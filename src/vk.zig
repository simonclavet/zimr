//! VULKAN, DECLARED BY HAND - exactly the part of the API zimr's Vulkan host calls, loaded at run time.
//!
//! zimr builds with nothing but the Zig compiler: no Vulkan SDK, no generated binding, no C header. The host talks to
//! the GPU driver through `vulkan-1.dll` (Windows) or `libvulkan.so.1` (Linux), opened at run time (`native_os.zig`),
//! which yields one function: `vkGetInstanceProcAddr`. Every other command is fetched through it, by name, into
//! dispatch tables - one per kind of handle, with the window system's commands apart, since a host without a window
//! has none of them:
//!
//!     GlobalDispatch      the commands that exist before an instance (vkCreateInstance, the layer and extension lists)
//!     InstanceDispatch    per instance: physical devices, the debug messenger, vkCreateDevice
//!     SurfaceDispatch     per instance, with a window: the surface and what it supports
//!     DeviceDispatch      per device: queues, images, semaphores, command buffers and the commands in them
//!     SwapchainDispatch   per device, with a window: the swapchain, acquiring and presenting
//!
//! `loadDispatch` fills any such table, so a program may also declare a smaller one of exactly the commands it calls.
//!
//! A table's fields are named after the commands themselves (`vkCreateDevice`), so a field IS the name the loader asks
//! for, and reads like the specification at every call site. A field whose type is optional belongs to an extension
//! the host may not enable (the debug utilities): it stays null when the driver does not provide it. Every other
//! command is required, and a missing one is the named error `MissingCommand`.
//!
//! ---- NAMES ----
//!
//! Types drop the `Vk` prefix (`VkInstanceCreateInfo` is `InstanceCreateInfo`). Commands drop the `vk` prefix and start
//! lower-case, as Zig functions do (`vkCmdBeginRendering` is the table field `cmdBeginRendering`), and each command's
//! function-pointer type is `Pfn` and its name (`PfnCmdBeginRendering`, the headers' `PFN_vkCmdBeginRendering`). Fields
//! and enumeration values are snake_case (`sType` is `s_type`, `VK_FORMAT_R8G8B8A8_UNORM` is `Format.r8g8b8a8_unorm`).
//! Each flags type is a packed structure with a `bool` per bit, named as the bit without its prefix and `BIT`
//! (`VK_IMAGE_USAGE_TRANSFER_DST_BIT` is `ImageUsageFlags.transfer_dst`); every other constant is its C name
//! lower-cased without `VK_` (`VK_MAX_MEMORY_TYPES` is `max_memory_types`). Each structure's `s_type` defaults to
//! its own value and its pointers to null, so a create-info names only what it sets.
//!
//! ---- READING C TYPES IN ZIG ----
//!
//! The declarations follow the C headers, so they are full of C's pointer kinds, each in Zig's spelling:
//!
//!     ?*const T                        one T, or null                       C: const T*, to one object
//!     [*]const T                       the first of several T               C: const T*, to an array
//!     [*:0]const u8                    a string ending in a zero byte       C: const char*
//!     ?*const anyopaque                something of a type not stated here  C: const void* (the pNext chains)
//!     *const fn (A) callconv(.c) R     a C function taking A, returning R   C: R (*)(A)
//!
//! `callconv(.c)` marks a function that follows the C calling convention - the driver's - rather than Zig's own; the
//! declarations here say `callconv(call_conv)`, Vulkan's convention, which is C's on every target but two.
//! The two function types that recur by concept have names: `PfnVoidFunction`, a command as a lookup returns
//! it, and `CommandLookup`, the lookup itself.
//!
//! ---- WHY THESE DECLARATIONS CAN BE TRUSTED ----
//!
//! A hand-declared structure that is wrong does not fail: the driver reads plausible garbage. So the declarations
//! between the hand-written parts of this file are generated from the Vulkan registry (`vk.xml`, the file the C
//! headers are generated from), for the subset zimr uses, by `tools/vk_gen.zig` (`zig build vk-gen
//! -Dvulkan-registry=<path to vk.xml>`); and `zig build vk-abi-check`
//! compares them with the official headers through `translate-c`, at compile time and for the Windows target: every
//! structure's size, alignment and field offsets, every enumeration value and constant, every command's parameter
//! count and sizes. Both take a checkout of Vulkan-Headers, a development-time source only; the build never needs it.
//! To declare one more command: add it to the generator's lists, regenerate, run the check.
//!
//! ---- HANDLES ----
//!
//! A dispatchable handle (instance, physical device, device, queue, command buffer) is a pointer in C; a
//! non-dispatchable one is a 64-bit value on 64-bit targets. Both are declared as non-exhaustive enumerations of that
//! size - the same bits at the ABI, and a different type per kind, so an image view cannot be passed where an image
//! belongs. `.null_handle` is `VK_NULL_HANDLE`. Only 64-bit targets are supported.
//!
//! Std only; no operating system named - the window layer loads the library.

const std = @import("std");
const builtin = @import("builtin");

const CallingConvention = std.builtin.CallingConvention;
const comptimePrint = std.fmt.comptimePrint;
const toUpper = std.ascii.toUpper;

const indexOfScalar = std.mem.indexOfScalar;

comptime {
    if (@sizeOf(usize) != 8) {
        @compileError("vk.zig declares non-dispatchable handles as 64-bit values: 64-bit targets only");
    }
}

// ---- Base types and handles ----

pub const Bool32 = u32;
pub const bool_true: Bool32 = 1;
pub const bool_false: Bool32 = 0;

/// A Zig `bool` as Vulkan's 32-bit boolean, for the create-info fields set from a condition.
pub fn bool32(value: bool) Bool32 {
    return @intFromBool(value);
}

/// The calling convention of Vulkan's commands and callbacks: `VKAPI_CALL` and `VKAPI_PTR` in the C headers. It is
/// C's own, except in two places. On 32-bit Windows, Vulkan uses stdcall, the Windows API's convention. On 32-bit
/// ARM Android, Vulkan passes floating-point arguments in registers ("hardfloat", the AAPCS-VFP convention) even when
/// the rest of the program passes them on the stack, as the NDK's armeabi-v7a ABI does.
pub const call_conv: CallingConvention = if (builtin.os.tag == .windows and builtin.cpu.arch == .x86)
    .winapi
else if (builtin.abi.isAndroid() and (builtin.cpu.arch.isArm() or builtin.cpu.arch.isThumb()))
    .{ .arm_aapcs_vfp = .{} }
else
    .c;

/// A Vulkan command as a lookup returns it: a C function whose real type only the caller knows, since it asked for
/// the command by name. A dispatch table casts it to that type - `PfnCreateInstance`, say - before anything calls
/// it. The C headers call it `PFN_vkVoidFunction`.
pub const PfnVoidFunction = *const fn () callconv(call_conv) void;
pub const DeviceSize = u64;
pub const DeviceAddress = u64;
pub const Flags = u32;
pub const Flags64 = u64;

/// Whether `flags` has every bit `required` has, for the flags structures below: `hasAllFlags(MemoryPropertyFlags,
/// memory_type.property_flags, required)`. The bits are compared as the integers the structures are made of.
pub fn hasAllFlags(
    comptime FlagsType: type,
    flags: FlagsType,
    required: FlagsType,
) bool {
    const Bits: type = @typeInfo(FlagsType).@"struct".backing_integer.?;
    const flag_bits: Bits = @bitCast(flags);
    const required_bits: Bits = @bitCast(required);
    return flag_bits & required_bits == required_bits;
}

/// The flags set in either of two flags values: `mergeFlags(MemoryPropertyFlags, preferred, required)`.
pub fn mergeFlags(
    comptime FlagsType: type,
    first: FlagsType,
    second: FlagsType,
) FlagsType {
    const Bits: type = @typeInfo(FlagsType).@"struct".backing_integer.?;
    const first_bits: Bits = @bitCast(first);
    const second_bits: Bits = @bitCast(second);
    return @bitCast(first_bits | second_bits);
}

pub const Instance = enum(usize) { null_handle = 0, _ };
pub const PhysicalDevice = enum(usize) { null_handle = 0, _ };
pub const Device = enum(usize) { null_handle = 0, _ };
pub const Queue = enum(usize) { null_handle = 0, _ };
pub const CommandBuffer = enum(usize) { null_handle = 0, _ };

pub const SurfaceKHR = enum(u64) { null_handle = 0, _ };
pub const SwapchainKHR = enum(u64) { null_handle = 0, _ };
pub const Buffer = enum(u64) { null_handle = 0, _ };
pub const Image = enum(u64) { null_handle = 0, _ };
pub const ImageView = enum(u64) { null_handle = 0, _ };
pub const Semaphore = enum(u64) { null_handle = 0, _ };
pub const Fence = enum(u64) { null_handle = 0, _ };
pub const CommandPool = enum(u64) { null_handle = 0, _ };
pub const DebugUtilsMessengerEXT = enum(u64) { null_handle = 0, _ };
pub const DeviceMemory = enum(u64) { null_handle = 0, _ };
pub const BufferView = enum(u64) { null_handle = 0, _ };
pub const Sampler = enum(u64) { null_handle = 0, _ };
pub const ShaderModule = enum(u64) { null_handle = 0, _ };
pub const DescriptorSetLayout = enum(u64) { null_handle = 0, _ };
pub const DescriptorPool = enum(u64) { null_handle = 0, _ };
pub const DescriptorSet = enum(u64) { null_handle = 0, _ };
pub const PipelineLayout = enum(u64) { null_handle = 0, _ };
pub const PipelineCache = enum(u64) { null_handle = 0, _ };
pub const Pipeline = enum(u64) { null_handle = 0, _ };
pub const RenderPass = enum(u64) { null_handle = 0, _ };

/// A Vulkan version number: variant (3 bits), major (7), minor (10), patch (12), packed as `VK_MAKE_API_VERSION`.
pub fn makeApiVersion(variant: u32, major: u32, minor: u32, patch: u32) u32 {
    return (variant << 29) | (major << 22) | (minor << 12) | patch;
}

pub fn apiVersionMajor(version: u32) u32 {
    return (version >> 22) & 0x7f;
}

pub fn apiVersionMinor(version: u32) u32 {
    return (version >> 12) & 0x3ff;
}

pub const api_version_1_3: u32 = makeApiVersion(0, 1, 3, 0);

/// The validation layer's name, as the loader lists it.
pub const khronos_validation_layer_name: [*:0]const u8 = "VK_LAYER_KHRONOS_validation";
pub const khr_surface_extension_name: [*:0]const u8 = "VK_KHR_surface";
pub const khr_win32_surface_extension_name: [*:0]const u8 = "VK_KHR_win32_surface";
pub const khr_swapchain_extension_name: [*:0]const u8 = "VK_KHR_swapchain";
pub const ext_debug_utils_extension_name: [*:0]const u8 = "VK_EXT_debug_utils";

// ---- Enumerations: the values zimr uses, non-exhaustive so a driver's other values stay representable ----

pub const Result = enum(i32) {
    success = 0,
    not_ready = 1,
    timeout = 2,
    event_set = 3,
    event_reset = 4,
    incomplete = 5,
    suboptimal_khr = 1000001003,
    error_out_of_host_memory = -1,
    error_out_of_device_memory = -2,
    error_initialization_failed = -3,
    error_device_lost = -4,
    error_memory_map_failed = -5,
    error_layer_not_present = -6,
    error_extension_not_present = -7,
    error_feature_not_present = -8,
    error_incompatible_driver = -9,
    error_too_many_objects = -10,
    error_format_not_supported = -11,
    error_surface_lost_khr = -1000000000,
    error_native_window_in_use_khr = -1000000001,
    error_out_of_date_khr = -1000001004,
    error_validation_failed_ext = -1000011001,
    error_unknown = -13,
    error_fragmented_pool = -12,
    error_out_of_pool_memory = -1000069000,
    _,
};

pub const Format = enum(i32) {
    undefined = 0,
    r8_unorm = 9,
    r8g8_unorm = 16,
    r8g8b8a8_unorm = 37,
    r8g8b8a8_srgb = 43,
    r8g8b8a8_uint = 41,
    b8g8r8a8_unorm = 44,
    b8g8r8a8_srgb = 50,
    a2b10g10r10_unorm_pack32 = 64,
    r16g16b16a16_sfloat = 97,
    r32_uint = 98,
    r32_sfloat = 100,
    r32g32_uint = 101,
    r32g32_sfloat = 103,
    r32g32b32_sfloat = 106,
    r32g32b32a32_sfloat = 109,
    d16_unorm = 124,
    d32_sfloat = 126,
    _,
};

pub const ColorSpaceKHR = enum(i32) {
    srgb_nonlinear_khr = 0,
    _,
};

pub const PresentModeKHR = enum(i32) {
    immediate_khr = 0,
    mailbox_khr = 1,
    fifo_khr = 2,
    fifo_relaxed_khr = 3,
    _,
};

pub const PhysicalDeviceType = enum(i32) {
    other = 0,
    integrated_gpu = 1,
    discrete_gpu = 2,
    virtual_gpu = 3,
    cpu = 4,
    _,
};

pub const ImageLayout = enum(i32) {
    undefined = 0,
    general = 1,
    present_src_khr = 1000001002,
    _,
};

pub const AttachmentLoadOp = enum(i32) {
    load = 0,
    clear = 1,
    dont_care = 2,
    _,
};

pub const AttachmentStoreOp = enum(i32) {
    store = 0,
    dont_care = 1,
    _,
};

pub const ImageViewType = enum(i32) {
    @"2d" = 1,
    @"2d_array" = 5,
    _,
};

pub const ComponentSwizzle = enum(i32) {
    identity = 0,
    _,
};

pub const SharingMode = enum(i32) {
    exclusive = 0,
    concurrent = 1,
    _,
};

pub const SemaphoreType = enum(i32) {
    binary = 0,
    timeline = 1,
    _,
};

pub const CommandBufferLevel = enum(i32) {
    primary = 0,
    _,
};

pub const ObjectType = enum(i32) {
    unknown = 0,
    instance = 1,
    device = 3,
    queue = 4,
    semaphore = 5,
    command_buffer = 6,
    buffer = 9,
    image = 10,
    device_memory = 8,
    image_view = 14,
    shader_module = 15,
    pipeline_layout = 17,
    pipeline = 19,
    descriptor_set_layout = 20,
    sampler = 21,
    descriptor_set = 23,
    command_pool = 25,
    swapchain_khr = 1000001000,
    _,
};

pub const ImageType = enum(i32) {
    @"2d" = 1,
    @"3d" = 2,
    _,
};

pub const ImageTiling = enum(i32) {
    optimal = 0,
    linear = 1,
    _,
};

pub const Filter = enum(i32) {
    nearest = 0,
    linear = 1,
    _,
};

pub const SamplerMipmapMode = enum(i32) {
    nearest = 0,
    linear = 1,
    _,
};

pub const SamplerAddressMode = enum(i32) {
    repeat = 0,
    mirrored_repeat = 1,
    clamp_to_edge = 2,
    _,
};

pub const BorderColor = enum(i32) {
    float_transparent_black = 0,
    _,
};

pub const CompareOp = enum(i32) {
    never = 0,
    less = 1,
    equal = 2,
    less_or_equal = 3,
    greater = 4,
    not_equal = 5,
    greater_or_equal = 6,
    always = 7,
    _,
};

pub const DescriptorType = enum(i32) {
    sampler = 0,
    sampled_image = 2,
    storage_image = 3,
    uniform_buffer = 6,
    storage_buffer = 7,
    _,
};

pub const PipelineBindPoint = enum(i32) {
    graphics = 0,
    compute = 1,
    _,
};

pub const VertexInputRate = enum(i32) {
    vertex = 0,
    instance = 1,
    _,
};

pub const PrimitiveTopology = enum(i32) {
    point_list = 0,
    line_list = 1,
    line_strip = 2,
    triangle_list = 3,
    triangle_strip = 4,
    _,
};

pub const PolygonMode = enum(i32) {
    fill = 0,
    _,
};

pub const FrontFace = enum(i32) {
    counter_clockwise = 0,
    clockwise = 1,
    _,
};

pub const BlendFactor = enum(i32) {
    zero = 0,
    one = 1,
    src_color = 2,
    one_minus_src_color = 3,
    dst_color = 4,
    one_minus_dst_color = 5,
    src_alpha = 6,
    one_minus_src_alpha = 7,
    dst_alpha = 8,
    one_minus_dst_alpha = 9,
    _,
};

pub const BlendOp = enum(i32) {
    add = 0,
    _,
};

pub const LogicOp = enum(i32) {
    copy = 3,
    _,
};

pub const StencilOp = enum(i32) {
    keep = 0,
    _,
};

pub const DynamicState = enum(i32) {
    viewport = 0,
    scissor = 1,
    _,
};

pub const IndexType = enum(i32) {
    uint16 = 0,
    uint32 = 1,
    _,
};

pub const StructureType = enum(i32) {
    application_info = 0,
    buffer_create_info = 12,
    buffer_memory_barrier_2 = 1000314001,
    command_buffer_allocate_info = 40,
    command_buffer_begin_info = 42,
    command_buffer_submit_info = 1000314006,
    command_pool_create_info = 39,
    compute_pipeline_create_info = 29,
    copy_descriptor_set = 36,
    debug_utils_label_ext = 1000128002,
    debug_utils_messenger_callback_data_ext = 1000128003,
    debug_utils_messenger_create_info_ext = 1000128004,
    debug_utils_object_name_info_ext = 1000128000,
    dependency_info = 1000314003,
    descriptor_pool_create_info = 33,
    descriptor_set_allocate_info = 34,
    descriptor_set_layout_create_info = 32,
    device_create_info = 3,
    device_queue_create_info = 2,
    graphics_pipeline_create_info = 28,
    image_create_info = 14,
    image_memory_barrier_2 = 1000314002,
    image_view_create_info = 15,
    instance_create_info = 1,
    memory_allocate_info = 5,
    memory_barrier_2 = 1000314000,
    physical_device_features_2 = 1000059000,
    physical_device_vulkan_1_2_features = 51,
    physical_device_vulkan_1_3_features = 53,
    pipeline_color_blend_state_create_info = 26,
    pipeline_depth_stencil_state_create_info = 25,
    pipeline_dynamic_state_create_info = 27,
    pipeline_input_assembly_state_create_info = 20,
    pipeline_layout_create_info = 30,
    pipeline_multisample_state_create_info = 24,
    pipeline_rasterization_state_create_info = 23,
    pipeline_rendering_create_info = 1000044002,
    pipeline_shader_stage_create_info = 18,
    pipeline_vertex_input_state_create_info = 19,
    pipeline_viewport_state_create_info = 22,
    present_info_khr = 1000001001,
    rendering_attachment_info = 1000044001,
    rendering_info = 1000044000,
    sampler_create_info = 31,
    semaphore_create_info = 9,
    semaphore_submit_info = 1000314005,
    semaphore_type_create_info = 1000207002,
    semaphore_wait_info = 1000207004,
    shader_module_create_info = 16,
    submit_info_2 = 1000314004,
    swapchain_create_info_khr = 1000001000,
    win32_surface_create_info_khr = 1000009000,
    write_descriptor_set = 35,
    _,
};

// ---- Flags: one packed structure per flags type, a field per bit ----

