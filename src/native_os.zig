//! THE NATIVE HOST'S OPERATING-SYSTEM SERVICES - what the Vulkan host asks of the operating system besides a window:
//!
//!     the Vulkan loader   the library every Vulkan program opens first, and its one exported entry point,
//!                         `vkGetInstanceProcAddr`, through which every other command is fetched
//!     environment         the variables that steer the host (`ZIMR_GPU`, `ZIMR_VK_VALIDATE`)
//!     a monotonic clock   milliseconds that never run backwards, as the browser's `performance.now()` gives them
//!
//! Each service has a Windows version, through `win32.zig`, and a Linux version, through the C library - which a
//! Linux program using Vulkan links anyway, since the Vulkan loader itself is a C library that `dlopen` loads. The
//! choice is made at compile time: the other platform's branch is never analyzed, so a Linux build references no
//! Win32 function and a Windows build no C-library one.
//!
//! The window is not here. It is Windows-only for now (`win32.zig`); a host without one runs headless, drawing into
//! textures - which is how the host's tests run on Linux, on Mesa's software Vulkan driver.

const builtin = @import("builtin");
const std = @import("std");
const vk = @import("vk.zig");
const win32 = @import("win32.zig");

const span = std.mem.span;

const is_windows: bool = builtin.os.tag == .windows;

// ---- The Vulkan loader ----

pub const VulkanLibrary = struct {
    /// The opened library: Win32's module handle, or the handle `dlopen` returned.
    handle: *anyopaque,
    /// `vkGetInstanceProcAddr`, the one command the host takes from the loader by name; every other is looked up
    /// through it. The operating system hands it out untyped; it gets its Vulkan type here, once.
    get_instance_proc_address: vk.PfnGetInstanceProcAddr,
};

pub const VulkanLibraryError = error{
    /// The loader library is not installed: no Vulkan driver on this machine.
    VulkanNotInstalled,
    /// The library loaded but does not export `vkGetInstanceProcAddr`.
    VulkanLoaderIncomplete,
};

/// The Vulkan loader. On Windows `vulkan-1.dll`; on Linux `libvulkan.so.1`, the loader's ABI-versioned name, present
/// wherever a Vulkan driver is installed (the unversioned `libvulkan.so` comes only with development packages).
pub fn openVulkanLibrary() VulkanLibraryError!VulkanLibrary {
    if (comptime is_windows) {
        const library: win32.VulkanLibrary = try win32.openVulkanLibrary();
        return .{ .handle = library.module, .get_instance_proc_address = @ptrCast(library.get_instance_proc_address) };
    }
    // LAZY: a symbol is resolved when first used, not all at load - the loader exports far more than one program calls.
    const handle: *anyopaque = std.c.dlopen("libvulkan.so.1", .{ .LAZY = true }) orelse
        return error.VulkanNotInstalled;
    const entry: *anyopaque = std.c.dlsym(handle, "vkGetInstanceProcAddr") orelse {
        _ = std.c.dlclose(handle);
        return error.VulkanLoaderIncomplete;
    };
    return .{ .handle = handle, .get_instance_proc_address = @ptrCast(entry) };
}

pub fn closeVulkanLibrary(library: VulkanLibrary) void {
    if (comptime is_windows) {
        win32.closeVulkanLibrary(.{
            .module = @ptrCast(library.handle),
            .get_instance_proc_address = @ptrCast(library.get_instance_proc_address),
        });
        return;
    }
    _ = std.c.dlclose(library.handle);
}

// ---- Environment ----

/// The environment variable `name`'s value as UTF-8, copied into `buffer`: null when it is not set or does not fit.
pub fn environmentVariable(comptime name: []const u8, buffer: []u8) ?[]const u8 {
    if (comptime is_windows) {
        return win32.environmentVariable(name, buffer);
    }
    const value: [*:0]const u8 = std.c.getenv(name ++ "\x00") orelse return null;
    const text: []const u8 = span(value);
    if (text.len > buffer.len) {
        return null;
    }
    @memcpy(buffer[0..text.len], text);
    return buffer[0..text.len];
}

// ---- The clock ----

/// A monotonic clock in milliseconds: Windows' performance counter, or Linux's `CLOCK_MONOTONIC` - both unaffected by
/// changes to the wall-clock time, and both starting at an arbitrary point, so only differences mean anything.
pub fn monotonicMilliseconds() f64 {
    if (comptime is_windows) {
        return win32.monotonicMilliseconds();
    }
    var now: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &now);
    const seconds: f64 = @floatFromInt(now.sec);
    const nanoseconds: f64 = @floatFromInt(now.nsec);
    return seconds * 1000.0 + nanoseconds / 1_000_000.0;
}

// ---- Tests ----

const testing = std.testing;
const expect = testing.expect;

test "native_os: an unset variable is null; the clock never runs backwards" {
    var buffer: [64]u8 = undefined;
    try expect(environmentVariable("ZIMR_NATIVE_OS_TEST_SURELY_UNSET", &buffer) == null);
    const first: f64 = monotonicMilliseconds();
    const second: f64 = monotonicMilliseconds();
    try expect(second >= first);
}

test "native_os: the Vulkan loader opens with its entry point, or is reported missing" {
    const library: VulkanLibrary = openVulkanLibrary() catch |err| {
        // A machine without a Vulkan driver: the one failure that is not a bug.
        try testing.expectEqual(VulkanLibraryError.VulkanNotInstalled, err);
        return;
    };
    defer closeVulkanLibrary(library);
    try expect(@intFromPtr(library.get_instance_proc_address) != 0);
}
