//! THE NATIVE WINDOW SYSTEM - the window layer a native build draws through, chosen once, by its operating system:
//! Win32 (`win32.zig`) on Windows, X11 (`x11.zig`) on Linux. The native loop and the Vulkan host both name the window
//! through here, so the choice is made in one place - the host cannot import the loop, which imports it.
//!
//! Both windows offer the members the loop and the host read and call, with Win32's names and meanings
//! (`shared_fields`, `shared_methods`): the client area's size in physical pixels, the flags the loop reacts to, the
//! scale, the requests the contract passes through. The check below fails the build of BOTH systems, naming the
//! member, when one window has a member the other lacks - so the shared loop, written against one, cannot quietly stop
//! compiling for the other. A request only one system has - Win32's file dialogs and drops, X11's clipboard - is called
//! by code that knows which system it runs on.
//!
//! macOS and Android compile against Win32's declarations and never call them: no window opens there
//! (`native_loop.has_window_loop` is false), as before.

const builtin = @import("builtin");
const vk = @import("vk.zig");
const win32 = @import("win32.zig");
const x11 = @import("x11.zig");

/// Whether this build's window is X11's: Linux, but not Android - Linux's kernel under a system of its own.
pub const is_x11: bool = builtin.target.os.tag == .linux and !builtin.target.abi.isAndroid();

/// The window layer this build draws through, and its types.
pub const system = if (is_x11) x11 else win32;
pub const Window = system.Window;
pub const WindowOptions = system.WindowOptions;
pub const WindowError = system.WindowError;
pub const InputMessage = system.InputMessage;

/// The Vulkan instance extension that makes a surface of this system's window.
pub const surface_extension_name: [*:0]const u8 =
    if (is_x11) vk.khr_xlib_surface_extension_name else vk.khr_win32_surface_extension_name;

/// The fields both windows have: the client area's size in physical pixels; whether the window was asked to close, is
/// minimized, changed size, is fullscreen; whether the monitors changed; where input goes; the client area's limits.
const shared_fields = [_][]const u8{
    "client_width",
    "client_height",
    "close_requested",
    "minimized",
    "size_changed",
    "is_fullscreen",
    "monitors_changed",
    "input_handler",
    "min_client_width",
    "min_client_height",
    "max_client_width",
    "max_client_height",
};

/// The functions both windows have: opening, handling the waiting events, closing; the scale; and the requests the
/// shared loop passes on to the window whatever its system.
const shared_methods = [_][]const u8{
    "open",
    "pump",
    "close",
    "scale",
    "setTitle",
    "setFullscreen",
    "requestPaste",
    "lockPointer",
    "releasePointerLock",
    "setInputMethodEnabled",
    "bringToFront",
    "applySizeLimits",
};

comptime {
    for ([_]type{ win32.Window, x11.Window }) |SystemWindow| {
        for (shared_fields) |field_name| {
            if (!@hasField(SystemWindow, field_name)) {
                @compileError(@typeName(SystemWindow) ++ " has no field `" ++ field_name ++
                    "`, which both windows offer (native_window.zig)");
            }
        }
        for (shared_methods) |method_name| {
            if (!@hasDecl(SystemWindow, method_name)) {
                @compileError(@typeName(SystemWindow) ++ " has no `" ++ method_name ++
                    "`, which both windows offer (native_window.zig)");
            }
        }
    }
}