pub const AccessFlags2 = packed struct(Flags64) {
    indirect_command_read: bool = false,
    index_read: bool = false,
    vertex_attribute_read: bool = false,
    uniform_read: bool = false,
    input_attachment_read: bool = false,
    shader_read: bool = false,
    shader_write: bool = false,
    color_attachment_read: bool = false,
    color_attachment_write: bool = false,
    depth_stencil_attachment_read: bool = false,
    depth_stencil_attachment_write: bool = false,
    transfer_read: bool = false,
    transfer_write: bool = false,
    host_read: bool = false,
    host_write: bool = false,
    memory_read: bool = false,
    memory_write: bool = false,
    command_preprocess_read_ext: bool = false,
    command_preprocess_write_ext: bool = false,
    color_attachment_read_noncoherent_ext: bool = false,
    conditional_rendering_read_ext: bool = false,
    acceleration_structure_read_khr: bool = false,
    acceleration_structure_write_khr: bool = false,
    fragment_shading_rate_attachment_read_khr: bool = false,
    fragment_density_map_read_ext: bool = false,
    transform_feedback_write_ext: bool = false,
    transform_feedback_counter_read_ext: bool = false,
    transform_feedback_counter_write_ext: bool = false,
    _reserved_bit_28: bool = false,
    _reserved_bit_29: bool = false,
    _reserved_bit_30: bool = false,
    _reserved_bit_31: bool = false,
    shader_sampled_read: bool = false,
    shader_storage_read: bool = false,
    shader_storage_write: bool = false,
    video_decode_read_khr: bool = false,
    video_decode_write_khr: bool = false,
    video_encode_read_khr: bool = false,
    video_encode_write_khr: bool = false,
    invocation_mask_read_huawei: bool = false,
    shader_binding_table_read_khr: bool = false,
    descriptor_buffer_read_ext: bool = false,
    optical_flow_read_nv: bool = false,
    optical_flow_write_nv: bool = false,
    micromap_read_ext: bool = false,
    micromap_write_ext: bool = false,
    _reserved_bit_46: bool = false,
    data_graph_read_arm: bool = false,
    data_graph_write_arm: bool = false,
    _reserved_bit_49: bool = false,
    _reserved_bit_50: bool = false,
    shader_tile_attachment_read_qcom: bool = false,
    shader_tile_attachment_write_qcom: bool = false,
    _reserved_bit_53: bool = false,
    _reserved_bit_54: bool = false,
    memory_decompression_read_ext: bool = false,
    memory_decompression_write_ext: bool = false,
    sampler_heap_read_ext: bool = false,
    resource_heap_read_ext: bool = false,
    _reserved_bit_59: bool = false,
    _reserved_bit_60: bool = false,
    _reserved_bit_61: bool = false,
    _reserved_bit_62: bool = false,
    _reserved_bit_63: bool = false,
};

pub const BufferCreateFlags = packed struct(Flags) {
    sparse_binding: bool = false,
    sparse_residency: bool = false,
    sparse_aliased: bool = false,
    protected: bool = false,
    device_address_capture_replay: bool = false,
    descriptor_buffer_capture_replay_ext: bool = false,
    video_profile_independent_khr: bool = false,
    _reserved_bit_7: bool = false,
    _reserved_bit_8: bool = false,
    _reserved_bit_9: bool = false,
    _reserved_bit_10: bool = false,
    _reserved_bit_11: bool = false,
    _reserved_bit_12: bool = false,
    _reserved_bit_13: bool = false,
    _reserved_bit_14: bool = false,
    _reserved_bit_15: bool = false,
    _reserved_bit_16: bool = false,
    _reserved_bit_17: bool = false,
    _reserved_bit_18: bool = false,
    _reserved_bit_19: bool = false,
    _reserved_bit_20: bool = false,
    _reserved_bit_21: bool = false,
    _reserved_bit_22: bool = false,
    _reserved_bit_23: bool = false,
    _reserved_bit_24: bool = false,
    _reserved_bit_25: bool = false,
    _reserved_bit_26: bool = false,
    _reserved_bit_27: bool = false,
    _reserved_bit_28: bool = false,
    _reserved_bit_29: bool = false,
    _reserved_bit_30: bool = false,
    _reserved_bit_31: bool = false,
};

pub const BufferUsageFlags = packed struct(Flags) {
    transfer_src: bool = false,
    transfer_dst: bool = false,
    uniform_texel_buffer: bool = false,
    storage_texel_buffer: bool = false,
    uniform_buffer: bool = false,
    storage_buffer: bool = false,
    index_buffer: bool = false,
    vertex_buffer: bool = false,
    indirect_buffer: bool = false,
    conditional_rendering_ext: bool = false,
    shader_binding_table_khr: bool = false,
    transform_feedback_buffer_ext: bool = false,
    transform_feedback_counter_buffer_ext: bool = false,
    video_decode_src_khr: bool = false,
    video_decode_dst_khr: bool = false,
    video_encode_dst_khr: bool = false,
    video_encode_src_khr: bool = false,
    shader_device_address: bool = false,
    _reserved_bit_18: bool = false,
    acceleration_structure_build_input_read_only_khr: bool = false,
    acceleration_structure_storage_khr: bool = false,
    sampler_descriptor_buffer_ext: bool = false,
    resource_descriptor_buffer_ext: bool = false,
    micromap_build_input_read_only_ext: bool = false,
    micromap_storage_ext: bool = false,
    execution_graph_scratch_amdx: bool = false,
    push_descriptors_descriptor_buffer_ext: bool = false,
    tile_memory_qcom: bool = false,
    descriptor_heap_ext: bool = false,
    _reserved_bit_29: bool = false,
    _reserved_bit_30: bool = false,
    _reserved_bit_31: bool = false,
};

pub const ColorComponentFlags = packed struct(Flags) {
    r: bool = false,
    g: bool = false,
    b: bool = false,
    a: bool = false,
    _reserved_bit_4: bool = false,
    _reserved_bit_5: bool = false,
    _reserved_bit_6: bool = false,
    _reserved_bit_7: bool = false,
    _reserved_bit_8: bool = false,
    _reserved_bit_9: bool = false,
    _reserved_bit_10: bool = false,
    _reserved_bit_11: bool = false,
    _reserved_bit_12: bool = false,
    _reserved_bit_13: bool = false,
    _reserved_bit_14: bool = false,
    _reserved_bit_15: bool = false,
    _reserved_bit_16: bool = false,
    _reserved_bit_17: bool = false,
    _reserved_bit_18: bool = false,
    _reserved_bit_19: bool = false,
    _reserved_bit_20: bool = false,
    _reserved_bit_21: bool = false,
    _reserved_bit_22: bool = false,
    _reserved_bit_23: bool = false,
    _reserved_bit_24: bool = false,
    _reserved_bit_25: bool = false,
    _reserved_bit_26: bool = false,
    _reserved_bit_27: bool = false,
    _reserved_bit_28: bool = false,
    _reserved_bit_29: bool = false,
    _reserved_bit_30: bool = false,
    _reserved_bit_31: bool = false,
};

pub const CommandBufferResetFlags = packed struct(Flags) {
    release_resources: bool = false,
    _reserved_bit_1: bool = false,
    _reserved_bit_2: bool = false,
    _reserved_bit_3: bool = false,
    _reserved_bit_4: bool = false,
    _reserved_bit_5: bool = false,
    _reserved_bit_6: bool = false,
    _reserved_bit_7: bool = false,
    _reserved_bit_8: bool = false,
    _reserved_bit_9: bool = false,
    _reserved_bit_10: bool = false,
    _reserved_bit_11: bool = false,
    _reserved_bit_12: bool = false,
    _reserved_bit_13: bool = false,
    _reserved_bit_14: bool = false,
    _reserved_bit_15: bool = false,
    _reserved_bit_16: bool = false,
    _reserved_bit_17: bool = false,
    _reserved_bit_18: bool = false,
    _reserved_bit_19: bool = false,
    _reserved_bit_20: bool = false,
    _reserved_bit_21: bool = false,
    _reserved_bit_22: bool = false,
    _reserved_bit_23: bool = false,
    _reserved_bit_24: bool = false,
    _reserved_bit_25: bool = false,
    _reserved_bit_26: bool = false,
    _reserved_bit_27: bool = false,
    _reserved_bit_28: bool = false,
    _reserved_bit_29: bool = false,
    _reserved_bit_30: bool = false,
    _reserved_bit_31: bool = false,
};

pub const CommandBufferUsageFlags = packed struct(Flags) {
    one_time_submit: bool = false,
    render_pass_continue: bool = false,
    simultaneous_use: bool = false,
    _reserved_bit_3: bool = false,
    _reserved_bit_4: bool = false,
    _reserved_bit_5: bool = false,
    _reserved_bit_6: bool = false,
    _reserved_bit_7: bool = false,
    _reserved_bit_8: bool = false,
    _reserved_bit_9: bool = false,
    _reserved_bit_10: bool = false,
    _reserved_bit_11: bool = false,
    _reserved_bit_12: bool = false,
    _reserved_bit_13: bool = false,
    _reserved_bit_14: bool = false,
    _reserved_bit_15: bool = false,
    _reserved_bit_16: bool = false,
    _reserved_bit_17: bool = false,
    _reserved_bit_18: bool = false,
    _reserved_bit_19: bool = false,
    _reserved_bit_20: bool = false,
    _reserved_bit_21: bool = false,
    _reserved_bit_22: bool = false,
    _reserved_bit_23: bool = false,
    _reserved_bit_24: bool = false,
    _reserved_bit_25: bool = false,
    _reserved_bit_26: bool = false,
    _reserved_bit_27: bool = false,
    _reserved_bit_28: bool = false,
    _reserved_bit_29: bool = false,
    _reserved_bit_30: bool = false,
    _reserved_bit_31: bool = false,
};

pub const CommandPoolCreateFlags = packed struct(Flags) {
    transient: bool = false,
    reset_command_buffer: bool = false,
    protected: bool = false,
    _reserved_bit_3: bool = false,
    _reserved_bit_4: bool = false,
    _reserved_bit_5: bool = false,
    _reserved_bit_6: bool = false,
    _reserved_bit_7: bool = false,
    _reserved_bit_8: bool = false,
    _reserved_bit_9: bool = false,
    _reserved_bit_10: bool = false,
    _reserved_bit_11: bool = false,
    _reserved_bit_12: bool = false,
    _reserved_bit_13: bool = false,
    _reserved_bit_14: bool = false,
    _reserved_bit_15: bool = false,
    _reserved_bit_16: bool = false,
    _reserved_bit_17: bool = false,
    _reserved_bit_18: bool = false,
    _reserved_bit_19: bool = false,
    _reserved_bit_20: bool = false,
    _reserved_bit_21: bool = false,
    _reserved_bit_22: bool = false,
    _reserved_bit_23: bool = false,
    _reserved_bit_24: bool = false,
    _reserved_bit_25: bool = false,
    _reserved_bit_26: bool = false,
    _reserved_bit_27: bool = false,
    _reserved_bit_28: bool = false,
    _reserved_bit_29: bool = false,
    _reserved_bit_30: bool = false,
    _reserved_bit_31: bool = false,
};

pub const CompositeAlphaFlagsKHR = packed struct(Flags) {
    @"opaque": bool = false,
    pre_multiplied: bool = false,
    post_multiplied: bool = false,
    inherit: bool = false,
    _reserved_bit_4: bool = false,
    _reserved_bit_5: bool = false,
    _reserved_bit_6: bool = false,
    _reserved_bit_7: bool = false,
    _reserved_bit_8: bool = false,
    _reserved_bit_9: bool = false,
    _reserved_bit_10: bool = false,
    _reserved_bit_11: bool = false,
    _reserved_bit_12: bool = false,
    _reserved_bit_13: bool = false,
    _reserved_bit_14: bool = false,
    _reserved_bit_15: bool = false,
    _reserved_bit_16: bool = false,
    _reserved_bit_17: bool = false,
    _reserved_bit_18: bool = false,
    _reserved_bit_19: bool = false,
    _reserved_bit_20: bool = false,
    _reserved_bit_21: bool = false,
    _reserved_bit_22: bool = false,
    _reserved_bit_23: bool = false,
    _reserved_bit_24: bool = false,
    _reserved_bit_25: bool = false,
    _reserved_bit_26: bool = false,
    _reserved_bit_27: bool = false,
    _reserved_bit_28: bool = false,
    _reserved_bit_29: bool = false,
    _reserved_bit_30: bool = false,
    _reserved_bit_31: bool = false,
};

pub const CullModeFlags = packed struct(Flags) {
    front: bool = false,
    back: bool = false,
    _reserved_bit_2: bool = false,
    _reserved_bit_3: bool = false,
    _reserved_bit_4: bool = false,
    _reserved_bit_5: bool = false,
    _reserved_bit_6: bool = false,
    _reserved_bit_7: bool = false,
    _reserved_bit_8: bool = false,
    _reserved_bit_9: bool = false,
    _reserved_bit_10: bool = false,
    _reserved_bit_11: bool = false,
    _reserved_bit_12: bool = false,
    _reserved_bit_13: bool = false,
    _reserved_bit_14: bool = false,
    _reserved_bit_15: bool = false,
    _reserved_bit_16: bool = false,
    _reserved_bit_17: bool = false,
    _reserved_bit_18: bool = false,
    _reserved_bit_19: bool = false,
    _reserved_bit_20: bool = false,
    _reserved_bit_21: bool = false,
    _reserved_bit_22: bool = false,
    _reserved_bit_23: bool = false,
    _reserved_bit_24: bool = false,
    _reserved_bit_25: bool = false,
    _reserved_bit_26: bool = false,
    _reserved_bit_27: bool = false,
    _reserved_bit_28: bool = false,
    _reserved_bit_29: bool = false,
    _reserved_bit_30: bool = false,
    _reserved_bit_31: bool = false,
};

pub const DebugUtilsMessageSeverityFlagsEXT = packed struct(Flags) {
    verbose: bool = false,
    _reserved_bit_1: bool = false,
    _reserved_bit_2: bool = false,
    _reserved_bit_3: bool = false,
    info: bool = false,
    _reserved_bit_5: bool = false,
    _reserved_bit_6: bool = false,
    _reserved_bit_7: bool = false,
    warning: bool = false,
    _reserved_bit_9: bool = false,
    _reserved_bit_10: bool = false,
    _reserved_bit_11: bool = false,
    @"error": bool = false,
    _reserved_bit_13: bool = false,
    _reserved_bit_14: bool = false,
    _reserved_bit_15: bool = false,
    _reserved_bit_16: bool = false,
    _reserved_bit_17: bool = false,
    _reserved_bit_18: bool = false,
    _reserved_bit_19: bool = false,
    _reserved_bit_20: bool = false,
    _reserved_bit_21: bool = false,
    _reserved_bit_22: bool = false,
    _reserved_bit_23: bool = false,
    _reserved_bit_24: bool = false,
    _reserved_bit_25: bool = false,
    _reserved_bit_26: bool = false,
    _reserved_bit_27: bool = false,
    _reserved_bit_28: bool = false,
    _reserved_bit_29: bool = false,
    _reserved_bit_30: bool = false,
    _reserved_bit_31: bool = false,
};

pub const DebugUtilsMessageTypeFlagsEXT = packed struct(Flags) {
    general: bool = false,
    validation: bool = false,
    performance: bool = false,
    device_address_binding: bool = false,
    _reserved_bit_4: bool = false,
    _reserved_bit_5: bool = false,
    _reserved_bit_6: bool = false,
    _reserved_bit_7: bool = false,
    _reserved_bit_8: bool = false,
    _reserved_bit_9: bool = false,
    _reserved_bit_10: bool = false,
    _reserved_bit_11: bool = false,
    _reserved_bit_12: bool = false,
    _reserved_bit_13: bool = false,
    _reserved_bit_14: bool = false,
    _reserved_bit_15: bool = false,
    _reserved_bit_16: bool = false,
    _reserved_bit_17: bool = false,
    _reserved_bit_18: bool = false,
    _reserved_bit_19: bool = false,
    _reserved_bit_20: bool = false,
    _reserved_bit_21: bool = false,
    _reserved_bit_22: bool = false,
    _reserved_bit_23: bool = false,
    _reserved_bit_24: bool = false,
    _reserved_bit_25: bool = false,
    _reserved_bit_26: bool = false,
    _reserved_bit_27: bool = false,
    _reserved_bit_28: bool = false,
    _reserved_bit_29: bool = false,
    _reserved_bit_30: bool = false,
    _reserved_bit_31: bool = false,
};

pub const DependencyFlags = packed struct(Flags) {
    by_region: bool = false,
    view_local: bool = false,
    device_group: bool = false,
    feedback_loop_ext: bool = false,
    _reserved_bit_4: bool = false,
    queue_family_ownership_transfer_use_all_stages_khr: bool = false,
    asymmetric_event_khr: bool = false,
    _reserved_bit_7: bool = false,
    _reserved_bit_8: bool = false,
    _reserved_bit_9: bool = false,
    _reserved_bit_10: bool = false,
    _reserved_bit_11: bool = false,
    _reserved_bit_12: bool = false,
    _reserved_bit_13: bool = false,
    _reserved_bit_14: bool = false,
    _reserved_bit_15: bool = false,
    _reserved_bit_16: bool = false,
    _reserved_bit_17: bool = false,
    _reserved_bit_18: bool = false,
    _reserved_bit_19: bool = false,
    _reserved_bit_20: bool = false,
    _reserved_bit_21: bool = false,
    _reserved_bit_22: bool = false,
    _reserved_bit_23: bool = false,
    _reserved_bit_24: bool = false,
    _reserved_bit_25: bool = false,
    _reserved_bit_26: bool = false,
    _reserved_bit_27: bool = false,
    _reserved_bit_28: bool = false,
    _reserved_bit_29: bool = false,
    _reserved_bit_30: bool = false,
    _reserved_bit_31: bool = false,
};

pub const DescriptorPoolCreateFlags = packed struct(Flags) {
    free_descriptor_set: bool = false,
    update_after_bind: bool = false,
    host_only_ext: bool = false,
    allow_overallocation_sets_nv: bool = false,
    allow_overallocation_pools_nv: bool = false,
    _reserved_bit_5: bool = false,
    _reserved_bit_6: bool = false,
    _reserved_bit_7: bool = false,
    _reserved_bit_8: bool = false,
    _reserved_bit_9: bool = false,
    _reserved_bit_10: bool = false,
    _reserved_bit_11: bool = false,
    _reserved_bit_12: bool = false,
    _reserved_bit_13: bool = false,
    _reserved_bit_14: bool = false,
    _reserved_bit_15: bool = false,
    _reserved_bit_16: bool = false,
    _reserved_bit_17: bool = false,
    _reserved_bit_18: bool = false,
    _reserved_bit_19: bool = false,
    _reserved_bit_20: bool = false,
    _reserved_bit_21: bool = false,
    _reserved_bit_22: bool = false,
    _reserved_bit_23: bool = false,
    _reserved_bit_24: bool = false,
    _reserved_bit_25: bool = false,
    _reserved_bit_26: bool = false,
    _reserved_bit_27: bool = false,
    _reserved_bit_28: bool = false,
    _reserved_bit_29: bool = false,
    _reserved_bit_30: bool = false,
    _reserved_bit_31: bool = false,
};

pub const DescriptorSetLayoutCreateFlags = packed struct(Flags) {
    push_descriptor: bool = false,
    update_after_bind_pool: bool = false,
    host_only_pool_ext: bool = false,
    _reserved_bit_3: bool = false,
    descriptor_buffer_ext: bool = false,
    embedded_immutable_samplers_ext: bool = false,
    per_stage_nv: bool = false,
    indirect_bindable_nv: bool = false,
    _reserved_bit_8: bool = false,
    _reserved_bit_9: bool = false,
    _reserved_bit_10: bool = false,
    _reserved_bit_11: bool = false,
    _reserved_bit_12: bool = false,
    _reserved_bit_13: bool = false,
    _reserved_bit_14: bool = false,
    _reserved_bit_15: bool = false,
    _reserved_bit_16: bool = false,
    _reserved_bit_17: bool = false,
    _reserved_bit_18: bool = false,
    _reserved_bit_19: bool = false,
    _reserved_bit_20: bool = false,
    _reserved_bit_21: bool = false,
    _reserved_bit_22: bool = false,
    _reserved_bit_23: bool = false,
    _reserved_bit_24: bool = false,
    _reserved_bit_25: bool = false,
    _reserved_bit_26: bool = false,
    _reserved_bit_27: bool = false,
    _reserved_bit_28: bool = false,
    _reserved_bit_29: bool = false,
    _reserved_bit_30: bool = false,
    _reserved_bit_31: bool = false,
};

pub const DeviceQueueCreateFlags = packed struct(Flags) {
    protected: bool = false,
    _reserved_bit_1: bool = false,
    internally_synchronized_khr: bool = false,
    _reserved_bit_3: bool = false,
    _reserved_bit_4: bool = false,
    _reserved_bit_5: bool = false,
    _reserved_bit_6: bool = false,
    _reserved_bit_7: bool = false,
    _reserved_bit_8: bool = false,
    _reserved_bit_9: bool = false,
    _reserved_bit_10: bool = false,
    _reserved_bit_11: bool = false,
    _reserved_bit_12: bool = false,
    _reserved_bit_13: bool = false,
    _reserved_bit_14: bool = false,
    _reserved_bit_15: bool = false,
    _reserved_bit_16: bool = false,
    _reserved_bit_17: bool = false,
    _reserved_bit_18: bool = false,
    _reserved_bit_19: bool = false,
    _reserved_bit_20: bool = false,
    _reserved_bit_21: bool = false,
    _reserved_bit_22: bool = false,
    _reserved_bit_23: bool = false,
    _reserved_bit_24: bool = false,
    _reserved_bit_25: bool = false,
    _reserved_bit_26: bool = false,
    _reserved_bit_27: bool = false,
    _reserved_bit_28: bool = false,
    _reserved_bit_29: bool = false,
    _reserved_bit_30: bool = false,
    _reserved_bit_31: bool = false,
};

pub const ImageAspectFlags = packed struct(Flags) {
    color: bool = false,
    depth: bool = false,
    stencil: bool = false,
    metadata: bool = false,
    plane_0: bool = false,
    plane_1: bool = false,
    plane_2: bool = false,
    memory_plane_0_ext: bool = false,
    memory_plane_1_ext: bool = false,
    memory_plane_2_ext: bool = false,
    memory_plane_3_ext: bool = false,
    _reserved_bit_11: bool = false,
    _reserved_bit_12: bool = false,
    _reserved_bit_13: bool = false,
    _reserved_bit_14: bool = false,
    _reserved_bit_15: bool = false,
    _reserved_bit_16: bool = false,
    _reserved_bit_17: bool = false,
    _reserved_bit_18: bool = false,
    _reserved_bit_19: bool = false,
    _reserved_bit_20: bool = false,
    _reserved_bit_21: bool = false,
    _reserved_bit_22: bool = false,
    _reserved_bit_23: bool = false,
    _reserved_bit_24: bool = false,
    _reserved_bit_25: bool = false,
    _reserved_bit_26: bool = false,
    _reserved_bit_27: bool = false,
    _reserved_bit_28: bool = false,
    _reserved_bit_29: bool = false,
    _reserved_bit_30: bool = false,
    _reserved_bit_31: bool = false,
};

pub const ImageCreateFlags = packed struct(Flags) {
    sparse_binding: bool = false,
    sparse_residency: bool = false,
    sparse_aliased: bool = false,
    mutable_format: bool = false,
    cube_compatible: bool = false,
    @"2d_array_compatible": bool = false,
    split_instance_bind_regions: bool = false,
    block_texel_view_compatible: bool = false,
    extended_usage: bool = false,
    disjoint: bool = false,
    alias: bool = false,
    protected: bool = false,
    sample_locations_compatible_depth_ext: bool = false,
    corner_sampled_nv: bool = false,
    subsampled_ext: bool = false,
    fragment_density_map_offset_ext: bool = false,
    descriptor_heap_capture_replay_ext: bool = false,
    @"2d_view_compatible_ext": bool = false,
    multisampled_render_to_single_sampled_ext: bool = false,
    _reserved_bit_19: bool = false,
    video_profile_independent_khr: bool = false,
    _reserved_bit_21: bool = false,
    alias_single_layer_descriptor_khr: bool = false,
    _reserved_bit_23: bool = false,
    _reserved_bit_24: bool = false,
    _reserved_bit_25: bool = false,
    _reserved_bit_26: bool = false,
    _reserved_bit_27: bool = false,
    _reserved_bit_28: bool = false,
    _reserved_bit_29: bool = false,
    _reserved_bit_30: bool = false,
    _reserved_bit_31: bool = false,
};

pub const ImageUsageFlags = packed struct(Flags) {
    transfer_src: bool = false,
    transfer_dst: bool = false,
    sampled: bool = false,
    storage: bool = false,
    color_attachment: bool = false,
    depth_stencil_attachment: bool = false,
    transient_attachment: bool = false,
    input_attachment: bool = false,
    fragment_shading_rate_attachment_khr: bool = false,
    fragment_density_map_ext: bool = false,
    video_decode_dst_khr: bool = false,
    video_decode_src_khr: bool = false,
    video_decode_dpb_khr: bool = false,
    video_encode_dst_khr: bool = false,
    video_encode_src_khr: bool = false,
    video_encode_dpb_khr: bool = false,
    _reserved_bit_16: bool = false,
    _reserved_bit_17: bool = false,
    invocation_mask_huawei: bool = false,
    attachment_feedback_loop_ext: bool = false,
    sample_weight_qcom: bool = false,
    sample_block_match_qcom: bool = false,
    host_transfer: bool = false,
    tensor_aliasing_arm: bool = false,
    _reserved_bit_24: bool = false,
    video_encode_quantization_delta_map_khr: bool = false,
    video_encode_emphasis_map_khr: bool = false,
    tile_memory_qcom: bool = false,
    _reserved_bit_28: bool = false,
    _reserved_bit_29: bool = false,
    _reserved_bit_30: bool = false,
    _reserved_bit_31: bool = false,
};

pub const ImageViewCreateFlags = packed struct(Flags) {
    fragment_density_map_dynamic_ext: bool = false,
    fragment_density_map_deferred_ext: bool = false,
    descriptor_buffer_capture_replay_ext: bool = false,
    _reserved_bit_3: bool = false,
    _reserved_bit_4: bool = false,
    _reserved_bit_5: bool = false,
    _reserved_bit_6: bool = false,
    _reserved_bit_7: bool = false,
    _reserved_bit_8: bool = false,
    _reserved_bit_9: bool = false,
    _reserved_bit_10: bool = false,
    _reserved_bit_11: bool = false,
    _reserved_bit_12: bool = false,
    _reserved_bit_13: bool = false,
    _reserved_bit_14: bool = false,
    _reserved_bit_15: bool = false,
    _reserved_bit_16: bool = false,
    _reserved_bit_17: bool = false,
    _reserved_bit_18: bool = false,
    _reserved_bit_19: bool = false,
    _reserved_bit_20: bool = false,
    _reserved_bit_21: bool = false,
    _reserved_bit_22: bool = false,
    _reserved_bit_23: bool = false,
    _reserved_bit_24: bool = false,
    _reserved_bit_25: bool = false,
    _reserved_bit_26: bool = false,
    _reserved_bit_27: bool = false,
    _reserved_bit_28: bool = false,
    _reserved_bit_29: bool = false,
    _reserved_bit_30: bool = false,
    _reserved_bit_31: bool = false,
};

pub const InstanceCreateFlags = packed struct(Flags) {
    enumerate_portability_khr: bool = false,
    _reserved_bit_1: bool = false,
    _reserved_bit_2: bool = false,
    _reserved_bit_3: bool = false,
    _reserved_bit_4: bool = false,
    _reserved_bit_5: bool = false,
    _reserved_bit_6: bool = false,
    _reserved_bit_7: bool = false,
    _reserved_bit_8: bool = false,
    _reserved_bit_9: bool = false,
    _reserved_bit_10: bool = false,
    _reserved_bit_11: bool = false,
    _reserved_bit_12: bool = false,
    _reserved_bit_13: bool = false,
    _reserved_bit_14: bool = false,
    _reserved_bit_15: bool = false,
    _reserved_bit_16: bool = false,
    _reserved_bit_17: bool = false,
    _reserved_bit_18: bool = false,
    _reserved_bit_19: bool = false,
    _reserved_bit_20: bool = false,
    _reserved_bit_21: bool = false,
    _reserved_bit_22: bool = false,
    _reserved_bit_23: bool = false,
    _reserved_bit_24: bool = false,
    _reserved_bit_25: bool = false,
    _reserved_bit_26: bool = false,
    _reserved_bit_27: bool = false,
    _reserved_bit_28: bool = false,
    _reserved_bit_29: bool = false,
    _reserved_bit_30: bool = false,
    _reserved_bit_31: bool = false,
};

pub const MemoryHeapFlags = packed struct(Flags) {
    device_local: bool = false,
    multi_instance: bool = false,
    _reserved_bit_2: bool = false,
    tile_memory_qcom: bool = false,
    _reserved_bit_4: bool = false,
    _reserved_bit_5: bool = false,
    _reserved_bit_6: bool = false,
    _reserved_bit_7: bool = false,
    _reserved_bit_8: bool = false,
    _reserved_bit_9: bool = false,
    _reserved_bit_10: bool = false,
    _reserved_bit_11: bool = false,
    _reserved_bit_12: bool = false,
    _reserved_bit_13: bool = false,
    _reserved_bit_14: bool = false,
    _reserved_bit_15: bool = false,
    _reserved_bit_16: bool = false,
    _reserved_bit_17: bool = false,
    _reserved_bit_18: bool = false,
    _reserved_bit_19: bool = false,
    _reserved_bit_20: bool = false,
    _reserved_bit_21: bool = false,
    _reserved_bit_22: bool = false,
    _reserved_bit_23: bool = false,
    _reserved_bit_24: bool = false,
    _reserved_bit_25: bool = false,
    _reserved_bit_26: bool = false,
    _reserved_bit_27: bool = false,
    _reserved_bit_28: bool = false,
    _reserved_bit_29: bool = false,
    _reserved_bit_30: bool = false,
    _reserved_bit_31: bool = false,
};

pub const MemoryMapFlags = packed struct(Flags) {
    placed_ext: bool = false,
    _reserved_bit_1: bool = false,
    _reserved_bit_2: bool = false,
    _reserved_bit_3: bool = false,
    _reserved_bit_4: bool = false,
    _reserved_bit_5: bool = false,
    _reserved_bit_6: bool = false,
    _reserved_bit_7: bool = false,
    _reserved_bit_8: bool = false,
    _reserved_bit_9: bool = false,
    _reserved_bit_10: bool = false,
    _reserved_bit_11: bool = false,
    _reserved_bit_12: bool = false,
    _reserved_bit_13: bool = false,
    _reserved_bit_14: bool = false,
    _reserved_bit_15: bool = false,
    _reserved_bit_16: bool = false,
    _reserved_bit_17: bool = false,
    _reserved_bit_18: bool = false,
    _reserved_bit_19: bool = false,
    _reserved_bit_20: bool = false,
    _reserved_bit_21: bool = false,
    _reserved_bit_22: bool = false,
    _reserved_bit_23: bool = false,
    _reserved_bit_24: bool = false,
    _reserved_bit_25: bool = false,
    _reserved_bit_26: bool = false,
    _reserved_bit_27: bool = false,
    _reserved_bit_28: bool = false,
    _reserved_bit_29: bool = false,
    _reserved_bit_30: bool = false,
    _reserved_bit_31: bool = false,
};

pub const MemoryPropertyFlags = packed struct(Flags) {
    device_local: bool = false,
    host_visible: bool = false,
    host_coherent: bool = false,
    host_cached: bool = false,
    lazily_allocated: bool = false,
    protected: bool = false,
    device_coherent_amd: bool = false,
    device_uncached_amd: bool = false,
    rdma_capable_nv: bool = false,
    _reserved_bit_9: bool = false,
    _reserved_bit_10: bool = false,
    _reserved_bit_11: bool = false,
    _reserved_bit_12: bool = false,
    _reserved_bit_13: bool = false,
    _reserved_bit_14: bool = false,
    _reserved_bit_15: bool = false,
    _reserved_bit_16: bool = false,
    _reserved_bit_17: bool = false,
    _reserved_bit_18: bool = false,
    _reserved_bit_19: bool = false,
    _reserved_bit_20: bool = false,
    _reserved_bit_21: bool = false,
    _reserved_bit_22: bool = false,
    _reserved_bit_23: bool = false,
    _reserved_bit_24: bool = false,
    _reserved_bit_25: bool = false,
    _reserved_bit_26: bool = false,
    _reserved_bit_27: bool = false,
    _reserved_bit_28: bool = false,
    _reserved_bit_29: bool = false,
    _reserved_bit_30: bool = false,
    _reserved_bit_31: bool = false,
};

pub const PipelineColorBlendStateCreateFlags = packed struct(Flags) {
    rasterization_order_attachment_access_ext: bool = false,
    _reserved_bit_1: bool = false,
    _reserved_bit_2: bool = false,
    _reserved_bit_3: bool = false,
    _reserved_bit_4: bool = false,
    _reserved_bit_5: bool = false,
    _reserved_bit_6: bool = false,
    _reserved_bit_7: bool = false,
    _reserved_bit_8: bool = false,
    _reserved_bit_9: bool = false,
    _reserved_bit_10: bool = false,
    _reserved_bit_11: bool = false,
    _reserved_bit_12: bool = false,
    _reserved_bit_13: bool = false,
    _reserved_bit_14: bool = false,
    _reserved_bit_15: bool = false,
    _reserved_bit_16: bool = false,
    _reserved_bit_17: bool = false,
    _reserved_bit_18: bool = false,
    _reserved_bit_19: bool = false,
    _reserved_bit_20: bool = false,
    _reserved_bit_21: bool = false,
    _reserved_bit_22: bool = false,
    _reserved_bit_23: bool = false,
    _reserved_bit_24: bool = false,
    _reserved_bit_25: bool = false,
    _reserved_bit_26: bool = false,
    _reserved_bit_27: bool = false,
    _reserved_bit_28: bool = false,
    _reserved_bit_29: bool = false,
    _reserved_bit_30: bool = false,
    _reserved_bit_31: bool = false,
};

pub const PipelineCreateFlags = packed struct(Flags) {
    disable_optimization: bool = false,
    allow_derivatives: bool = false,
    derivative: bool = false,
    view_index_from_device_index: bool = false,
    dispatch_base: bool = false,
    defer_compile_nv: bool = false,
    capture_statistics_khr: bool = false,
    capture_internal_representations_khr: bool = false,
    fail_on_pipeline_compile_required: bool = false,
    early_return_on_failure: bool = false,
    link_time_optimization_ext: bool = false,
    library_khr: bool = false,
    ray_tracing_skip_triangles_khr: bool = false,
    ray_tracing_skip_aabbs_khr: bool = false,
    ray_tracing_no_null_any_hit_shaders_khr: bool = false,
    ray_tracing_no_null_closest_hit_shaders_khr: bool = false,
    ray_tracing_no_null_miss_shaders_khr: bool = false,
    ray_tracing_no_null_intersection_shaders_khr: bool = false,
    indirect_bindable_nv: bool = false,
    ray_tracing_shader_group_handle_capture_replay_khr: bool = false,
    ray_tracing_allow_motion_nv: bool = false,
    rendering_fragment_shading_rate_attachment_khr: bool = false,
    rendering_fragment_density_map_attachment_ext: bool = false,
    retain_link_time_optimization_info_ext: bool = false,
    ray_tracing_opacity_micromap_khr: bool = false,
    color_attachment_feedback_loop_ext: bool = false,
    depth_stencil_attachment_feedback_loop_ext: bool = false,
    no_protected_access: bool = false,
    ray_tracing_displacement_micromap_nv: bool = false,
    descriptor_buffer_ext: bool = false,
    protected_access_only: bool = false,
    _reserved_bit_31: bool = false,
};

pub const PipelineDepthStencilStateCreateFlags = packed struct(Flags) {
    rasterization_order_attachment_depth_access_ext: bool = false,
    rasterization_order_attachment_stencil_access_ext: bool = false,
    _reserved_bit_2: bool = false,
    _reserved_bit_3: bool = false,
    _reserved_bit_4: bool = false,
    _reserved_bit_5: bool = false,
    _reserved_bit_6: bool = false,
    _reserved_bit_7: bool = false,
    _reserved_bit_8: bool = false,
    _reserved_bit_9: bool = false,
    _reserved_bit_10: bool = false,
    _reserved_bit_11: bool = false,
    _reserved_bit_12: bool = false,
    _reserved_bit_13: bool = false,
    _reserved_bit_14: bool = false,
    _reserved_bit_15: bool = false,
    _reserved_bit_16: bool = false,
    _reserved_bit_17: bool = false,
    _reserved_bit_18: bool = false,
    _reserved_bit_19: bool = false,
    _reserved_bit_20: bool = false,
    _reserved_bit_21: bool = false,
    _reserved_bit_22: bool = false,
    _reserved_bit_23: bool = false,
    _reserved_bit_24: bool = false,
    _reserved_bit_25: bool = false,
    _reserved_bit_26: bool = false,
    _reserved_bit_27: bool = false,
    _reserved_bit_28: bool = false,
    _reserved_bit_29: bool = false,
    _reserved_bit_30: bool = false,
    _reserved_bit_31: bool = false,
};

pub const PipelineLayoutCreateFlags = packed struct(Flags) {
    _reserved_bit_0: bool = false,
    independent_sets_ext: bool = false,
    no_task_shader_khr: bool = false,
    _reserved_bit_3: bool = false,
    _reserved_bit_4: bool = false,
    _reserved_bit_5: bool = false,
    _reserved_bit_6: bool = false,
    _reserved_bit_7: bool = false,
    _reserved_bit_8: bool = false,
    _reserved_bit_9: bool = false,
    _reserved_bit_10: bool = false,
    _reserved_bit_11: bool = false,
    _reserved_bit_12: bool = false,
    _reserved_bit_13: bool = false,
    _reserved_bit_14: bool = false,
    _reserved_bit_15: bool = false,
    _reserved_bit_16: bool = false,
    _reserved_bit_17: bool = false,
    _reserved_bit_18: bool = false,
    _reserved_bit_19: bool = false,
    _reserved_bit_20: bool = false,
    _reserved_bit_21: bool = false,
    _reserved_bit_22: bool = false,
    _reserved_bit_23: bool = false,
    _reserved_bit_24: bool = false,
    _reserved_bit_25: bool = false,
    _reserved_bit_26: bool = false,
    _reserved_bit_27: bool = false,
    _reserved_bit_28: bool = false,
    _reserved_bit_29: bool = false,
    _reserved_bit_30: bool = false,
    _reserved_bit_31: bool = false,
};

pub const PipelineShaderStageCreateFlags = packed struct(Flags) {
    allow_varying_subgroup_size: bool = false,
    require_full_subgroups: bool = false,
    _reserved_bit_2: bool = false,
    _reserved_bit_3: bool = false,
    _reserved_bit_4: bool = false,
    _reserved_bit_5: bool = false,
    _reserved_bit_6: bool = false,
    _reserved_bit_7: bool = false,
    _reserved_bit_8: bool = false,
    _reserved_bit_9: bool = false,
    _reserved_bit_10: bool = false,
    _reserved_bit_11: bool = false,
    _reserved_bit_12: bool = false,
    _reserved_bit_13: bool = false,
    _reserved_bit_14: bool = false,
    _reserved_bit_15: bool = false,
    _reserved_bit_16: bool = false,
    _reserved_bit_17: bool = false,
    _reserved_bit_18: bool = false,
    _reserved_bit_19: bool = false,
    _reserved_bit_20: bool = false,
    _reserved_bit_21: bool = false,
    _reserved_bit_22: bool = false,
    _reserved_bit_23: bool = false,
    _reserved_bit_24: bool = false,
    _reserved_bit_25: bool = false,
    _reserved_bit_26: bool = false,
    _reserved_bit_27: bool = false,
    _reserved_bit_28: bool = false,
    _reserved_bit_29: bool = false,
    _reserved_bit_30: bool = false,
    _reserved_bit_31: bool = false,
};

pub const PipelineStageFlags2 = packed struct(Flags64) {
    top_of_pipe: bool = false,
    draw_indirect: bool = false,
    vertex_input: bool = false,
    vertex_shader: bool = false,
    tessellation_control_shader: bool = false,
    tessellation_evaluation_shader: bool = false,
    geometry_shader: bool = false,
    fragment_shader: bool = false,
    early_fragment_tests: bool = false,
    late_fragment_tests: bool = false,
    color_attachment_output: bool = false,
    compute_shader: bool = false,
    all_transfer: bool = false,
    bottom_of_pipe: bool = false,
    host: bool = false,
    all_graphics: bool = false,
    all_commands: bool = false,
    command_preprocess_ext: bool = false,
    conditional_rendering_ext: bool = false,
    task_shader_ext: bool = false,
    mesh_shader_ext: bool = false,
    ray_tracing_shader_khr: bool = false,
    fragment_shading_rate_attachment_khr: bool = false,
    fragment_density_process_ext: bool = false,
    transform_feedback_ext: bool = false,
    acceleration_structure_build_khr: bool = false,
    video_decode_khr: bool = false,
    video_encode_khr: bool = false,
    acceleration_structure_copy_khr: bool = false,
    optical_flow_nv: bool = false,
    micromap_build_ext: bool = false,
    _reserved_bit_31: bool = false,
    copy: bool = false,
    resolve: bool = false,
    blit: bool = false,
    clear: bool = false,
    index_input: bool = false,
    vertex_attribute_input: bool = false,
    pre_rasterization_shaders: bool = false,
    subpass_shader_huawei: bool = false,
    invocation_mask_huawei: bool = false,
    cluster_culling_shader_huawei: bool = false,
    data_graph_arm: bool = false,
    _reserved_bit_43: bool = false,
    convert_cooperative_vector_matrix_nv: bool = false,
    memory_decompression_ext: bool = false,
    copy_indirect_khr: bool = false,
    _reserved_bit_47: bool = false,
    _reserved_bit_48: bool = false,
    _reserved_bit_49: bool = false,
    _reserved_bit_50: bool = false,
    _reserved_bit_51: bool = false,
    _reserved_bit_52: bool = false,
    _reserved_bit_53: bool = false,
    _reserved_bit_54: bool = false,
    _reserved_bit_55: bool = false,
    _reserved_bit_56: bool = false,
    _reserved_bit_57: bool = false,
    _reserved_bit_58: bool = false,
    _reserved_bit_59: bool = false,
    _reserved_bit_60: bool = false,
    _reserved_bit_61: bool = false,
    _reserved_bit_62: bool = false,
    _reserved_bit_63: bool = false,
};

pub const QueueFlags = packed struct(Flags) {
    graphics: bool = false,
    compute: bool = false,
    transfer: bool = false,
    sparse_binding: bool = false,
    protected: bool = false,
    video_decode_khr: bool = false,
    video_encode_khr: bool = false,
    _reserved_bit_7: bool = false,
    optical_flow_nv: bool = false,
    _reserved_bit_9: bool = false,
    data_graph_arm: bool = false,
    _reserved_bit_11: bool = false,
    _reserved_bit_12: bool = false,
    _reserved_bit_13: bool = false,
    _reserved_bit_14: bool = false,
    _reserved_bit_15: bool = false,
    _reserved_bit_16: bool = false,
    _reserved_bit_17: bool = false,
    _reserved_bit_18: bool = false,
    _reserved_bit_19: bool = false,
    _reserved_bit_20: bool = false,
    _reserved_bit_21: bool = false,
    _reserved_bit_22: bool = false,
    _reserved_bit_23: bool = false,
    _reserved_bit_24: bool = false,
    _reserved_bit_25: bool = false,
    _reserved_bit_26: bool = false,
    _reserved_bit_27: bool = false,
    _reserved_bit_28: bool = false,
    _reserved_bit_29: bool = false,
    _reserved_bit_30: bool = false,
    _reserved_bit_31: bool = false,
};

pub const RenderingFlags = packed struct(Flags) {
    contents_secondary_command_buffers: bool = false,
    suspending: bool = false,
    resuming: bool = false,
    enable_legacy_dithering_ext: bool = false,
    contents_inline_khr: bool = false,
    per_layer_fragment_density_valve: bool = false,
    fragment_region_ext: bool = false,
    custom_resolve_ext: bool = false,
    local_read_concurrent_access_control_khr: bool = false,
    _reserved_bit_9: bool = false,
    _reserved_bit_10: bool = false,
    _reserved_bit_11: bool = false,
    _reserved_bit_12: bool = false,
    _reserved_bit_13: bool = false,
    _reserved_bit_14: bool = false,
    _reserved_bit_15: bool = false,
    _reserved_bit_16: bool = false,
    _reserved_bit_17: bool = false,
    _reserved_bit_18: bool = false,
    _reserved_bit_19: bool = false,
    _reserved_bit_20: bool = false,
    _reserved_bit_21: bool = false,
    _reserved_bit_22: bool = false,
    _reserved_bit_23: bool = false,
    _reserved_bit_24: bool = false,
    _reserved_bit_25: bool = false,
    _reserved_bit_26: bool = false,
    _reserved_bit_27: bool = false,
    _reserved_bit_28: bool = false,
    _reserved_bit_29: bool = false,
    _reserved_bit_30: bool = false,
    _reserved_bit_31: bool = false,
};

pub const ResolveModeFlags = packed struct(Flags) {
    sample_zero: bool = false,
    average: bool = false,
    min: bool = false,
    max: bool = false,
    external_format_downsample_android: bool = false,
    custom_ext: bool = false,
    _reserved_bit_6: bool = false,
    _reserved_bit_7: bool = false,
    _reserved_bit_8: bool = false,
    _reserved_bit_9: bool = false,
    _reserved_bit_10: bool = false,
    _reserved_bit_11: bool = false,
    _reserved_bit_12: bool = false,
    _reserved_bit_13: bool = false,
    _reserved_bit_14: bool = false,
    _reserved_bit_15: bool = false,
    _reserved_bit_16: bool = false,
    _reserved_bit_17: bool = false,
    _reserved_bit_18: bool = false,
    _reserved_bit_19: bool = false,
    _reserved_bit_20: bool = false,
    _reserved_bit_21: bool = false,
    _reserved_bit_22: bool = false,
    _reserved_bit_23: bool = false,
    _reserved_bit_24: bool = false,
    _reserved_bit_25: bool = false,
    _reserved_bit_26: bool = false,
    _reserved_bit_27: bool = false,
    _reserved_bit_28: bool = false,
    _reserved_bit_29: bool = false,
    _reserved_bit_30: bool = false,
    _reserved_bit_31: bool = false,
};

pub const SampleCountFlags = packed struct(Flags) {
    @"1": bool = false,
    @"2": bool = false,
    @"4": bool = false,
    @"8": bool = false,
    @"16": bool = false,
    @"32": bool = false,
    @"64": bool = false,
    _reserved_bit_7: bool = false,
    _reserved_bit_8: bool = false,
    _reserved_bit_9: bool = false,
    _reserved_bit_10: bool = false,
    _reserved_bit_11: bool = false,
    _reserved_bit_12: bool = false,
    _reserved_bit_13: bool = false,
    _reserved_bit_14: bool = false,
    _reserved_bit_15: bool = false,
    _reserved_bit_16: bool = false,
    _reserved_bit_17: bool = false,
    _reserved_bit_18: bool = false,
    _reserved_bit_19: bool = false,
    _reserved_bit_20: bool = false,
    _reserved_bit_21: bool = false,
    _reserved_bit_22: bool = false,
    _reserved_bit_23: bool = false,
    _reserved_bit_24: bool = false,
    _reserved_bit_25: bool = false,
    _reserved_bit_26: bool = false,
    _reserved_bit_27: bool = false,
    _reserved_bit_28: bool = false,
    _reserved_bit_29: bool = false,
    _reserved_bit_30: bool = false,
    _reserved_bit_31: bool = false,
};

pub const SamplerCreateFlags = packed struct(Flags) {
    subsampled_ext: bool = false,
    subsampled_coarse_reconstruction_ext: bool = false,
    non_seamless_cube_map_ext: bool = false,
    descriptor_buffer_capture_replay_ext: bool = false,
    image_processing_qcom: bool = false,
    _reserved_bit_5: bool = false,
    _reserved_bit_6: bool = false,
    _reserved_bit_7: bool = false,
    _reserved_bit_8: bool = false,
    _reserved_bit_9: bool = false,
    _reserved_bit_10: bool = false,
    _reserved_bit_11: bool = false,
    _reserved_bit_12: bool = false,
    _reserved_bit_13: bool = false,
    _reserved_bit_14: bool = false,
    _reserved_bit_15: bool = false,
    _reserved_bit_16: bool = false,
    _reserved_bit_17: bool = false,
    _reserved_bit_18: bool = false,
    _reserved_bit_19: bool = false,
    _reserved_bit_20: bool = false,
    _reserved_bit_21: bool = false,
    _reserved_bit_22: bool = false,
    _reserved_bit_23: bool = false,
    _reserved_bit_24: bool = false,
    _reserved_bit_25: bool = false,
    _reserved_bit_26: bool = false,
    _reserved_bit_27: bool = false,
    _reserved_bit_28: bool = false,
    _reserved_bit_29: bool = false,
    _reserved_bit_30: bool = false,
    _reserved_bit_31: bool = false,
};

pub const SemaphoreWaitFlags = packed struct(Flags) {
    any: bool = false,
    _reserved_bit_1: bool = false,
    _reserved_bit_2: bool = false,
    _reserved_bit_3: bool = false,
    _reserved_bit_4: bool = false,
    _reserved_bit_5: bool = false,
    _reserved_bit_6: bool = false,
    _reserved_bit_7: bool = false,
    _reserved_bit_8: bool = false,
    _reserved_bit_9: bool = false,
    _reserved_bit_10: bool = false,
    _reserved_bit_11: bool = false,
    _reserved_bit_12: bool = false,
    _reserved_bit_13: bool = false,
    _reserved_bit_14: bool = false,
    _reserved_bit_15: bool = false,
    _reserved_bit_16: bool = false,
    _reserved_bit_17: bool = false,
    _reserved_bit_18: bool = false,
    _reserved_bit_19: bool = false,
    _reserved_bit_20: bool = false,
    _reserved_bit_21: bool = false,
    _reserved_bit_22: bool = false,
    _reserved_bit_23: bool = false,
    _reserved_bit_24: bool = false,
    _reserved_bit_25: bool = false,
    _reserved_bit_26: bool = false,
    _reserved_bit_27: bool = false,
    _reserved_bit_28: bool = false,
    _reserved_bit_29: bool = false,
    _reserved_bit_30: bool = false,
    _reserved_bit_31: bool = false,
};

pub const ShaderStageFlags = packed struct(Flags) {
    vertex: bool = false,
    tessellation_control: bool = false,
    tessellation_evaluation: bool = false,
    geometry: bool = false,
    fragment: bool = false,
    compute: bool = false,
    task_ext: bool = false,
    mesh_ext: bool = false,
    raygen_khr: bool = false,
    any_hit_khr: bool = false,
    closest_hit_khr: bool = false,
    miss_khr: bool = false,
    intersection_khr: bool = false,
    callable_khr: bool = false,
    subpass_shading_huawei: bool = false,
    _reserved_bit_15: bool = false,
    _reserved_bit_16: bool = false,
    _reserved_bit_17: bool = false,
    _reserved_bit_18: bool = false,
    cluster_culling_huawei: bool = false,
    _reserved_bit_20: bool = false,
    _reserved_bit_21: bool = false,
    _reserved_bit_22: bool = false,
    _reserved_bit_23: bool = false,
    _reserved_bit_24: bool = false,
    _reserved_bit_25: bool = false,
    _reserved_bit_26: bool = false,
    _reserved_bit_27: bool = false,
    _reserved_bit_28: bool = false,
    _reserved_bit_29: bool = false,
    _reserved_bit_30: bool = false,
    _reserved_bit_31: bool = false,
};

pub const SubmitFlags = packed struct(Flags) {
    protected: bool = false,
    _reserved_bit_1: bool = false,
    _reserved_bit_2: bool = false,
    _reserved_bit_3: bool = false,
    _reserved_bit_4: bool = false,
    _reserved_bit_5: bool = false,
    _reserved_bit_6: bool = false,
    _reserved_bit_7: bool = false,
    _reserved_bit_8: bool = false,
    _reserved_bit_9: bool = false,
    _reserved_bit_10: bool = false,
    _reserved_bit_11: bool = false,
    _reserved_bit_12: bool = false,
    _reserved_bit_13: bool = false,
    _reserved_bit_14: bool = false,
    _reserved_bit_15: bool = false,
    _reserved_bit_16: bool = false,
    _reserved_bit_17: bool = false,
    _reserved_bit_18: bool = false,
    _reserved_bit_19: bool = false,
    _reserved_bit_20: bool = false,
    _reserved_bit_21: bool = false,
    _reserved_bit_22: bool = false,
    _reserved_bit_23: bool = false,
    _reserved_bit_24: bool = false,
    _reserved_bit_25: bool = false,
    _reserved_bit_26: bool = false,
    _reserved_bit_27: bool = false,
    _reserved_bit_28: bool = false,
    _reserved_bit_29: bool = false,
    _reserved_bit_30: bool = false,
    _reserved_bit_31: bool = false,
};

pub const SurfaceTransformFlagsKHR = packed struct(Flags) {
    identity: bool = false,
    rotate_90: bool = false,
    rotate_180: bool = false,
    rotate_270: bool = false,
    horizontal_mirror: bool = false,
    horizontal_mirror_rotate_90: bool = false,
    horizontal_mirror_rotate_180: bool = false,
    horizontal_mirror_rotate_270: bool = false,
    inherit: bool = false,
    _reserved_bit_9: bool = false,
    _reserved_bit_10: bool = false,
    _reserved_bit_11: bool = false,
    _reserved_bit_12: bool = false,
    _reserved_bit_13: bool = false,
    _reserved_bit_14: bool = false,
    _reserved_bit_15: bool = false,
    _reserved_bit_16: bool = false,
    _reserved_bit_17: bool = false,
    _reserved_bit_18: bool = false,
    _reserved_bit_19: bool = false,
    _reserved_bit_20: bool = false,
    _reserved_bit_21: bool = false,
    _reserved_bit_22: bool = false,
    _reserved_bit_23: bool = false,
    _reserved_bit_24: bool = false,
    _reserved_bit_25: bool = false,
    _reserved_bit_26: bool = false,
    _reserved_bit_27: bool = false,
    _reserved_bit_28: bool = false,
    _reserved_bit_29: bool = false,
    _reserved_bit_30: bool = false,
    _reserved_bit_31: bool = false,
};

pub const SwapchainCreateFlagsKHR = packed struct(Flags) {
    split_instance_bind_regions: bool = false,
    protected: bool = false,
    mutable_format: bool = false,
    deferred_memory_allocation: bool = false,
    _reserved_bit_4: bool = false,
    _reserved_bit_5: bool = false,
    present_id_2: bool = false,
    present_wait_2: bool = false,
    multisampled_render_to_single_sampled_ext: bool = false,
    present_timing_ext: bool = false,
    _reserved_bit_10: bool = false,
    _reserved_bit_11: bool = false,
    _reserved_bit_12: bool = false,
    _reserved_bit_13: bool = false,
    _reserved_bit_14: bool = false,
    _reserved_bit_15: bool = false,
    _reserved_bit_16: bool = false,
    _reserved_bit_17: bool = false,
    _reserved_bit_18: bool = false,
    _reserved_bit_19: bool = false,
    _reserved_bit_20: bool = false,
    _reserved_bit_21: bool = false,
    _reserved_bit_22: bool = false,
    _reserved_bit_23: bool = false,
    _reserved_bit_24: bool = false,
    _reserved_bit_25: bool = false,
    _reserved_bit_26: bool = false,
    _reserved_bit_27: bool = false,
    _reserved_bit_28: bool = false,
    _reserved_bit_29: bool = false,
    _reserved_bit_30: bool = false,
    _reserved_bit_31: bool = false,
};

// ---- Constants: each C name lower-cased without `VK_` (VK_MAX_MEMORY_TYPES is `max_memory_types`) ----

pub const max_memory_types: u32 = 32;
pub const max_memory_heaps: u32 = 16;
pub const max_extension_name_size: u32 = 256;
pub const max_description_size: u32 = 256;
pub const max_physical_device_name_size: u32 = 256;
pub const uuid_size: u32 = 16;
pub const queue_family_ignored: u32 = 0xffff_ffff;
pub const remaining_mip_levels: u32 = 0xffff_ffff;
pub const remaining_array_layers: u32 = 0xffff_ffff;
/// VK_WHOLE_SIZE: the rest of the buffer.
pub const whole_size: DeviceSize = 0xffff_ffff_ffff_ffff;
/// VK_LOD_CLAMP_NONE: no upper bound on a sampler's level of detail.
pub const lod_clamp_none: f32 = 1000.0;

// ---- Structures (layouts from the Vulkan registry; checked against the C headers by `vk-abi-check`) ----

pub const AllocationCallbacks = opaque {};

pub const CommandBufferInheritanceInfo = opaque {};

pub const SpecializationInfo = opaque {};

pub const PipelineTessellationStateCreateInfo = opaque {};

pub const ApplicationInfo = extern struct {
    s_type: StructureType = .application_info,
    p_next: ?*const anyopaque = null,
    p_application_name: ?[*:0]const u8 = null,
    application_version: u32 = 0,
    p_engine_name: ?[*:0]const u8 = null,
    engine_version: u32 = 0,
    api_version: u32 = 0,
};

pub const InstanceCreateInfo = extern struct {
    s_type: StructureType = .instance_create_info,
    p_next: ?*const anyopaque = null,
    flags: InstanceCreateFlags = .{},
    p_application_info: ?*const ApplicationInfo = null,
    enabled_layer_count: u32 = 0,
    pp_enabled_layer_names: ?[*]const [*:0]const u8 = null,
    enabled_extension_count: u32 = 0,
    pp_enabled_extension_names: ?[*]const [*:0]const u8 = null,
};

pub const LayerProperties = extern struct {
    layer_name: [256]u8 = @splat(0),
    spec_version: u32 = 0,
    implementation_version: u32 = 0,
    description: [256]u8 = @splat(0),
};

pub const ExtensionProperties = extern struct {
    extension_name: [256]u8 = @splat(0),
    spec_version: u32 = 0,
};

pub const Extent2D = extern struct {
    width: u32 = 0,
    height: u32 = 0,
};

pub const Extent3D = extern struct {
    width: u32 = 0,
    height: u32 = 0,
    depth: u32 = 0,
};

pub const Offset2D = extern struct {
    x: i32 = 0,
    y: i32 = 0,
};

pub const Offset3D = extern struct {
    x: i32 = 0,
    y: i32 = 0,
    z: i32 = 0,
};

pub const Rect2D = extern struct {
    offset: Offset2D = .{},
    extent: Extent2D = .{},
};

pub const PhysicalDeviceLimits = extern struct {
    max_image_dimension_1d: u32 = 0,
    max_image_dimension_2d: u32 = 0,
    max_image_dimension_3d: u32 = 0,
    max_image_dimension_cube: u32 = 0,
    max_image_array_layers: u32 = 0,
    max_texel_buffer_elements: u32 = 0,
    max_uniform_buffer_range: u32 = 0,
    max_storage_buffer_range: u32 = 0,
    max_push_constants_size: u32 = 0,
    max_memory_allocation_count: u32 = 0,
    max_sampler_allocation_count: u32 = 0,
    buffer_image_granularity: DeviceSize = 0,
    sparse_address_space_size: DeviceSize = 0,
    max_bound_descriptor_sets: u32 = 0,
    max_per_stage_descriptor_samplers: u32 = 0,
    max_per_stage_descriptor_uniform_buffers: u32 = 0,
    max_per_stage_descriptor_storage_buffers: u32 = 0,
    max_per_stage_descriptor_sampled_images: u32 = 0,
    max_per_stage_descriptor_storage_images: u32 = 0,
    max_per_stage_descriptor_input_attachments: u32 = 0,
    max_per_stage_resources: u32 = 0,
    max_descriptor_set_samplers: u32 = 0,
    max_descriptor_set_uniform_buffers: u32 = 0,
    max_descriptor_set_uniform_buffers_dynamic: u32 = 0,
    max_descriptor_set_storage_buffers: u32 = 0,
    max_descriptor_set_storage_buffers_dynamic: u32 = 0,
    max_descriptor_set_sampled_images: u32 = 0,
    max_descriptor_set_storage_images: u32 = 0,
    max_descriptor_set_input_attachments: u32 = 0,
    max_vertex_input_attributes: u32 = 0,
    max_vertex_input_bindings: u32 = 0,
    max_vertex_input_attribute_offset: u32 = 0,
    max_vertex_input_binding_stride: u32 = 0,
    max_vertex_output_components: u32 = 0,
    max_tessellation_generation_level: u32 = 0,
    max_tessellation_patch_size: u32 = 0,
    max_tessellation_control_per_vertex_input_components: u32 = 0,
    max_tessellation_control_per_vertex_output_components: u32 = 0,
    max_tessellation_control_per_patch_output_components: u32 = 0,
    max_tessellation_control_total_output_components: u32 = 0,
    max_tessellation_evaluation_input_components: u32 = 0,
    max_tessellation_evaluation_output_components: u32 = 0,
    max_geometry_shader_invocations: u32 = 0,
    max_geometry_input_components: u32 = 0,
    max_geometry_output_components: u32 = 0,
    max_geometry_output_vertices: u32 = 0,
    max_geometry_total_output_components: u32 = 0,
    max_fragment_input_components: u32 = 0,
    max_fragment_output_attachments: u32 = 0,
    max_fragment_dual_src_attachments: u32 = 0,
    max_fragment_combined_output_resources: u32 = 0,
    max_compute_shared_memory_size: u32 = 0,
    max_compute_work_group_count: [3]u32 = @splat(0),
    max_compute_work_group_invocations: u32 = 0,
    max_compute_work_group_size: [3]u32 = @splat(0),
    sub_pixel_precision_bits: u32 = 0,
    sub_texel_precision_bits: u32 = 0,
    mipmap_precision_bits: u32 = 0,
    max_draw_indexed_index_value: u32 = 0,
    max_draw_indirect_count: u32 = 0,
    max_sampler_lod_bias: f32 = 0,
    max_sampler_anisotropy: f32 = 0,
    max_viewports: u32 = 0,
    max_viewport_dimensions: [2]u32 = @splat(0),
    viewport_bounds_range: [2]f32 = @splat(0),
    viewport_sub_pixel_bits: u32 = 0,
    min_memory_map_alignment: usize = 0,
    min_texel_buffer_offset_alignment: DeviceSize = 0,
    min_uniform_buffer_offset_alignment: DeviceSize = 0,
    min_storage_buffer_offset_alignment: DeviceSize = 0,
    min_texel_offset: i32 = 0,
    max_texel_offset: u32 = 0,
    min_texel_gather_offset: i32 = 0,
    max_texel_gather_offset: u32 = 0,
    min_interpolation_offset: f32 = 0,
    max_interpolation_offset: f32 = 0,
    sub_pixel_interpolation_offset_bits: u32 = 0,
    max_framebuffer_width: u32 = 0,
    max_framebuffer_height: u32 = 0,
    max_framebuffer_layers: u32 = 0,
    framebuffer_color_sample_counts: SampleCountFlags = .{},
    framebuffer_depth_sample_counts: SampleCountFlags = .{},
    framebuffer_stencil_sample_counts: SampleCountFlags = .{},
    framebuffer_no_attachments_sample_counts: SampleCountFlags = .{},
    max_color_attachments: u32 = 0,
    sampled_image_color_sample_counts: SampleCountFlags = .{},
    sampled_image_integer_sample_counts: SampleCountFlags = .{},
    sampled_image_depth_sample_counts: SampleCountFlags = .{},
    sampled_image_stencil_sample_counts: SampleCountFlags = .{},
    storage_image_sample_counts: SampleCountFlags = .{},
    max_sample_mask_words: u32 = 0,
    timestamp_compute_and_graphics: Bool32 = 0,
    timestamp_period: f32 = 0,
    max_clip_distances: u32 = 0,
    max_cull_distances: u32 = 0,
    max_combined_clip_and_cull_distances: u32 = 0,
    discrete_queue_priorities: u32 = 0,
    point_size_range: [2]f32 = @splat(0),
    line_width_range: [2]f32 = @splat(0),
    point_size_granularity: f32 = 0,
    line_width_granularity: f32 = 0,
    strict_lines: Bool32 = 0,
    standard_sample_locations: Bool32 = 0,
    optimal_buffer_copy_offset_alignment: DeviceSize = 0,
    optimal_buffer_copy_row_pitch_alignment: DeviceSize = 0,
    non_coherent_atom_size: DeviceSize = 0,
};

pub const PhysicalDeviceSparseProperties = extern struct {
    residency_standard_2dblock_shape: Bool32 = 0,
    residency_standard_2dmultisample_block_shape: Bool32 = 0,
    residency_standard_3dblock_shape: Bool32 = 0,
    residency_aligned_mip_size: Bool32 = 0,
    residency_non_resident_strict: Bool32 = 0,
};

pub const PhysicalDeviceProperties = extern struct {
    api_version: u32 = 0,
    driver_version: u32 = 0,
    vendor_id: u32 = 0,
    device_id: u32 = 0,
    device_type: PhysicalDeviceType = @fromBackingInt(@intCast(0)),
    device_name: [256]u8 = @splat(0),
    pipeline_cache_uuid: [16]u8 = @splat(0),
    limits: PhysicalDeviceLimits = .{},
    sparse_properties: PhysicalDeviceSparseProperties = .{},
};

pub const QueueFamilyProperties = extern struct {
    queue_flags: QueueFlags = .{},
    queue_count: u32 = 0,
    timestamp_valid_bits: u32 = 0,
    min_image_transfer_granularity: Extent3D = .{},
};

pub const PhysicalDeviceFeatures = extern struct {
    robust_buffer_access: Bool32 = 0,
    full_draw_index_uint_32: Bool32 = 0,
    image_cube_array: Bool32 = 0,
    independent_blend: Bool32 = 0,
    geometry_shader: Bool32 = 0,
    tessellation_shader: Bool32 = 0,
    sample_rate_shading: Bool32 = 0,
    dual_src_blend: Bool32 = 0,
    logic_op: Bool32 = 0,
    multi_draw_indirect: Bool32 = 0,
    draw_indirect_first_instance: Bool32 = 0,
    depth_clamp: Bool32 = 0,
    depth_bias_clamp: Bool32 = 0,
    fill_mode_non_solid: Bool32 = 0,
    depth_bounds: Bool32 = 0,
    wide_lines: Bool32 = 0,
    large_points: Bool32 = 0,
    alpha_to_one: Bool32 = 0,
    multi_viewport: Bool32 = 0,
    sampler_anisotropy: Bool32 = 0,
    texture_compression_etc_2: Bool32 = 0,
    texture_compression_astc_ldr: Bool32 = 0,
    texture_compression_bc: Bool32 = 0,
    occlusion_query_precise: Bool32 = 0,
    pipeline_statistics_query: Bool32 = 0,
    vertex_pipeline_stores_and_atomics: Bool32 = 0,
    fragment_stores_and_atomics: Bool32 = 0,
    shader_tessellation_and_geometry_point_size: Bool32 = 0,
    shader_image_gather_extended: Bool32 = 0,
    shader_storage_image_extended_formats: Bool32 = 0,
    shader_storage_image_multisample: Bool32 = 0,
    shader_storage_image_read_without_format: Bool32 = 0,
    shader_storage_image_write_without_format: Bool32 = 0,
    shader_uniform_buffer_array_dynamic_indexing: Bool32 = 0,
    shader_sampled_image_array_dynamic_indexing: Bool32 = 0,
    shader_storage_buffer_array_dynamic_indexing: Bool32 = 0,
    shader_storage_image_array_dynamic_indexing: Bool32 = 0,
    shader_clip_distance: Bool32 = 0,
    shader_cull_distance: Bool32 = 0,
    shader_float_64: Bool32 = 0,
    shader_int_64: Bool32 = 0,
    shader_int_16: Bool32 = 0,
    shader_resource_residency: Bool32 = 0,
    shader_resource_min_lod: Bool32 = 0,
    sparse_binding: Bool32 = 0,
    sparse_residency_buffer: Bool32 = 0,
    sparse_residency_image_2d: Bool32 = 0,
    sparse_residency_image_3d: Bool32 = 0,
    sparse_residency_2samples: Bool32 = 0,
    sparse_residency_4samples: Bool32 = 0,
    sparse_residency_8samples: Bool32 = 0,
    sparse_residency_16samples: Bool32 = 0,
    sparse_residency_aliased: Bool32 = 0,
    variable_multisample_rate: Bool32 = 0,
    inherited_queries: Bool32 = 0,
};

pub const PhysicalDeviceFeatures2 = extern struct {
    s_type: StructureType = .physical_device_features_2,
    p_next: ?*anyopaque = null,
    features: PhysicalDeviceFeatures = .{},
};

pub const PhysicalDeviceVulkan12Features = extern struct {
    s_type: StructureType = .physical_device_vulkan_1_2_features,
    p_next: ?*anyopaque = null,
    sampler_mirror_clamp_to_edge: Bool32 = 0,
    draw_indirect_count: Bool32 = 0,
    storage_buffer_8bit_access: Bool32 = 0,
    uniform_and_storage_buffer_8bit_access: Bool32 = 0,
    storage_push_constant_8: Bool32 = 0,
    shader_buffer_int_64atomics: Bool32 = 0,
    shader_shared_int_64atomics: Bool32 = 0,
    shader_float_16: Bool32 = 0,
    shader_int_8: Bool32 = 0,
    descriptor_indexing: Bool32 = 0,
    shader_input_attachment_array_dynamic_indexing: Bool32 = 0,
    shader_uniform_texel_buffer_array_dynamic_indexing: Bool32 = 0,
    shader_storage_texel_buffer_array_dynamic_indexing: Bool32 = 0,
    shader_uniform_buffer_array_non_uniform_indexing: Bool32 = 0,
    shader_sampled_image_array_non_uniform_indexing: Bool32 = 0,
    shader_storage_buffer_array_non_uniform_indexing: Bool32 = 0,
    shader_storage_image_array_non_uniform_indexing: Bool32 = 0,
    shader_input_attachment_array_non_uniform_indexing: Bool32 = 0,
    shader_uniform_texel_buffer_array_non_uniform_indexing: Bool32 = 0,
    shader_storage_texel_buffer_array_non_uniform_indexing: Bool32 = 0,
    descriptor_binding_uniform_buffer_update_after_bind: Bool32 = 0,
    descriptor_binding_sampled_image_update_after_bind: Bool32 = 0,
    descriptor_binding_storage_image_update_after_bind: Bool32 = 0,
    descriptor_binding_storage_buffer_update_after_bind: Bool32 = 0,
    descriptor_binding_uniform_texel_buffer_update_after_bind: Bool32 = 0,
    descriptor_binding_storage_texel_buffer_update_after_bind: Bool32 = 0,
    descriptor_binding_update_unused_while_pending: Bool32 = 0,
    descriptor_binding_partially_bound: Bool32 = 0,
    descriptor_binding_variable_descriptor_count: Bool32 = 0,
    runtime_descriptor_array: Bool32 = 0,
    sampler_filter_minmax: Bool32 = 0,
    scalar_block_layout: Bool32 = 0,
    imageless_framebuffer: Bool32 = 0,
    uniform_buffer_standard_layout: Bool32 = 0,
    shader_subgroup_extended_types: Bool32 = 0,
    separate_depth_stencil_layouts: Bool32 = 0,
    host_query_reset: Bool32 = 0,
    timeline_semaphore: Bool32 = 0,
    buffer_device_address: Bool32 = 0,
    buffer_device_address_capture_replay: Bool32 = 0,
    buffer_device_address_multi_device: Bool32 = 0,
    vulkan_memory_model: Bool32 = 0,
    vulkan_memory_model_device_scope: Bool32 = 0,
    vulkan_memory_model_availability_visibility_chains: Bool32 = 0,
    shader_output_viewport_index: Bool32 = 0,
    shader_output_layer: Bool32 = 0,
    subgroup_broadcast_dynamic_id: Bool32 = 0,
};

pub const PhysicalDeviceVulkan13Features = extern struct {
    s_type: StructureType = .physical_device_vulkan_1_3_features,
    p_next: ?*anyopaque = null,
    robust_image_access: Bool32 = 0,
    inline_uniform_block: Bool32 = 0,
    descriptor_binding_inline_uniform_block_update_after_bind: Bool32 = 0,
    pipeline_creation_cache_control: Bool32 = 0,
    private_data: Bool32 = 0,
    shader_demote_to_helper_invocation: Bool32 = 0,
    shader_terminate_invocation: Bool32 = 0,
    subgroup_size_control: Bool32 = 0,
    compute_full_subgroups: Bool32 = 0,
    synchronization_2: Bool32 = 0,
    texture_compression_astc_hdr: Bool32 = 0,
    shader_zero_initialize_workgroup_memory: Bool32 = 0,
    dynamic_rendering: Bool32 = 0,
    shader_integer_dot_product: Bool32 = 0,
    maintenance_4: Bool32 = 0,
};

pub const DeviceQueueCreateInfo = extern struct {
    s_type: StructureType = .device_queue_create_info,
    p_next: ?*const anyopaque = null,
    flags: DeviceQueueCreateFlags = .{},
    queue_family_index: u32 = 0,
    queue_count: u32 = 0,
    p_queue_priorities: ?[*]const f32 = null,
};

pub const DeviceCreateInfo = extern struct {
    s_type: StructureType = .device_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    queue_create_info_count: u32 = 0,
    p_queue_create_infos: ?[*]const DeviceQueueCreateInfo = null,
    enabled_layer_count: u32 = 0,
    pp_enabled_layer_names: ?[*]const [*:0]const u8 = null,
    enabled_extension_count: u32 = 0,
    pp_enabled_extension_names: ?[*]const [*:0]const u8 = null,
    p_enabled_features: ?*const PhysicalDeviceFeatures = null,
};

pub const SurfaceCapabilitiesKHR = extern struct {
    min_image_count: u32 = 0,
    max_image_count: u32 = 0,
    current_extent: Extent2D = .{},
    min_image_extent: Extent2D = .{},
    max_image_extent: Extent2D = .{},
    max_image_array_layers: u32 = 0,
    supported_transforms: SurfaceTransformFlagsKHR = .{},
    current_transform: SurfaceTransformFlagsKHR = .{},
    supported_composite_alpha: CompositeAlphaFlagsKHR = .{},
    supported_usage_flags: ImageUsageFlags = .{},
};

pub const SurfaceFormatKHR = extern struct {
    format: Format = @fromBackingInt(@intCast(0)),
    color_space: ColorSpaceKHR = @fromBackingInt(@intCast(0)),
};

pub const SwapchainCreateInfoKHR = extern struct {
    s_type: StructureType = .swapchain_create_info_khr,
    p_next: ?*const anyopaque = null,
    flags: SwapchainCreateFlagsKHR = .{},
    surface: SurfaceKHR = .null_handle,
    min_image_count: u32 = 0,
    image_format: Format = @fromBackingInt(@intCast(0)),
    image_color_space: ColorSpaceKHR = @fromBackingInt(@intCast(0)),
    image_extent: Extent2D = .{},
    image_array_layers: u32 = 0,
    image_usage: ImageUsageFlags = .{},
    image_sharing_mode: SharingMode = @fromBackingInt(@intCast(0)),
    queue_family_index_count: u32 = 0,
    p_queue_family_indices: ?[*]const u32 = null,
    pre_transform: SurfaceTransformFlagsKHR = .{},
    composite_alpha: CompositeAlphaFlagsKHR = .{},
    present_mode: PresentModeKHR = @fromBackingInt(@intCast(0)),
    clipped: Bool32 = 0,
    old_swapchain: SwapchainKHR = .null_handle,
};

pub const PresentInfoKHR = extern struct {
    s_type: StructureType = .present_info_khr,
    p_next: ?*const anyopaque = null,
    wait_semaphore_count: u32 = 0,
    p_wait_semaphores: ?[*]const Semaphore = null,
    swapchain_count: u32 = 0,
    p_swapchains: ?[*]const SwapchainKHR = null,
    p_image_indices: ?[*]const u32 = null,
    p_results: ?[*]Result = null,
};

pub const Win32SurfaceCreateInfoKHR = extern struct {
    s_type: StructureType = .win32_surface_create_info_khr,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    hinstance: ?*anyopaque = null,
    hwnd: ?*anyopaque = null,
};

pub const ComponentMapping = extern struct {
    r: ComponentSwizzle = @fromBackingInt(@intCast(0)),
    g: ComponentSwizzle = @fromBackingInt(@intCast(0)),
    b: ComponentSwizzle = @fromBackingInt(@intCast(0)),
    a: ComponentSwizzle = @fromBackingInt(@intCast(0)),
};

pub const ImageSubresourceRange = extern struct {
    aspect_mask: ImageAspectFlags = .{},
    base_mip_level: u32 = 0,
    level_count: u32 = 0,
    base_array_layer: u32 = 0,
    layer_count: u32 = 0,
};

pub const ImageViewCreateInfo = extern struct {
    s_type: StructureType = .image_view_create_info,
    p_next: ?*const anyopaque = null,
    flags: ImageViewCreateFlags = .{},
    image: Image = .null_handle,
    view_type: ImageViewType = @fromBackingInt(@intCast(0)),
    format: Format = @fromBackingInt(@intCast(0)),
    components: ComponentMapping = .{},
    subresource_range: ImageSubresourceRange = .{},
};

pub const SemaphoreCreateInfo = extern struct {
    s_type: StructureType = .semaphore_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
};

pub const SemaphoreTypeCreateInfo = extern struct {
    s_type: StructureType = .semaphore_type_create_info,
    p_next: ?*const anyopaque = null,
    semaphore_type: SemaphoreType = @fromBackingInt(@intCast(0)),
    initial_value: u64 = 0,
};

pub const SemaphoreWaitInfo = extern struct {
    s_type: StructureType = .semaphore_wait_info,
    p_next: ?*const anyopaque = null,
    flags: SemaphoreWaitFlags = .{},
    semaphore_count: u32 = 0,
    p_semaphores: ?[*]const Semaphore = null,
    p_values: ?[*]const u64 = null,
};

pub const CommandPoolCreateInfo = extern struct {
    s_type: StructureType = .command_pool_create_info,
    p_next: ?*const anyopaque = null,
    flags: CommandPoolCreateFlags = .{},
    queue_family_index: u32 = 0,
};

pub const CommandBufferAllocateInfo = extern struct {
    s_type: StructureType = .command_buffer_allocate_info,
    p_next: ?*const anyopaque = null,
    command_pool: CommandPool = .null_handle,
    level: CommandBufferLevel = @fromBackingInt(@intCast(0)),
    command_buffer_count: u32 = 0,
};

pub const CommandBufferBeginInfo = extern struct {
    s_type: StructureType = .command_buffer_begin_info,
    p_next: ?*const anyopaque = null,
    flags: CommandBufferUsageFlags = .{},
    p_inheritance_info: ?*const CommandBufferInheritanceInfo = null,
};

pub const SemaphoreSubmitInfo = extern struct {
    s_type: StructureType = .semaphore_submit_info,
    p_next: ?*const anyopaque = null,
    semaphore: Semaphore = .null_handle,
    value: u64 = 0,
    stage_mask: PipelineStageFlags2 = .{},
    device_index: u32 = 0,
};

pub const CommandBufferSubmitInfo = extern struct {
    s_type: StructureType = .command_buffer_submit_info,
    p_next: ?*const anyopaque = null,
    command_buffer: CommandBuffer = .null_handle,
    device_mask: u32 = 0,
};

pub const SubmitInfo2 = extern struct {
    s_type: StructureType = .submit_info_2,
    p_next: ?*const anyopaque = null,
    flags: SubmitFlags = .{},
    wait_semaphore_info_count: u32 = 0,
    p_wait_semaphore_infos: ?[*]const SemaphoreSubmitInfo = null,
    command_buffer_info_count: u32 = 0,
    p_command_buffer_infos: ?[*]const CommandBufferSubmitInfo = null,
    signal_semaphore_info_count: u32 = 0,
    p_signal_semaphore_infos: ?[*]const SemaphoreSubmitInfo = null,
};

pub const MemoryBarrier2 = extern struct {
    s_type: StructureType = .memory_barrier_2,
    p_next: ?*const anyopaque = null,
    src_stage_mask: PipelineStageFlags2 = .{},
    src_access_mask: AccessFlags2 = .{},
    dst_stage_mask: PipelineStageFlags2 = .{},
    dst_access_mask: AccessFlags2 = .{},
};

pub const ImageMemoryBarrier2 = extern struct {
    s_type: StructureType = .image_memory_barrier_2,
    p_next: ?*const anyopaque = null,
    src_stage_mask: PipelineStageFlags2 = .{},
    src_access_mask: AccessFlags2 = .{},
    dst_stage_mask: PipelineStageFlags2 = .{},
    dst_access_mask: AccessFlags2 = .{},
    old_layout: ImageLayout = @fromBackingInt(@intCast(0)),
    new_layout: ImageLayout = @fromBackingInt(@intCast(0)),
    src_queue_family_index: u32 = 0,
    dst_queue_family_index: u32 = 0,
    image: Image = .null_handle,
    subresource_range: ImageSubresourceRange = .{},
};

pub const BufferMemoryBarrier2 = extern struct {
    s_type: StructureType = .buffer_memory_barrier_2,
    p_next: ?*const anyopaque = null,
    src_stage_mask: PipelineStageFlags2 = .{},
    src_access_mask: AccessFlags2 = .{},
    dst_stage_mask: PipelineStageFlags2 = .{},
    dst_access_mask: AccessFlags2 = .{},
    src_queue_family_index: u32 = 0,
    dst_queue_family_index: u32 = 0,
    buffer: Buffer = .null_handle,
    offset: DeviceSize = 0,
    size: DeviceSize = 0,
};

pub const DependencyInfo = extern struct {
    s_type: StructureType = .dependency_info,
    p_next: ?*const anyopaque = null,
    dependency_flags: DependencyFlags = .{},
    memory_barrier_count: u32 = 0,
    p_memory_barriers: ?[*]const MemoryBarrier2 = null,
    buffer_memory_barrier_count: u32 = 0,
    p_buffer_memory_barriers: ?[*]const BufferMemoryBarrier2 = null,
    image_memory_barrier_count: u32 = 0,
    p_image_memory_barriers: ?[*]const ImageMemoryBarrier2 = null,
};

pub const ClearColorValue = extern union {
    float_32: [4]f32,
    int_32: [4]i32,
    uint_32: [4]u32,
};

pub const ClearDepthStencilValue = extern struct {
    depth: f32 = 0,
    stencil: u32 = 0,
};

pub const ClearValue = extern union {
    color: ClearColorValue,
    depth_stencil: ClearDepthStencilValue,
};

pub const RenderingAttachmentInfo = extern struct {
    s_type: StructureType = .rendering_attachment_info,
    p_next: ?*const anyopaque = null,
    image_view: ImageView = .null_handle,
    image_layout: ImageLayout = @fromBackingInt(@intCast(0)),
    resolve_mode: ResolveModeFlags = .{},
    resolve_image_view: ImageView = .null_handle,
    resolve_image_layout: ImageLayout = @fromBackingInt(@intCast(0)),
    load_op: AttachmentLoadOp = @fromBackingInt(@intCast(0)),
    store_op: AttachmentStoreOp = @fromBackingInt(@intCast(0)),
    clear_value: ClearValue,
};

pub const RenderingInfo = extern struct {
    s_type: StructureType = .rendering_info,
    p_next: ?*const anyopaque = null,
    flags: RenderingFlags = .{},
    render_area: Rect2D = .{},
    layer_count: u32 = 0,
    view_mask: u32 = 0,
    color_attachment_count: u32 = 0,
    p_color_attachments: ?[*]const RenderingAttachmentInfo = null,
    p_depth_attachment: ?*const RenderingAttachmentInfo = null,
    p_stencil_attachment: ?*const RenderingAttachmentInfo = null,
};

pub const DebugUtilsLabelEXT = extern struct {
    s_type: StructureType = .debug_utils_label_ext,
    p_next: ?*const anyopaque = null,
    p_label_name: ?[*:0]const u8 = null,
    color: [4]f32 = @splat(0),
};

pub const DebugUtilsObjectNameInfoEXT = extern struct {
    s_type: StructureType = .debug_utils_object_name_info_ext,
    p_next: ?*const anyopaque = null,
    object_type: ObjectType = @fromBackingInt(@intCast(0)),
    object_handle: u64 = 0,
    p_object_name: ?[*:0]const u8 = null,
};

pub const DebugUtilsMessengerCreateInfoEXT = extern struct {
    s_type: StructureType = .debug_utils_messenger_create_info_ext,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    message_severity: DebugUtilsMessageSeverityFlagsEXT = .{},
    message_type: DebugUtilsMessageTypeFlagsEXT = .{},
    pfn_user_callback: ?*const anyopaque = null,
    p_user_data: ?*anyopaque = null,
};

pub const DebugUtilsMessengerCallbackDataEXT = extern struct {
    s_type: StructureType = .debug_utils_messenger_callback_data_ext,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    p_message_id_name: ?[*:0]const u8 = null,
    message_id_number: i32 = 0,
    p_message: ?[*:0]const u8 = null,
    queue_label_count: u32 = 0,
    p_queue_labels: ?[*]const DebugUtilsLabelEXT = null,
    cmd_buf_label_count: u32 = 0,
    p_cmd_buf_labels: ?[*]const DebugUtilsLabelEXT = null,
    object_count: u32 = 0,
    p_objects: ?[*]const DebugUtilsObjectNameInfoEXT = null,
};

pub const MemoryType = extern struct {
    property_flags: MemoryPropertyFlags = .{},
    heap_index: u32 = 0,
};

pub const MemoryHeap = extern struct {
    size: DeviceSize = 0,
    flags: MemoryHeapFlags = .{},
};

pub const PhysicalDeviceMemoryProperties = extern struct {
    memory_type_count: u32 = 0,
    memory_types: [32]MemoryType = @splat(.{}),
    memory_heap_count: u32 = 0,
    memory_heaps: [16]MemoryHeap = @splat(.{}),
};

pub const MemoryRequirements = extern struct {
    size: DeviceSize = 0,
    alignment: DeviceSize = 0,
    memory_type_bits: u32 = 0,
};

pub const MemoryAllocateInfo = extern struct {
    s_type: StructureType = .memory_allocate_info,
    p_next: ?*const anyopaque = null,
    allocation_size: DeviceSize = 0,
    memory_type_index: u32 = 0,
};

pub const BufferCreateInfo = extern struct {
    s_type: StructureType = .buffer_create_info,
    p_next: ?*const anyopaque = null,
    flags: BufferCreateFlags = .{},
    size: DeviceSize = 0,
    usage: BufferUsageFlags = .{},
    sharing_mode: SharingMode = @fromBackingInt(@intCast(0)),
    queue_family_index_count: u32 = 0,
    p_queue_family_indices: ?[*]const u32 = null,
};

pub const BufferCopy = extern struct {
    src_offset: DeviceSize = 0,
    dst_offset: DeviceSize = 0,
    size: DeviceSize = 0,
};

pub const ImageSubresourceLayers = extern struct {
    aspect_mask: ImageAspectFlags = .{},
    mip_level: u32 = 0,
    base_array_layer: u32 = 0,
    layer_count: u32 = 0,
};

pub const ImageCreateInfo = extern struct {
    s_type: StructureType = .image_create_info,
    p_next: ?*const anyopaque = null,
    flags: ImageCreateFlags = .{},
    image_type: ImageType = @fromBackingInt(@intCast(0)),
    format: Format = @fromBackingInt(@intCast(0)),
    extent: Extent3D = .{},
    mip_levels: u32 = 0,
    array_layers: u32 = 0,
    samples: SampleCountFlags = .{},
    tiling: ImageTiling = @fromBackingInt(@intCast(0)),
    usage: ImageUsageFlags = .{},
    sharing_mode: SharingMode = @fromBackingInt(@intCast(0)),
    queue_family_index_count: u32 = 0,
    p_queue_family_indices: ?[*]const u32 = null,
    initial_layout: ImageLayout = @fromBackingInt(@intCast(0)),
};

pub const BufferImageCopy = extern struct {
    buffer_offset: DeviceSize = 0,
    buffer_row_length: u32 = 0,
    buffer_image_height: u32 = 0,
    image_subresource: ImageSubresourceLayers = .{},
    image_offset: Offset3D = .{},
    image_extent: Extent3D = .{},
};

pub const SamplerCreateInfo = extern struct {
    s_type: StructureType = .sampler_create_info,
    p_next: ?*const anyopaque = null,
    flags: SamplerCreateFlags = .{},
    mag_filter: Filter = @fromBackingInt(@intCast(0)),
    min_filter: Filter = @fromBackingInt(@intCast(0)),
    mipmap_mode: SamplerMipmapMode = @fromBackingInt(@intCast(0)),
    address_mode_u: SamplerAddressMode = @fromBackingInt(@intCast(0)),
    address_mode_v: SamplerAddressMode = @fromBackingInt(@intCast(0)),
    address_mode_w: SamplerAddressMode = @fromBackingInt(@intCast(0)),
    mip_lod_bias: f32 = 0,
    anisotropy_enable: Bool32 = 0,
    max_anisotropy: f32 = 0,
    compare_enable: Bool32 = 0,
    compare_op: CompareOp = @fromBackingInt(@intCast(0)),
    min_lod: f32 = 0,
    max_lod: f32 = 0,
    border_color: BorderColor = @fromBackingInt(@intCast(0)),
    unnormalized_coordinates: Bool32 = 0,
};

pub const ShaderModuleCreateInfo = extern struct {
    s_type: StructureType = .shader_module_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    code_size: usize = 0,
    p_code: ?[*]const u32 = null,
};

pub const DescriptorSetLayoutBinding = extern struct {
    binding: u32 = 0,
    descriptor_type: DescriptorType = @fromBackingInt(@intCast(0)),
    descriptor_count: u32 = 0,
    stage_flags: ShaderStageFlags = .{},
    p_immutable_samplers: ?[*]const Sampler = null,
};

pub const DescriptorSetLayoutCreateInfo = extern struct {
    s_type: StructureType = .descriptor_set_layout_create_info,
    p_next: ?*const anyopaque = null,
    flags: DescriptorSetLayoutCreateFlags = .{},
    binding_count: u32 = 0,
    p_bindings: ?[*]const DescriptorSetLayoutBinding = null,
};

pub const DescriptorPoolSize = extern struct {
    type: DescriptorType = @fromBackingInt(@intCast(0)),
    descriptor_count: u32 = 0,
};

pub const DescriptorPoolCreateInfo = extern struct {
    s_type: StructureType = .descriptor_pool_create_info,
    p_next: ?*const anyopaque = null,
    flags: DescriptorPoolCreateFlags = .{},
    max_sets: u32 = 0,
    pool_size_count: u32 = 0,
    p_pool_sizes: ?[*]const DescriptorPoolSize = null,
};

pub const DescriptorSetAllocateInfo = extern struct {
    s_type: StructureType = .descriptor_set_allocate_info,
    p_next: ?*const anyopaque = null,
    descriptor_pool: DescriptorPool = .null_handle,
    descriptor_set_count: u32 = 0,
    p_set_layouts: ?[*]const DescriptorSetLayout = null,
};

pub const DescriptorBufferInfo = extern struct {
    buffer: Buffer = .null_handle,
    offset: DeviceSize = 0,
    range: DeviceSize = 0,
};

pub const DescriptorImageInfo = extern struct {
    sampler: Sampler = .null_handle,
    image_view: ImageView = .null_handle,
    image_layout: ImageLayout = @fromBackingInt(@intCast(0)),
};

pub const WriteDescriptorSet = extern struct {
    s_type: StructureType = .write_descriptor_set,
    p_next: ?*const anyopaque = null,
    dst_set: DescriptorSet = .null_handle,
    dst_binding: u32 = 0,
    dst_array_element: u32 = 0,
    descriptor_count: u32 = 0,
    descriptor_type: DescriptorType = @fromBackingInt(@intCast(0)),
    p_image_info: ?[*]const DescriptorImageInfo = null,
    p_buffer_info: ?[*]const DescriptorBufferInfo = null,
    p_texel_buffer_view: ?[*]const BufferView = null,
};

pub const CopyDescriptorSet = extern struct {
    s_type: StructureType = .copy_descriptor_set,
    p_next: ?*const anyopaque = null,
    src_set: DescriptorSet = .null_handle,
    src_binding: u32 = 0,
    src_array_element: u32 = 0,
    dst_set: DescriptorSet = .null_handle,
    dst_binding: u32 = 0,
    dst_array_element: u32 = 0,
    descriptor_count: u32 = 0,
};

pub const PushConstantRange = extern struct {
    stage_flags: ShaderStageFlags = .{},
    offset: u32 = 0,
    size: u32 = 0,
};

pub const PipelineLayoutCreateInfo = extern struct {
    s_type: StructureType = .pipeline_layout_create_info,
    p_next: ?*const anyopaque = null,
    flags: PipelineLayoutCreateFlags = .{},
    set_layout_count: u32 = 0,
    p_set_layouts: ?[*]const DescriptorSetLayout = null,
    push_constant_range_count: u32 = 0,
    p_push_constant_ranges: ?[*]const PushConstantRange = null,
};

pub const PipelineShaderStageCreateInfo = extern struct {
    s_type: StructureType = .pipeline_shader_stage_create_info,
    p_next: ?*const anyopaque = null,
    flags: PipelineShaderStageCreateFlags = .{},
    stage: ShaderStageFlags = .{},
    module: ShaderModule = .null_handle,
    p_name: ?[*:0]const u8 = null,
    p_specialization_info: ?*const SpecializationInfo = null,
};

pub const VertexInputBindingDescription = extern struct {
    binding: u32 = 0,
    stride: u32 = 0,
    input_rate: VertexInputRate = @fromBackingInt(@intCast(0)),
};

pub const VertexInputAttributeDescription = extern struct {
    location: u32 = 0,
    binding: u32 = 0,
    format: Format = @fromBackingInt(@intCast(0)),
    offset: u32 = 0,
};

pub const PipelineVertexInputStateCreateInfo = extern struct {
    s_type: StructureType = .pipeline_vertex_input_state_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    vertex_binding_description_count: u32 = 0,
    p_vertex_binding_descriptions: ?[*]const VertexInputBindingDescription = null,
    vertex_attribute_description_count: u32 = 0,
    p_vertex_attribute_descriptions: ?[*]const VertexInputAttributeDescription = null,
};

pub const PipelineInputAssemblyStateCreateInfo = extern struct {
    s_type: StructureType = .pipeline_input_assembly_state_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    topology: PrimitiveTopology = @fromBackingInt(@intCast(0)),
    primitive_restart_enable: Bool32 = 0,
};

pub const Viewport = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
    min_depth: f32 = 0,
    max_depth: f32 = 0,
};

pub const PipelineViewportStateCreateInfo = extern struct {
    s_type: StructureType = .pipeline_viewport_state_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    viewport_count: u32 = 0,
    p_viewports: ?[*]const Viewport = null,
    scissor_count: u32 = 0,
    p_scissors: ?[*]const Rect2D = null,
};

pub const PipelineRasterizationStateCreateInfo = extern struct {
    s_type: StructureType = .pipeline_rasterization_state_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    depth_clamp_enable: Bool32 = 0,
    rasterizer_discard_enable: Bool32 = 0,
    polygon_mode: PolygonMode = @fromBackingInt(@intCast(0)),
    cull_mode: CullModeFlags = .{},
    front_face: FrontFace = @fromBackingInt(@intCast(0)),
    depth_bias_enable: Bool32 = 0,
    depth_bias_constant_factor: f32 = 0,
    depth_bias_clamp: f32 = 0,
    depth_bias_slope_factor: f32 = 0,
    line_width: f32 = 0,
};

pub const PipelineMultisampleStateCreateInfo = extern struct {
    s_type: StructureType = .pipeline_multisample_state_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    rasterization_samples: SampleCountFlags = .{},
    sample_shading_enable: Bool32 = 0,
    min_sample_shading: f32 = 0,
    p_sample_mask: ?[*]const u32 = null,
    alpha_to_coverage_enable: Bool32 = 0,
    alpha_to_one_enable: Bool32 = 0,
};

pub const StencilOpState = extern struct {
    fail_op: StencilOp = @fromBackingInt(@intCast(0)),
    pass_op: StencilOp = @fromBackingInt(@intCast(0)),
    depth_fail_op: StencilOp = @fromBackingInt(@intCast(0)),
    compare_op: CompareOp = @fromBackingInt(@intCast(0)),
    compare_mask: u32 = 0,
    write_mask: u32 = 0,
    reference: u32 = 0,
};

pub const PipelineDepthStencilStateCreateInfo = extern struct {
    s_type: StructureType = .pipeline_depth_stencil_state_create_info,
    p_next: ?*const anyopaque = null,
    flags: PipelineDepthStencilStateCreateFlags = .{},
    depth_test_enable: Bool32 = 0,
    depth_write_enable: Bool32 = 0,
    depth_compare_op: CompareOp = @fromBackingInt(@intCast(0)),
    depth_bounds_test_enable: Bool32 = 0,
    stencil_test_enable: Bool32 = 0,
    front: StencilOpState = .{},
    back: StencilOpState = .{},
    min_depth_bounds: f32 = 0,
    max_depth_bounds: f32 = 0,
};

pub const PipelineColorBlendAttachmentState = extern struct {
    blend_enable: Bool32 = 0,
    src_color_blend_factor: BlendFactor = @fromBackingInt(@intCast(0)),
    dst_color_blend_factor: BlendFactor = @fromBackingInt(@intCast(0)),
    color_blend_op: BlendOp = @fromBackingInt(@intCast(0)),
    src_alpha_blend_factor: BlendFactor = @fromBackingInt(@intCast(0)),
    dst_alpha_blend_factor: BlendFactor = @fromBackingInt(@intCast(0)),
    alpha_blend_op: BlendOp = @fromBackingInt(@intCast(0)),
    color_write_mask: ColorComponentFlags = .{},
};

pub const PipelineColorBlendStateCreateInfo = extern struct {
    s_type: StructureType = .pipeline_color_blend_state_create_info,
    p_next: ?*const anyopaque = null,
    flags: PipelineColorBlendStateCreateFlags = .{},
    logic_op_enable: Bool32 = 0,
    logic_op: LogicOp = @fromBackingInt(@intCast(0)),
    attachment_count: u32 = 0,
    p_attachments: ?[*]const PipelineColorBlendAttachmentState = null,
    blend_constants: [4]f32 = @splat(0),
};

pub const PipelineDynamicStateCreateInfo = extern struct {
    s_type: StructureType = .pipeline_dynamic_state_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    dynamic_state_count: u32 = 0,
    p_dynamic_states: ?[*]const DynamicState = null,
};

pub const PipelineRenderingCreateInfo = extern struct {
    s_type: StructureType = .pipeline_rendering_create_info,
    p_next: ?*const anyopaque = null,
    view_mask: u32 = 0,
    color_attachment_count: u32 = 0,
    p_color_attachment_formats: ?[*]const Format = null,
    depth_attachment_format: Format = @fromBackingInt(@intCast(0)),
    stencil_attachment_format: Format = @fromBackingInt(@intCast(0)),
};

pub const GraphicsPipelineCreateInfo = extern struct {
    s_type: StructureType = .graphics_pipeline_create_info,
    p_next: ?*const anyopaque = null,
    flags: PipelineCreateFlags = .{},
    stage_count: u32 = 0,
    p_stages: ?[*]const PipelineShaderStageCreateInfo = null,
    p_vertex_input_state: ?*const PipelineVertexInputStateCreateInfo = null,
    p_input_assembly_state: ?*const PipelineInputAssemblyStateCreateInfo = null,
    p_tessellation_state: ?*const PipelineTessellationStateCreateInfo = null,
    p_viewport_state: ?*const PipelineViewportStateCreateInfo = null,
    p_rasterization_state: ?*const PipelineRasterizationStateCreateInfo = null,
    p_multisample_state: ?*const PipelineMultisampleStateCreateInfo = null,
    p_depth_stencil_state: ?*const PipelineDepthStencilStateCreateInfo = null,
    p_color_blend_state: ?*const PipelineColorBlendStateCreateInfo = null,
    p_dynamic_state: ?*const PipelineDynamicStateCreateInfo = null,
    layout: PipelineLayout = .null_handle,
    render_pass: RenderPass = .null_handle,
    subpass: u32 = 0,
    base_pipeline_handle: Pipeline = .null_handle,
    base_pipeline_index: i32 = 0,
};

pub const ComputePipelineCreateInfo = extern struct {
    s_type: StructureType = .compute_pipeline_create_info,
    p_next: ?*const anyopaque = null,
    flags: PipelineCreateFlags = .{},
    stage: PipelineShaderStageCreateInfo = .{},
    layout: PipelineLayout = .null_handle,
    base_pipeline_handle: Pipeline = .null_handle,
    base_pipeline_index: i32 = 0,
};

/// The debug messenger's callback: the validation layer's messages arrive here. Returning `bool_false` lets the
/// command that triggered the message proceed (`bool_true` would abort it, which only layer tests want).
pub const PfnDebugUtilsMessengerCallbackEXT = *const fn (
    message_severity: DebugUtilsMessageSeverityFlagsEXT,
    message_types: DebugUtilsMessageTypeFlagsEXT,
    callback_data: *const DebugUtilsMessengerCallbackDataEXT,
    user_data: ?*anyopaque,
) callconv(call_conv) Bool32;

// ---- Commands: one function-pointer type per command, filled by name into the dispatch tables ----

pub const PfnCreateInstance = *const fn (
    p_create_info: *const InstanceCreateInfo,
    p_allocator: ?*const AllocationCallbacks,
    p_instance: *Instance,
) callconv(call_conv) Result;

pub const PfnEnumerateInstanceLayerProperties = *const fn (
    p_property_count: *u32,
    p_properties: ?[*]LayerProperties,
) callconv(call_conv) Result;

pub const PfnEnumerateInstanceExtensionProperties = *const fn (
    p_layer_name: ?[*:0]const u8,
    p_property_count: *u32,
    p_properties: ?[*]ExtensionProperties,
) callconv(call_conv) Result;

pub const PfnEnumerateInstanceVersion = *const fn (
    p_api_version: *u32,
) callconv(call_conv) Result;

pub const PfnDestroyInstance = *const fn (
    instance: Instance,
    p_allocator: ?*const AllocationCallbacks,
) callconv(call_conv) void;

pub const PfnEnumeratePhysicalDevices = *const fn (
    instance: Instance,
    p_physical_device_count: *u32,
    p_physical_devices: ?[*]PhysicalDevice,
) callconv(call_conv) Result;

pub const PfnGetPhysicalDeviceProperties = *const fn (
    physical_device: PhysicalDevice,
    p_properties: *PhysicalDeviceProperties,
) callconv(call_conv) void;

pub const PfnGetPhysicalDeviceQueueFamilyProperties = *const fn (
    physical_device: PhysicalDevice,
    p_queue_family_property_count: *u32,
    p_queue_family_properties: ?[*]QueueFamilyProperties,
) callconv(call_conv) void;

pub const PfnGetPhysicalDeviceFeatures2 = *const fn (
    physical_device: PhysicalDevice,
    p_features: *PhysicalDeviceFeatures2,
) callconv(call_conv) void;

pub const PfnEnumerateDeviceExtensionProperties = *const fn (
    physical_device: PhysicalDevice,
    p_layer_name: ?[*:0]const u8,
    p_property_count: *u32,
    p_properties: ?[*]ExtensionProperties,
) callconv(call_conv) Result;

pub const PfnCreateDevice = *const fn (
    physical_device: PhysicalDevice,
    p_create_info: *const DeviceCreateInfo,
    p_allocator: ?*const AllocationCallbacks,
    p_device: *Device,
) callconv(call_conv) Result;

pub const PfnGetDeviceProcAddr = *const fn (
    device: Device,
    p_name: [*:0]const u8,
) callconv(call_conv) ?PfnVoidFunction;

pub const PfnGetPhysicalDeviceMemoryProperties = *const fn (
    physical_device: PhysicalDevice,
    p_memory_properties: *PhysicalDeviceMemoryProperties,
) callconv(call_conv) void;

pub const PfnCreateDebugUtilsMessengerEXT = *const fn (
    instance: Instance,
    p_create_info: *const DebugUtilsMessengerCreateInfoEXT,
    p_allocator: ?*const AllocationCallbacks,
    p_messenger: *DebugUtilsMessengerEXT,
) callconv(call_conv) Result;

pub const PfnDestroyDebugUtilsMessengerEXT = *const fn (
    instance: Instance,
    messenger: DebugUtilsMessengerEXT,
    p_allocator: ?*const AllocationCallbacks,
) callconv(call_conv) void;

pub const PfnCreateWin32SurfaceKHR = *const fn (
    instance: Instance,
    p_create_info: *const Win32SurfaceCreateInfoKHR,
    p_allocator: ?*const AllocationCallbacks,
    p_surface: *SurfaceKHR,
) callconv(call_conv) Result;

pub const PfnDestroySurfaceKHR = *const fn (
    instance: Instance,
    surface: SurfaceKHR,
    p_allocator: ?*const AllocationCallbacks,
) callconv(call_conv) void;

pub const PfnGetPhysicalDeviceSurfaceSupportKHR = *const fn (
    physical_device: PhysicalDevice,
    queue_family_index: u32,
    surface: SurfaceKHR,
    p_supported: *Bool32,
) callconv(call_conv) Result;

pub const PfnGetPhysicalDeviceSurfaceCapabilitiesKHR = *const fn (
    physical_device: PhysicalDevice,
    surface: SurfaceKHR,
    p_surface_capabilities: *SurfaceCapabilitiesKHR,
) callconv(call_conv) Result;

pub const PfnGetPhysicalDeviceSurfaceFormatsKHR = *const fn (
    physical_device: PhysicalDevice,
    surface: SurfaceKHR,
    p_surface_format_count: *u32,
    p_surface_formats: ?[*]SurfaceFormatKHR,
) callconv(call_conv) Result;

pub const PfnGetPhysicalDeviceSurfacePresentModesKHR = *const fn (
    physical_device: PhysicalDevice,
    surface: SurfaceKHR,
    p_present_mode_count: *u32,
    p_present_modes: ?[*]PresentModeKHR,
) callconv(call_conv) Result;

pub const PfnDestroyDevice = *const fn (
    device: Device,
    p_allocator: ?*const AllocationCallbacks,
) callconv(call_conv) void;

pub const PfnGetDeviceQueue = *const fn (
    device: Device,
    queue_family_index: u32,
    queue_index: u32,
    p_queue: *Queue,
) callconv(call_conv) void;

pub const PfnDeviceWaitIdle = *const fn (
    device: Device,
) callconv(call_conv) Result;

pub const PfnCreateImageView = *const fn (
    device: Device,
    p_create_info: *const ImageViewCreateInfo,
    p_allocator: ?*const AllocationCallbacks,
    p_view: *ImageView,
) callconv(call_conv) Result;

pub const PfnDestroyImageView = *const fn (
    device: Device,
    image_view: ImageView,
    p_allocator: ?*const AllocationCallbacks,
) callconv(call_conv) void;

pub const PfnCreateSemaphore = *const fn (
    device: Device,
    p_create_info: *const SemaphoreCreateInfo,
    p_allocator: ?*const AllocationCallbacks,
    p_semaphore: *Semaphore,
) callconv(call_conv) Result;

pub const PfnDestroySemaphore = *const fn (
    device: Device,
    semaphore: Semaphore,
    p_allocator: ?*const AllocationCallbacks,
) callconv(call_conv) void;

pub const PfnWaitSemaphores = *const fn (
    device: Device,
    p_wait_info: *const SemaphoreWaitInfo,
    timeout: u64,
) callconv(call_conv) Result;

pub const PfnGetSemaphoreCounterValue = *const fn (
    device: Device,
    semaphore: Semaphore,
    p_value: *u64,
) callconv(call_conv) Result;

pub const PfnCreateCommandPool = *const fn (
    device: Device,
    p_create_info: *const CommandPoolCreateInfo,
    p_allocator: ?*const AllocationCallbacks,
    p_command_pool: *CommandPool,
) callconv(call_conv) Result;

pub const PfnDestroyCommandPool = *const fn (
    device: Device,
    command_pool: CommandPool,
    p_allocator: ?*const AllocationCallbacks,
) callconv(call_conv) void;

pub const PfnAllocateCommandBuffers = *const fn (
    device: Device,
    p_allocate_info: *const CommandBufferAllocateInfo,
    p_command_buffers: [*]CommandBuffer,
) callconv(call_conv) Result;

pub const PfnResetCommandBuffer = *const fn (
    command_buffer: CommandBuffer,
    flags: CommandBufferResetFlags,
) callconv(call_conv) Result;

pub const PfnBeginCommandBuffer = *const fn (
    command_buffer: CommandBuffer,
    p_begin_info: *const CommandBufferBeginInfo,
) callconv(call_conv) Result;

pub const PfnEndCommandBuffer = *const fn (
    command_buffer: CommandBuffer,
) callconv(call_conv) Result;

pub const PfnCmdPipelineBarrier2 = *const fn (
    command_buffer: CommandBuffer,
    p_dependency_info: *const DependencyInfo,
) callconv(call_conv) void;

pub const PfnCmdBeginRendering = *const fn (
    command_buffer: CommandBuffer,
    p_rendering_info: *const RenderingInfo,
) callconv(call_conv) void;

pub const PfnCmdEndRendering = *const fn (
    command_buffer: CommandBuffer,
) callconv(call_conv) void;

pub const PfnQueueSubmit2 = *const fn (
    queue: Queue,
    submit_count: u32,
    p_submits: [*]const SubmitInfo2,
    fence: Fence,
) callconv(call_conv) Result;

pub const PfnSetDebugUtilsObjectNameEXT = *const fn (
    device: Device,
    p_name_info: *const DebugUtilsObjectNameInfoEXT,
) callconv(call_conv) Result;

pub const PfnCreateBuffer = *const fn (
    device: Device,
    p_create_info: *const BufferCreateInfo,
    p_allocator: ?*const AllocationCallbacks,
    p_buffer: *Buffer,
) callconv(call_conv) Result;

pub const PfnDestroyBuffer = *const fn (
    device: Device,
    buffer: Buffer,
    p_allocator: ?*const AllocationCallbacks,
) callconv(call_conv) void;

pub const PfnGetBufferMemoryRequirements = *const fn (
    device: Device,
    buffer: Buffer,
    p_memory_requirements: *MemoryRequirements,
) callconv(call_conv) void;

pub const PfnAllocateMemory = *const fn (
    device: Device,
    p_allocate_info: *const MemoryAllocateInfo,
    p_allocator: ?*const AllocationCallbacks,
    p_memory: *DeviceMemory,
) callconv(call_conv) Result;

pub const PfnFreeMemory = *const fn (
    device: Device,
    memory: DeviceMemory,
    p_allocator: ?*const AllocationCallbacks,
) callconv(call_conv) void;

pub const PfnBindBufferMemory = *const fn (
    device: Device,
    buffer: Buffer,
    memory: DeviceMemory,
    memory_offset: DeviceSize,
) callconv(call_conv) Result;

pub const PfnMapMemory = *const fn (
    device: Device,
    memory: DeviceMemory,
    offset: DeviceSize,
    size: DeviceSize,
    flags: MemoryMapFlags,
    pp_data: *?*anyopaque,
) callconv(call_conv) Result;

pub const PfnCmdCopyBuffer = *const fn (
    command_buffer: CommandBuffer,
    src_buffer: Buffer,
    dst_buffer: Buffer,
    region_count: u32,
    p_regions: [*]const BufferCopy,
) callconv(call_conv) void;

pub const PfnCmdFillBuffer = *const fn (
    command_buffer: CommandBuffer,
    dst_buffer: Buffer,
    dst_offset: DeviceSize,
    size: DeviceSize,
    data: u32,
) callconv(call_conv) void;

pub const PfnCreateImage = *const fn (
    device: Device,
    p_create_info: *const ImageCreateInfo,
    p_allocator: ?*const AllocationCallbacks,
    p_image: *Image,
) callconv(call_conv) Result;

pub const PfnDestroyImage = *const fn (
    device: Device,
    image: Image,
    p_allocator: ?*const AllocationCallbacks,
) callconv(call_conv) void;

pub const PfnGetImageMemoryRequirements = *const fn (
    device: Device,
    image: Image,
    p_memory_requirements: *MemoryRequirements,
) callconv(call_conv) void;

pub const PfnBindImageMemory = *const fn (
    device: Device,
    image: Image,
    memory: DeviceMemory,
    memory_offset: DeviceSize,
) callconv(call_conv) Result;

pub const PfnCmdCopyBufferToImage = *const fn (
    command_buffer: CommandBuffer,
    src_buffer: Buffer,
    dst_image: Image,
    dst_image_layout: ImageLayout,
    region_count: u32,
    p_regions: [*]const BufferImageCopy,
) callconv(call_conv) void;

pub const PfnCmdCopyImageToBuffer = *const fn (
    command_buffer: CommandBuffer,
    src_image: Image,
    src_image_layout: ImageLayout,
    dst_buffer: Buffer,
    region_count: u32,
    p_regions: [*]const BufferImageCopy,
) callconv(call_conv) void;

pub const PfnCmdClearColorImage = *const fn (
    command_buffer: CommandBuffer,
    image: Image,
    image_layout: ImageLayout,
    p_color: *const ClearColorValue,
    range_count: u32,
    p_ranges: [*]const ImageSubresourceRange,
) callconv(call_conv) void;

pub const PfnCmdClearDepthStencilImage = *const fn (
    command_buffer: CommandBuffer,
    image: Image,
    image_layout: ImageLayout,
    p_depth_stencil: *const ClearDepthStencilValue,
    range_count: u32,
    p_ranges: [*]const ImageSubresourceRange,
) callconv(call_conv) void;

pub const PfnCreateSampler = *const fn (
    device: Device,
    p_create_info: *const SamplerCreateInfo,
    p_allocator: ?*const AllocationCallbacks,
    p_sampler: *Sampler,
) callconv(call_conv) Result;

pub const PfnDestroySampler = *const fn (
    device: Device,
    sampler: Sampler,
    p_allocator: ?*const AllocationCallbacks,
) callconv(call_conv) void;

pub const PfnCreateShaderModule = *const fn (
    device: Device,
    p_create_info: *const ShaderModuleCreateInfo,
    p_allocator: ?*const AllocationCallbacks,
    p_shader_module: *ShaderModule,
) callconv(call_conv) Result;

pub const PfnDestroyShaderModule = *const fn (
    device: Device,
    shader_module: ShaderModule,
    p_allocator: ?*const AllocationCallbacks,
) callconv(call_conv) void;

pub const PfnCreateDescriptorSetLayout = *const fn (
    device: Device,
    p_create_info: *const DescriptorSetLayoutCreateInfo,
    p_allocator: ?*const AllocationCallbacks,
    p_set_layout: *DescriptorSetLayout,
) callconv(call_conv) Result;

pub const PfnDestroyDescriptorSetLayout = *const fn (
    device: Device,
    descriptor_set_layout: DescriptorSetLayout,
    p_allocator: ?*const AllocationCallbacks,
) callconv(call_conv) void;

pub const PfnCreatePipelineLayout = *const fn (
    device: Device,
    p_create_info: *const PipelineLayoutCreateInfo,
    p_allocator: ?*const AllocationCallbacks,
    p_pipeline_layout: *PipelineLayout,
) callconv(call_conv) Result;

pub const PfnDestroyPipelineLayout = *const fn (
    device: Device,
    pipeline_layout: PipelineLayout,
    p_allocator: ?*const AllocationCallbacks,
) callconv(call_conv) void;

pub const PfnCreateDescriptorPool = *const fn (
    device: Device,
    p_create_info: *const DescriptorPoolCreateInfo,
    p_allocator: ?*const AllocationCallbacks,
    p_descriptor_pool: *DescriptorPool,
) callconv(call_conv) Result;

pub const PfnDestroyDescriptorPool = *const fn (
    device: Device,
    descriptor_pool: DescriptorPool,
    p_allocator: ?*const AllocationCallbacks,
) callconv(call_conv) void;

pub const PfnAllocateDescriptorSets = *const fn (
    device: Device,
    p_allocate_info: *const DescriptorSetAllocateInfo,
    p_descriptor_sets: [*]DescriptorSet,
) callconv(call_conv) Result;

pub const PfnFreeDescriptorSets = *const fn (
    device: Device,
    descriptor_pool: DescriptorPool,
    descriptor_set_count: u32,
    p_descriptor_sets: [*]const DescriptorSet,
) callconv(call_conv) Result;

pub const PfnUpdateDescriptorSets = *const fn (
    device: Device,
    descriptor_write_count: u32,
    p_descriptor_writes: [*]const WriteDescriptorSet,
    descriptor_copy_count: u32,
    p_descriptor_copies: [*]const CopyDescriptorSet,
) callconv(call_conv) void;

pub const PfnCreateGraphicsPipelines = *const fn (
    device: Device,
    pipeline_cache: PipelineCache,
    create_info_count: u32,
    p_create_infos: [*]const GraphicsPipelineCreateInfo,
    p_allocator: ?*const AllocationCallbacks,
    p_pipelines: [*]Pipeline,
) callconv(call_conv) Result;

pub const PfnCreateComputePipelines = *const fn (
    device: Device,
    pipeline_cache: PipelineCache,
    create_info_count: u32,
    p_create_infos: [*]const ComputePipelineCreateInfo,
    p_allocator: ?*const AllocationCallbacks,
    p_pipelines: [*]Pipeline,
) callconv(call_conv) Result;

pub const PfnDestroyPipeline = *const fn (
    device: Device,
    pipeline: Pipeline,
    p_allocator: ?*const AllocationCallbacks,
) callconv(call_conv) void;

pub const PfnCmdBindPipeline = *const fn (
    command_buffer: CommandBuffer,
    pipeline_bind_point: PipelineBindPoint,
    pipeline: Pipeline,
) callconv(call_conv) void;

pub const PfnCmdBindDescriptorSets = *const fn (
    command_buffer: CommandBuffer,
    pipeline_bind_point: PipelineBindPoint,
    layout: PipelineLayout,
    first_set: u32,
    descriptor_set_count: u32,
    p_descriptor_sets: [*]const DescriptorSet,
    dynamic_offset_count: u32,
    p_dynamic_offsets: [*]const u32,
) callconv(call_conv) void;

pub const PfnCmdBindVertexBuffers = *const fn (
    command_buffer: CommandBuffer,
    first_binding: u32,
    binding_count: u32,
    p_buffers: [*]const Buffer,
    p_offsets: [*]const DeviceSize,
) callconv(call_conv) void;

pub const PfnCmdBindIndexBuffer = *const fn (
    command_buffer: CommandBuffer,
    buffer: Buffer,
    offset: DeviceSize,
    index_type: IndexType,
) callconv(call_conv) void;

pub const PfnCmdDraw = *const fn (
    command_buffer: CommandBuffer,
    vertex_count: u32,
    instance_count: u32,
    first_vertex: u32,
    first_instance: u32,
) callconv(call_conv) void;

pub const PfnCmdDrawIndexed = *const fn (
    command_buffer: CommandBuffer,
    index_count: u32,
    instance_count: u32,
    first_index: u32,
    vertex_offset: i32,
    first_instance: u32,
) callconv(call_conv) void;

pub const PfnCmdSetViewport = *const fn (
    command_buffer: CommandBuffer,
    first_viewport: u32,
    viewport_count: u32,
    p_viewports: [*]const Viewport,
) callconv(call_conv) void;

pub const PfnCmdSetScissor = *const fn (
    command_buffer: CommandBuffer,
    first_scissor: u32,
    scissor_count: u32,
    p_scissors: [*]const Rect2D,
) callconv(call_conv) void;

pub const PfnCmdDispatch = *const fn (
    command_buffer: CommandBuffer,
    group_count_x: u32,
    group_count_y: u32,
    group_count_z: u32,
) callconv(call_conv) void;

pub const PfnCreateSwapchainKHR = *const fn (
    device: Device,
    p_create_info: *const SwapchainCreateInfoKHR,
    p_allocator: ?*const AllocationCallbacks,
    p_swapchain: *SwapchainKHR,
) callconv(call_conv) Result;

pub const PfnDestroySwapchainKHR = *const fn (
    device: Device,
    swapchain: SwapchainKHR,
    p_allocator: ?*const AllocationCallbacks,
) callconv(call_conv) void;

pub const PfnGetSwapchainImagesKHR = *const fn (
    device: Device,
    swapchain: SwapchainKHR,
    p_swapchain_image_count: *u32,
    p_swapchain_images: ?[*]Image,
) callconv(call_conv) Result;

pub const PfnAcquireNextImageKHR = *const fn (
    device: Device,
    swapchain: SwapchainKHR,
    timeout: u64,
    semaphore: Semaphore,
    fence: Fence,
    p_image_index: *u32,
) callconv(call_conv) Result;

pub const PfnQueuePresentKHR = *const fn (
    queue: Queue,
    p_present_info: *const PresentInfoKHR,
) callconv(call_conv) Result;

/// The commands that exist before an instance.
pub const GlobalDispatch = struct {
    createInstance: PfnCreateInstance,
    enumerateInstanceLayerProperties: PfnEnumerateInstanceLayerProperties,
    enumerateInstanceExtensionProperties: PfnEnumerateInstanceExtensionProperties,
    enumerateInstanceVersion: PfnEnumerateInstanceVersion,
};

/// One instance's commands.
pub const InstanceDispatch = struct {
    destroyInstance: PfnDestroyInstance,
    enumeratePhysicalDevices: PfnEnumeratePhysicalDevices,
    getPhysicalDeviceProperties: PfnGetPhysicalDeviceProperties,
    getPhysicalDeviceQueueFamilyProperties: PfnGetPhysicalDeviceQueueFamilyProperties,
    getPhysicalDeviceFeatures2: PfnGetPhysicalDeviceFeatures2,
    enumerateDeviceExtensionProperties: PfnEnumerateDeviceExtensionProperties,
    createDevice: PfnCreateDevice,
    getDeviceProcAddr: PfnGetDeviceProcAddr,
    getPhysicalDeviceMemoryProperties: PfnGetPhysicalDeviceMemoryProperties,
    createDebugUtilsMessengerEXT: ?PfnCreateDebugUtilsMessengerEXT,
    destroyDebugUtilsMessengerEXT: ?PfnDestroyDebugUtilsMessengerEXT,
};

/// An instance's window-system commands (VK_KHR_surface, VK_KHR_win32_surface): loaded only by a
/// host with a window.
pub const SurfaceDispatch = struct {
    createWin32SurfaceKHR: PfnCreateWin32SurfaceKHR,
    destroySurfaceKHR: PfnDestroySurfaceKHR,
    getPhysicalDeviceSurfaceSupportKHR: PfnGetPhysicalDeviceSurfaceSupportKHR,
    getPhysicalDeviceSurfaceCapabilitiesKHR: PfnGetPhysicalDeviceSurfaceCapabilitiesKHR,
    getPhysicalDeviceSurfaceFormatsKHR: PfnGetPhysicalDeviceSurfaceFormatsKHR,
    getPhysicalDeviceSurfacePresentModesKHR: PfnGetPhysicalDeviceSurfacePresentModesKHR,
};

/// One device's commands.
pub const DeviceDispatch = struct {
    destroyDevice: PfnDestroyDevice,
    getDeviceQueue: PfnGetDeviceQueue,
    deviceWaitIdle: PfnDeviceWaitIdle,
    createImageView: PfnCreateImageView,
    destroyImageView: PfnDestroyImageView,
    createSemaphore: PfnCreateSemaphore,
    destroySemaphore: PfnDestroySemaphore,
    waitSemaphores: PfnWaitSemaphores,
    getSemaphoreCounterValue: PfnGetSemaphoreCounterValue,
    createCommandPool: PfnCreateCommandPool,
    destroyCommandPool: PfnDestroyCommandPool,
    allocateCommandBuffers: PfnAllocateCommandBuffers,
    resetCommandBuffer: PfnResetCommandBuffer,
    beginCommandBuffer: PfnBeginCommandBuffer,
    endCommandBuffer: PfnEndCommandBuffer,
    cmdPipelineBarrier2: PfnCmdPipelineBarrier2,
    cmdBeginRendering: PfnCmdBeginRendering,
    cmdEndRendering: PfnCmdEndRendering,
    queueSubmit2: PfnQueueSubmit2,
    setDebugUtilsObjectNameEXT: ?PfnSetDebugUtilsObjectNameEXT,
    createBuffer: PfnCreateBuffer,
    destroyBuffer: PfnDestroyBuffer,
    getBufferMemoryRequirements: PfnGetBufferMemoryRequirements,
    allocateMemory: PfnAllocateMemory,
    freeMemory: PfnFreeMemory,
    bindBufferMemory: PfnBindBufferMemory,
    mapMemory: PfnMapMemory,
    cmdCopyBuffer: PfnCmdCopyBuffer,
    cmdFillBuffer: PfnCmdFillBuffer,
    createImage: PfnCreateImage,
    destroyImage: PfnDestroyImage,
    getImageMemoryRequirements: PfnGetImageMemoryRequirements,
    bindImageMemory: PfnBindImageMemory,
    cmdCopyBufferToImage: PfnCmdCopyBufferToImage,
    cmdCopyImageToBuffer: PfnCmdCopyImageToBuffer,
    cmdClearColorImage: PfnCmdClearColorImage,
    cmdClearDepthStencilImage: PfnCmdClearDepthStencilImage,
    createSampler: PfnCreateSampler,
    destroySampler: PfnDestroySampler,
    createShaderModule: PfnCreateShaderModule,
    destroyShaderModule: PfnDestroyShaderModule,
    createDescriptorSetLayout: PfnCreateDescriptorSetLayout,
    destroyDescriptorSetLayout: PfnDestroyDescriptorSetLayout,
    createPipelineLayout: PfnCreatePipelineLayout,
    destroyPipelineLayout: PfnDestroyPipelineLayout,
    createDescriptorPool: PfnCreateDescriptorPool,
    destroyDescriptorPool: PfnDestroyDescriptorPool,
    allocateDescriptorSets: PfnAllocateDescriptorSets,
    freeDescriptorSets: PfnFreeDescriptorSets,
    updateDescriptorSets: PfnUpdateDescriptorSets,
    createGraphicsPipelines: PfnCreateGraphicsPipelines,
    createComputePipelines: PfnCreateComputePipelines,
    destroyPipeline: PfnDestroyPipeline,
    cmdBindPipeline: PfnCmdBindPipeline,
    cmdBindDescriptorSets: PfnCmdBindDescriptorSets,
    cmdBindVertexBuffers: PfnCmdBindVertexBuffers,
    cmdBindIndexBuffer: PfnCmdBindIndexBuffer,
    cmdDraw: PfnCmdDraw,
    cmdDrawIndexed: PfnCmdDrawIndexed,
    cmdSetViewport: PfnCmdSetViewport,
    cmdSetScissor: PfnCmdSetScissor,
    cmdDispatch: PfnCmdDispatch,
};

/// A device's swapchain commands (VK_KHR_swapchain): loaded only by a host with a window.
pub const SwapchainDispatch = struct {
    createSwapchainKHR: PfnCreateSwapchainKHR,
    destroySwapchainKHR: PfnDestroySwapchainKHR,
    getSwapchainImagesKHR: PfnGetSwapchainImagesKHR,
    acquireNextImageKHR: PfnAcquireNextImageKHR,
    queuePresentKHR: PfnQueuePresentKHR,
};

// ---- Loading: the dispatch tables, filled by name ----

/// How Vulkan's commands are found: `vkGetInstanceProcAddr` and `vkGetDeviceProcAddr` take the object whose commands
/// are wanted - an instance (the null instance, for the global commands) or a device - and a command's name, and
/// return that command, or null when the object does not provide it. `Handle` is `Instance` or `Device`.
pub fn CommandLookup(comptime Handle: type) type {
    return *const fn (handle: Handle, name: [*:0]const u8) callconv(call_conv) ?PfnVoidFunction;
}

/// The one command a program needs from the loader by name (`native_os.zig` opens the loader and finds it): the
/// lookup over instances, through which every other command is found. The loader exports the core commands too; but
/// a device command looked up through its device (`vkGetDeviceProcAddr`) skips the loader's dispatch on every call.
pub const PfnGetInstanceProcAddr = CommandLookup(Instance);

pub const LoadError = error{
    /// A required command is not provided by the driver (or its extension was not enabled).
    MissingCommand,
};

/// A fetched command as its table field's type: an optional field takes null, a required one makes null an error.
fn commandOrNull(comptime Field: type, command: ?PfnVoidFunction) LoadError!Field {
    if (@typeInfo(Field) == .optional) {
        const found: PfnVoidFunction = command orelse return null;
        return @ptrCast(found);
    }
    const found: PfnVoidFunction = command orelse return LoadError.MissingCommand;
    return @ptrCast(found);
}

/// A table field's command under its C name: `cmdBeginRendering` is `vkCmdBeginRendering`.
fn commandName(comptime field_name: []const u8) [:0]const u8 {
    return comptime comptimePrint("vk{c}{s}", .{ toUpper(field_name[0]), field_name[1..] });
}

/// Any dispatch table: a struct whose fields are Vulkan commands under their Zig names (`createImage`), typed with
/// their function-pointer types (`PfnCreateImage`) - optional where the program can do without the command. Each is
/// looked up by its C name, from `handle`.
pub fn loadDispatch(
    comptime Table: type,
    comptime Handle: type,
    lookup: CommandLookup(Handle),
    handle: Handle,
) LoadError!Table {
    var table: Table = undefined;
    const fields: std.lang.Type.Struct = @typeInfo(Table).@"struct";
    inline for (fields.field_names, fields.field_types) |field_name, FieldType| {
        const command: ?PfnVoidFunction = lookup(handle, commandName(field_name).ptr);
        @field(table, field_name) = try commandOrNull(FieldType, command);
    }
    return table;
}

/// The commands that exist before an instance: fetched with the null instance.
pub fn loadGlobalDispatch(get_instance_proc_address: PfnGetInstanceProcAddr) LoadError!GlobalDispatch {
    return loadDispatch(GlobalDispatch, Instance, get_instance_proc_address, .null_handle);
}

/// The commands of one instance.
pub fn loadInstanceDispatch(
    get_instance_proc_address: PfnGetInstanceProcAddr,
    instance: Instance,
) LoadError!InstanceDispatch {
    return loadDispatch(InstanceDispatch, Instance, get_instance_proc_address, instance);
}

/// The window-system commands of one instance; loaded only by a host with a window.
pub fn loadSurfaceDispatch(
    get_instance_proc_address: PfnGetInstanceProcAddr,
    instance: Instance,
) LoadError!SurfaceDispatch {
    return loadDispatch(SurfaceDispatch, Instance, get_instance_proc_address, instance);
}

/// The commands of one device, fetched through `vkGetDeviceProcAddr` - the device's own entry points, without the
/// loader's per-call dispatch.
pub fn loadDeviceDispatch(get_device_proc_address: PfnGetDeviceProcAddr, device: Device) LoadError!DeviceDispatch {
    return loadDispatch(DeviceDispatch, Device, get_device_proc_address, device);
}

/// The swapchain commands of one device; loaded only by a host with a window.
pub fn loadSwapchainDispatch(
    get_device_proc_address: PfnGetDeviceProcAddr,
    device: Device,
) LoadError!SwapchainDispatch {
    return loadDispatch(SwapchainDispatch, Device, get_device_proc_address, device);
}

/// A failing `VkResult` as a Zig error: the caller names what it was doing.
pub const ResultError = error{
    VulkanNotReady,
    VulkanTimeout,
    VulkanIncomplete,
    VulkanOutOfHostMemory,
    VulkanOutOfDeviceMemory,
    VulkanInitializationFailed,
    VulkanDeviceLost,
    VulkanLayerNotPresent,
    VulkanExtensionNotPresent,
    VulkanFeatureNotPresent,
    VulkanIncompatibleDriver,
    VulkanSurfaceLost,
    VulkanNativeWindowInUse,
    VulkanOutOfDate,
    VulkanValidationFailed,
    VulkanUnknown,
};

/// `success` and `suboptimal_khr` pass (suboptimal is still a valid present); every other result is an error.
pub fn check(result: Result) ResultError!void {
    return switch (result) {
        .success, .suboptimal_khr => {},
        .not_ready => ResultError.VulkanNotReady,
        .timeout => ResultError.VulkanTimeout,
        .incomplete => ResultError.VulkanIncomplete,
        .error_out_of_host_memory => ResultError.VulkanOutOfHostMemory,
        .error_out_of_device_memory => ResultError.VulkanOutOfDeviceMemory,
        .error_initialization_failed => ResultError.VulkanInitializationFailed,
        .error_device_lost => ResultError.VulkanDeviceLost,
        .error_layer_not_present => ResultError.VulkanLayerNotPresent,
        .error_extension_not_present => ResultError.VulkanExtensionNotPresent,
        .error_feature_not_present => ResultError.VulkanFeatureNotPresent,
        .error_incompatible_driver => ResultError.VulkanIncompatibleDriver,
        .error_surface_lost_khr => ResultError.VulkanSurfaceLost,
        .error_native_window_in_use_khr => ResultError.VulkanNativeWindowInUse,
        .error_out_of_date_khr => ResultError.VulkanOutOfDate,
        .error_validation_failed_ext => ResultError.VulkanValidationFailed,
        else => ResultError.VulkanUnknown,
    };
}

/// A device or instance name stored as a fixed, zero-padded byte array, as text.
pub fn fixedName(bytes: []const u8) []const u8 {
    const length: usize = indexOfScalar(u8, bytes, 0) orelse bytes.len;
    return bytes[0..length];
}
