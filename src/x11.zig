//! THE X11 WINDOW LAYER - one window on an X server and its events, through Xlib: loaded at run time, declared by hand.
//! lint:off screaming-const: X11's own names (XA_ATOM, _NET_WM_STATE_ADD), exactly as its headers declare them;
//! linux-abi-check finds each one's twin in the headers by that same name.
//!
//! ---- X11 IN BRIEF ----
//!
//! An X server owns the screen, the keyboard and the mouse; programs - its clients - talk to it over a socket, asking
//! it to make windows, and it sends them events: a key pressed, a window resized. The window manager is a client with
//! privileges: it frames the other clients' windows and decides where they go. Two conventions say how a program and
//! it get along - the ICCCM (the title, the close button's protocol, size hints) and EWMH (fullscreen, a window's
//! state, its process). On a Wayland desktop XWayland is an X server turning X11 windows into Wayland ones - WSLg's
//! included - so this one window layer runs on both.
//!
//! ---- WHY XLIB, AND LOADED AT RUN TIME ----
//!
//! Xlib (libX11) rather than XCB: only Xlib has the input method (XIM) through which dead keys, compose and the input
//! methods of Chinese, Japanese and Korean type, and Vulkan's `VK_KHR_xlib_surface` takes its connection. The library
//! is opened at run time (`loadLibrary`) - `libX11.so.6`, the name every distribution's package gives it - and each
//! function looked up by name, as the Vulkan loader is: a zimr program links glibc alone, starts on a machine without
//! X11, and says what is missing. It is never closed: the Vulkan driver may call into it until the program exits.
//!
//! ---- DECLARED BY HAND, CHECKED THREE WAYS ----
//!
//! No X11 header is on the machine that builds zimr, so the structures, constants and prototypes below are declared by
//! hand from the headers' text, under C's names - fields too (`keycode`, `x_root`, `send_event`). One exception: X's
//! `Window` typedef is not declared, `Window` being this layer's own struct; a window's id is an `XID`, which C's
//! `Window` is. The checks: each structure's size on 64-bit Linux, and the offsets zimr reads, asserted at compile time
//! in a Linux build (`is_lp64_linux`) - they catch a declaration that drifts from the headers' text; Vulkan's own
//! structure, by `vk-abi-check`; and every declaration against the headers themselves, by `zig build linux-abi-check`
//! on a machine that has them (linux_port_plan.md, stage L9).
//!
//! ---- PHYSICAL PIXELS ----
//!
//! X11 speaks physical pixels: positions and sizes, the window's own included. The window keeps its size in them, as
//! Win32's does; the scale (`scale`) - the desktop's `Xft.dpi` over 96, or `ZIMR_SCALE` - turns them into the
//! engine's logical pixels, in `native_input.translateX11`.
//!
//! ---- THE WINDOW ----
//!
//! `Window` has the members the native loop and the Vulkan host read and call, with Win32's names and meanings
//! (`native_window.zig` checks that both windows offer them). `pump` drains the server's events, each turned into a
//! plain `InputMessage` for the input handler; `native_input.translateX11` turns those into the engine's events - a
//! pure function, tested on any machine. Written in stages (linux_port_plan.md): this file is stage L3's - the window,
//! keys by position (evdev codes), text through `XLookupString`, the mouse, focus, the window manager's requests,
//! fullscreen. The input method, cursors and pointer lock are stage L4's; the clipboard and monitors L5's.

const std = @import("std");
const builtin = @import("builtin");
const zm = @import("zm");
const console = @import("platform/console.zig");
const native_os = @import("native_os.zig");

const clamp = zm.clamp;
const float = zm.float;
const bufPrint = std.fmt.bufPrint;
const comptimePrint = std.fmt.comptimePrint;
const parseFloat = std.fmt.parseFloat;
const startsWith = std.mem.startsWith;
const trim = std.mem.trim;
const splitScalar = std.mem.splitScalar;
const SplitIterator = std.mem.SplitIterator;
const span = std.mem.span;
const StaticBitSet = std.bit_set.StaticBitSet;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

// ---- Types ----

pub const XID = c_ulong;
pub const Atom = c_ulong;
pub const Time = c_ulong;
pub const Colormap = c_ulong;
pub const KeySym = c_ulong;
pub const Bool = c_int;
pub const Status = c_int;
pub const KeyCode = u8;
/// A connection to an X server.
pub const Display = opaque {};
pub const Visual = opaque {};

// ---- Structures, field for field as Xlib.h and Xutil.h declare them ----

pub const XAnyEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: XID,
};

pub const XKeyEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: XID,
    root: XID,
    subwindow: XID,
    time: Time,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    keycode: c_uint,
    same_screen: Bool,
};

pub const XButtonEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: XID,
    root: XID,
    subwindow: XID,
    time: Time,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    button: c_uint,
    same_screen: Bool,
};

pub const XMotionEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: XID,
    root: XID,
    subwindow: XID,
    time: Time,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    is_hint: u8,
    same_screen: Bool,
};

pub const XCrossingEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: XID,
    root: XID,
    subwindow: XID,
    time: Time,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    mode: c_int,
    detail: c_int,
    same_screen: Bool,
    focus: Bool,
    state: c_uint,
};

pub const XFocusChangeEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: XID,
    mode: c_int,
    detail: c_int,
};

pub const XConfigureEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    event: XID,
    window: XID,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    border_width: c_int,
    above: XID,
    override_redirect: Bool,
};

pub const XMapEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    event: XID,
    window: XID,
    override_redirect: Bool,
};

pub const XUnmapEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    event: XID,
    window: XID,
    from_configure: Bool,
};

/// A client message's twenty bytes, as bytes, shorts or longs - its `format` says which (8, 16, 32).
pub const ClientMessageData = extern union {
    b: [20]u8,
    s: [10]c_short,
    l: [5]c_long,
};

pub const XClientMessageEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: XID,
    message_type: Atom,
    format: c_int,
    data: ClientMessageData,
};

pub const XPropertyEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: XID,
    atom: Atom,
    time: Time,
    state: c_int,
};

pub const XErrorEvent = extern struct {
    type: c_int,
    display: ?*Display,
    resourceid: XID,
    serial: c_ulong,
    error_code: u8,
    request_code: u8,
    minor_code: u8,
};

/// What Xlib calls when a request fails: Xlib's own handler ends the program, so the window installs one that logs.
pub const ErrorHandler = *const fn (display: ?*Display, event: *XErrorEvent) callconv(.c) c_int;

/// Any event: its first field, `type`, says which member holds it. Xlib's room for every event is 24 longs.
pub const XEvent = extern union {
    type: c_int,
    xany: XAnyEvent,
    xkey: XKeyEvent,
    xbutton: XButtonEvent,
    xmotion: XMotionEvent,
    xcrossing: XCrossingEvent,
    xfocus: XFocusChangeEvent,
    xconfigure: XConfigureEvent,
    xmap: XMapEvent,
    xunmap: XUnmapEvent,
    xclient: XClientMessageEvent,
    xproperty: XPropertyEvent,
    xerror: XErrorEvent,
    pad: [24]c_long,
};

/// A new window's attributes; `CW...` bits say which the server reads.
pub const XSetWindowAttributes = extern struct {
    background_pixmap: XID = 0,
    background_pixel: c_ulong = 0,
    border_pixmap: XID = 0,
    border_pixel: c_ulong = 0,
    bit_gravity: c_int = 0,
    win_gravity: c_int = 0,
    backing_store: c_int = 0,
    backing_planes: c_ulong = 0,
    backing_pixel: c_ulong = 0,
    save_under: Bool = 0,
    event_mask: c_long = 0,
    do_not_propagate_mask: c_long = 0,
    override_redirect: Bool = 0,
    colormap: Colormap = 0,
    cursor: XID = 0,
};

/// A ratio in the size hints: numerator, denominator.
pub const AspectRatio = extern struct {
    x: c_int,
    y: c_int,
};

/// The window's size hints for the window manager (ICCCM's `WM_NORMAL_HINTS`); `flags` says which fields count.
pub const XSizeHints = extern struct {
    flags: c_long,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    min_width: c_int,
    min_height: c_int,
    max_width: c_int,
    max_height: c_int,
    width_inc: c_int,
    height_inc: c_int,
    min_aspect: AspectRatio,
    max_aspect: AspectRatio,
    base_width: c_int,
    base_height: c_int,
    win_gravity: c_int,
};

/// The window's class (ICCCM's `WM_CLASS`): the program's name, and the class of programs it belongs to.
pub const XClassHint = extern struct {
    res_name: ?[*:0]const u8,
    res_class: ?[*:0]const u8,
};

/// Whether this build lays C's types out as the structures above were measured: 64-bit Linux, where `long` and
/// pointers are 8 bytes (LP64). Elsewhere - a Windows build importing these types for `native_input`'s tests - the
/// sizes differ, and nothing calls Xlib.
const is_lp64_linux: bool = builtin.target.os.tag == .linux and @sizeOf(c_long) == 8;

/// Fails the build when `T` is not `size` bytes.
fn assertSize(comptime T: type, comptime size: usize) void {
    if (@sizeOf(T) != size) {
        @compileError(comptimePrint("x11.{s} is {d} bytes; the headers' is {d}", .{ @typeName(T), @sizeOf(T), size }));
    }
}

/// Fails the build when `T`'s field `field_name` is not at byte `offset`.
fn assertOffset(
    comptime T: type,
    comptime field_name: []const u8,
    comptime offset: usize,
) void {
    if (@offsetOf(T, field_name) != offset) {
        @compileError(comptimePrint("x11.{s}.{s} is at byte {d}; the headers' is at {d}", .{
            @typeName(T),
            field_name,
            @offsetOf(T, field_name),
            offset,
        }));
    }
}

// The layouts, worked out from the headers' text for LP64: each `long`, pointer and id 8 bytes, aligned to 8.
comptime {
    if (is_lp64_linux) {
        assertSize(XAnyEvent, 40);
        assertOffset(XAnyEvent, "window", 32);
        assertSize(XKeyEvent, 96);
        assertOffset(XKeyEvent, "time", 56);
        assertOffset(XKeyEvent, "x", 64);
        assertOffset(XKeyEvent, "state", 80);
        assertOffset(XKeyEvent, "keycode", 84);
        assertSize(XButtonEvent, 96);
        assertOffset(XButtonEvent, "button", 84);
        assertSize(XMotionEvent, 96);
        assertOffset(XMotionEvent, "state", 80);
        assertOffset(XMotionEvent, "is_hint", 84);
        assertSize(XCrossingEvent, 104);
        assertOffset(XCrossingEvent, "mode", 80);
        assertOffset(XCrossingEvent, "detail", 84);
        assertOffset(XCrossingEvent, "state", 96);
        assertSize(XFocusChangeEvent, 48);
        assertOffset(XFocusChangeEvent, "mode", 40);
        assertSize(XConfigureEvent, 88);
        assertOffset(XConfigureEvent, "width", 56);
        assertOffset(XConfigureEvent, "above", 72);
        assertSize(XMapEvent, 56);
        assertOffset(XMapEvent, "window", 40);
        assertSize(XUnmapEvent, 56);
        assertOffset(XUnmapEvent, "window", 40);
        assertSize(XClientMessageEvent, 96);
        assertOffset(XClientMessageEvent, "message_type", 40);
        assertOffset(XClientMessageEvent, "format", 48);
        assertOffset(XClientMessageEvent, "data", 56);
        assertSize(XPropertyEvent, 64);
        assertOffset(XPropertyEvent, "atom", 40);
        assertOffset(XPropertyEvent, "state", 56);
        assertSize(XErrorEvent, 40);
        assertOffset(XErrorEvent, "error_code", 32);
        assertSize(XEvent, 192);
        assertSize(XSetWindowAttributes, 112);
        assertOffset(XSetWindowAttributes, "event_mask", 72);
        assertOffset(XSetWindowAttributes, "colormap", 96);
        assertSize(XSizeHints, 80);
        assertOffset(XSizeHints, "min_width", 24);
        assertOffset(XSizeHints, "win_gravity", 72);
        assertSize(XClassHint, 16);
    }
}

// ---- Constants (X.h, Xutil.h, Xatom.h, keysymdef.h), each by its C name ----

pub const False: Bool = 0;
pub const True: Bool = 1;
pub const Success: c_int = 0;
pub const None: XID = 0;
pub const CurrentTime: Time = 0;

// Event types.
pub const KeyPress: c_int = 2;
pub const KeyRelease: c_int = 3;
pub const ButtonPress: c_int = 4;
pub const ButtonRelease: c_int = 5;
pub const MotionNotify: c_int = 6;
pub const EnterNotify: c_int = 7;
pub const LeaveNotify: c_int = 8;
pub const FocusIn: c_int = 9;
pub const FocusOut: c_int = 10;
pub const UnmapNotify: c_int = 18;
pub const MapNotify: c_int = 19;
pub const ConfigureNotify: c_int = 22;
pub const PropertyNotify: c_int = 28;
pub const ClientMessage: c_int = 33;

// Event masks: which events a window selects.
pub const KeyPressMask: c_long = 1 << 0;
pub const KeyReleaseMask: c_long = 1 << 1;
pub const ButtonPressMask: c_long = 1 << 2;
pub const ButtonReleaseMask: c_long = 1 << 3;
pub const EnterWindowMask: c_long = 1 << 4;
pub const LeaveWindowMask: c_long = 1 << 5;
pub const PointerMotionMask: c_long = 1 << 6;
pub const ExposureMask: c_long = 1 << 15;
pub const StructureNotifyMask: c_long = 1 << 17;
pub const SubstructureNotifyMask: c_long = 1 << 19;
pub const SubstructureRedirectMask: c_long = 1 << 20;
pub const FocusChangeMask: c_long = 1 << 21;
pub const PropertyChangeMask: c_long = 1 << 22;

// Window creation: its class, which attributes are given, and a colormap that allocates nothing.
pub const InputOutput: c_uint = 1;
pub const CWBorderPixel: c_ulong = 1 << 3;
pub const CWEventMask: c_ulong = 1 << 11;
pub const CWColormap: c_ulong = 1 << 13;
pub const AllocNone: c_int = 0;

// Focus: why focus moved, and where it goes when the window it was given goes away.
pub const NotifyNormal: c_int = 0;
pub const NotifyGrab: c_int = 1;
pub const NotifyUngrab: c_int = 2;
pub const RevertToParent: c_int = 2;

// Properties and the event queue.
pub const PropModeReplace: c_int = 0;
pub const QueuedAfterReading: c_int = 1;

// Predefined atoms (Xatom.h).
pub const XA_ATOM: Atom = 4;
pub const XA_CARDINAL: Atom = 6;
pub const XA_STRING: Atom = 31;

// Size hints (Xutil.h): which fields count, and the gravity that makes a given position the client area's.
pub const PMinSize: c_long = 1 << 4;
pub const PMaxSize: c_long = 1 << 5;
pub const PWinGravity: c_long = 1 << 9;
pub const StaticGravity: c_int = 10;

// Keysyms (keysymdef.h).
pub const XK_Escape: KeySym = 0xff1b;
pub const XK_Return: KeySym = 0xff0d;

// EWMH's state changes, in a `_NET_WM_STATE` client message, and who asks: 1, an application.
pub const _NET_WM_STATE_REMOVE: c_long = 0;
pub const _NET_WM_STATE_ADD: c_long = 1;
const source_application: c_long = 1;

/// A window size X11 takes, as an unlimited size limit: 16 bits, signed.
const largest_window_size: c_int = 32767;

// ---- The library ----

/// libX11's functions zimr calls, each under its C name - looked up by it when the window opens (`loadLibrary`).
pub const Xlib = struct {
    // The connection.
    XInitThreads: *const fn () callconv(.c) Status,
    XOpenDisplay: *const fn (display_name: ?[*:0]const u8) callconv(.c) ?*Display,
    XCloseDisplay: *const fn (display: *Display) callconv(.c) c_int,
    XSetErrorHandler: *const fn (handler: ?ErrorHandler) callconv(.c) ?ErrorHandler,
    XConnectionNumber: *const fn (display: *Display) callconv(.c) c_int,
    XDefaultScreen: *const fn (display: *Display) callconv(.c) c_int,
    XRootWindow: *const fn (display: *Display, screen: c_int) callconv(.c) XID,
    XDefaultVisual: *const fn (display: *Display, screen: c_int) callconv(.c) ?*Visual,
    XDefaultDepth: *const fn (display: *Display, screen: c_int) callconv(.c) c_int,
    XDisplayWidth: *const fn (display: *Display, screen: c_int) callconv(.c) c_int,
    XDisplayHeight: *const fn (display: *Display, screen: c_int) callconv(.c) c_int,
    XFlush: *const fn (display: *Display) callconv(.c) c_int,
    XPending: *const fn (display: *Display) callconv(.c) c_int,
    XEventsQueued: *const fn (display: *Display, mode: c_int) callconv(.c) c_int,
    XNextEvent: *const fn (display: *Display, event: *XEvent) callconv(.c) c_int,
    XPeekEvent: *const fn (display: *Display, event: *XEvent) callconv(.c) c_int,
    XFree: *const fn (data: ?*anyopaque) callconv(.c) c_int,
    // The window.
    XCreateColormap: *const fn (
        display: *Display,
        window: XID,
        visual: ?*Visual,
        alloc: c_int,
    ) callconv(.c) Colormap,
    XFreeColormap: *const fn (display: *Display, colormap: Colormap) callconv(.c) c_int,
    XCreateWindow: *const fn (
        display: *Display,
        parent: XID,
        x: c_int,
        y: c_int,
        width: c_uint,
        height: c_uint,
        border_width: c_uint,
        depth: c_int,
        class: c_uint,
        visual: ?*Visual,
        value_mask: c_ulong,
        attributes: *XSetWindowAttributes,
    ) callconv(.c) XID,
    XDestroyWindow: *const fn (display: *Display, window: XID) callconv(.c) c_int,
    XMapWindow: *const fn (display: *Display, window: XID) callconv(.c) c_int,
    XRaiseWindow: *const fn (display: *Display, window: XID) callconv(.c) c_int,
    XResizeWindow: *const fn (
        display: *Display,
        window: XID,
        width: c_uint,
        height: c_uint,
    ) callconv(.c) c_int,
    XSetInputFocus: *const fn (
        display: *Display,
        focus: XID,
        revert_to: c_int,
        time: Time,
    ) callconv(.c) c_int,
    XSelectInput: *const fn (
        display: *Display,
        window: XID,
        event_mask: c_long,
    ) callconv(.c) c_int,
    XStoreName: *const fn (
        display: *Display,
        window: XID,
        window_name: [*:0]const u8,
    ) callconv(.c) c_int,
    XSetWMProtocols: *const fn (
        display: *Display,
        window: XID,
        protocols: [*]Atom,
        count: c_int,
    ) callconv(.c) Status,
    XAllocSizeHints: *const fn () callconv(.c) ?*XSizeHints,
    XSetWMNormalHints: *const fn (
        display: *Display,
        window: XID,
        hints: *XSizeHints,
    ) callconv(.c) void,
    XAllocClassHint: *const fn () callconv(.c) ?*XClassHint,
    XSetClassHint: *const fn (
        display: *Display,
        window: XID,
        class_hints: *XClassHint,
    ) callconv(.c) c_int,
    XSendEvent: *const fn (
        display: *Display,
        window: XID,
        propagate: Bool,
        event_mask: c_long,
        event: *XEvent,
    ) callconv(.c) Status,
    // Properties.
    XInternAtoms: *const fn (
        display: *Display,
        names: [*]const [*:0]const u8,
        count: c_int,
        only_if_exists: Bool,
        atoms_return: [*]Atom,
    ) callconv(.c) Status,
    XChangeProperty: *const fn (
        display: *Display,
        window: XID,
        property: Atom,
        property_type: Atom,
        format: c_int,
        mode: c_int,
        data: [*]const u8,
        element_count: c_int,
    ) callconv(.c) c_int,
    XGetWindowProperty: *const fn (
        display: *Display,
        window: XID,
        property: Atom,
        long_offset: c_long,
        long_length: c_long,
        delete: Bool,
        requested_type: Atom,
        actual_type_return: *Atom,
        actual_format_return: *c_int,
        item_count_return: *c_ulong,
        bytes_after_return: *c_ulong,
        data_return: *?[*]u8,
    ) callconv(.c) c_int,
    XResourceManagerString: *const fn (display: *Display) callconv(.c) ?[*:0]const u8,
    // Keys and text.
    XGetKeyboardMapping: *const fn (
        display: *Display,
        first_keycode: KeyCode,
        keycode_count: c_int,
        keysyms_per_keycode_return: *c_int,
    ) callconv(.c) ?[*]KeySym,
    XkbSetDetectableAutoRepeat: *const fn (
        display: *Display,
        detectable: Bool,
        supported_return: ?*Bool,
    ) callconv(.c) Bool,
    XLookupString: *const fn (
        event: *XKeyEvent,
        buffer_return: ?[*]u8,
        buffer_length: c_int,
        keysym_return: ?*KeySym,
        status_in_out: ?*anyopaque,
    ) callconv(.c) c_int,
    XLookupKeysym: *const fn (event: *XKeyEvent, index: c_int) callconv(.c) KeySym,
};

/// Why the window could not open.
pub const WindowError = error{
    /// libX11 is not installed (Debian and Ubuntu: libx11-6).
    LibraryMissing,
    /// libX11 lacks a function zimr calls - a library too old, or not X.Org's.
    SymbolMissing,
    /// No X server to connect to: `DISPLAY` unset, or naming a server that does not answer.
    NoDisplay,
    CreateWindowFailed,
};

/// Opens the first of `names` that opens, and fills `Table` - a struct of function pointers named exactly as the C
/// functions - by looking each one up by its field's name. The library is never closed (see the top of this file).
fn loadLibrary(comptime Table: type, comptime names: []const [:0]const u8) WindowError!Table {
    const handle: *anyopaque = for (names) |name| {
        if (std.c.dlopen(name, .{ .LAZY = true })) |opened| {
            break opened;
        }
    } else return WindowError.LibraryMissing;
    var table: Table = undefined;
    const fields: std.lang.Type.Struct = @typeInfo(Table).@"struct";
    inline for (fields.field_names, fields.field_types) |field_name, FieldType| {
        const symbol: *anyopaque = std.c.dlsym(handle, field_name) orelse {
            var message_buffer: [160]u8 = undefined;
            const message: []const u8 = bufPrint(&message_buffer, "{s} has no {s}", .{ names[0], field_name }) catch
                field_name;
            console.log(.err, message);
            return WindowError.SymbolMissing;
        };
        // A function's address is aligned as the target's code is, where `dlsym`'s untyped pointer promises 1.
        @field(table, field_name) = @as(FieldType, @ptrCast(@alignCast(symbol)));
    }
    return table;
}

/// libX11, by its versioned name first - the one its run-time package installs - then the development name.
const xlib_names = [_][:0]const u8{ "libX11.so.6", "libX11.so" };

// ---- The pure parts, tested on any machine ----

/// The dots per inch X11 programs assume when the desktop sets none: 96, scale 1.
pub const default_dpi: f32 = 96;

/// The `Xft.dpi` line's value in the text of the X resource database (`XResourceManagerString`) - where GNOME, KDE
/// and Xfce write the desktop's scale, as dots per inch: the number after the colon, whitespace skipped. Null when no
/// line sets it, or its value is not a number above 0.
pub fn xftDpiOf(resources: []const u8) ?f32 {
    const prefix: []const u8 = "Xft.dpi:";
    var lines: SplitIterator(u8, .scalar) = splitScalar(u8, resources, '\n');
    while (lines.next()) |line| {
        if (!startsWith(u8, line, prefix)) {
            continue;
        }
        const value_text: []const u8 = trim(u8, line[prefix.len..], " \t\r");
        const dpi: f32 = parseFloat(f32, value_text) catch return null;
        return if (dpi > 0) dpi else null;
    }
    return null;
}

/// The window's scale, physical pixels per logical pixel: `override` - the `ZIMR_SCALE` setting - when it is set and
/// above 0, else `dpi` over 96. The override is for a desktop that magnifies X programs itself and also sets
/// `Xft.dpi`, which would scale zimr twice (GNOME on Wayland at scale 2, say).
pub fn scaleOf(dpi: f32, override: ?f32) f32 {
    if (override) |scale_override| {
        if (scale_override > 0) {
            return scale_override;
        }
    }
    return dpi / default_dpi;
}

/// The character a keysym types, as a code point; 0 for a keysym that types none (Shift, an arrow). Keysyms 0x20 to
/// 0x7e and 0xa0 to 0xff are Latin-1's own code points; 0x0100_0000 plus a code point is that code point (keysymdef.h:
/// "Unicode characters"). The older keysyms of other scripts (Cyrillic's 0x6c1, ...) give none here - the input
/// method, which knows them, comes with stage L4.
pub fn codePointOfKeysym(keysym: KeySym) u21 {
    const is_printable_ascii: bool = keysym >= 0x20 and keysym <= 0x7e;
    const is_printable_latin1: bool = keysym >= 0xa0 and keysym <= 0xff;
    if (is_printable_ascii or is_printable_latin1) {
        return @intCast(keysym);
    }
    const unicode_base: KeySym = 0x0100_0000;
    const is_unicode: bool = keysym >= unicode_base and keysym - unicode_base <= 0x10_ffff;
    if (is_unicode) {
        return @intCast(keysym - unicode_base);
    }
    return 0;
}

/// Latin-1 text - what `XLookupString` writes - as UTF-8 in `out`: each byte below 0x80 as itself, each other as two.
/// A text longer than `out` keeps its first characters, whole.
pub fn latin1ToUtf8(latin1: []const u8, out: []u8) []const u8 {
    var written: usize = 0;
    for (latin1) |byte| {
        const is_ascii: bool = byte < 0x80;
        const byte_count: usize = if (is_ascii) 1 else 2;
        if (written + byte_count > out.len) {
            break;
        }
        if (is_ascii) {
            out[written] = byte;
        } else {
            out[written] = 0xc0 | (byte >> 6);
            out[written + 1] = 0x80 | (byte & 0x3f);
        }
        written += byte_count;
    }
    return out[0..written];
}

/// What a key types without modifiers, from its first keysym (`XLookupKeysym`, index 0), lowercased as Windows'
/// label is - A to Z - and 0 when it types nothing by itself.
pub fn labelOfKeysym(keysym: KeySym) u21 {
    const code_point: u21 = codePointOfKeysym(keysym);
    const is_capital: bool = code_point >= 'A' and code_point <= 'Z';
    return if (is_capital) code_point - 'A' + 'a' else code_point;
}

// ---- The input message: what the window hands the loop ----

pub const InputKind = enum {
    key_press,
    key_release,
    text,
    button_press,
    button_release,
    motion,
    locked_motion,
    enter,
    leave,
    focus_in,
    focus_out,
    pointer_lock_changed,
    fullscreen_changed,
    paste,
};

/// One input message, as X's numbers give it; `native_input.translateX11` turns it into the engine's events.
pub const InputMessage = struct {
    kind: InputKind,
    /// A key message's X keycode (the evdev code plus 8), or a button message's X button number (1 the first).
    detail: u32 = 0,
    /// A key press of a key already down: the server's auto-repeat.
    is_repeat: bool = false,
    /// A key press: what the key types without modifiers on the current layout, lowercased; 0 for nothing.
    label: u21 = 0,
    /// A pointer message's position, in the window's physical pixels; a locked pointer's motion, how far.
    x: i32 = 0,
    y: i32 = 0,
    /// The window's scale when the message was made.
    scale: f32 = 1,
    /// Text and paste: UTF-8, in the window's buffer until its next message of that kind.
    text: []const u8 = &.{},
    /// A pointer lock's or fullscreen's outcome.
    is_on: bool = false,
};

/// Receives the window's input messages.
pub const InputHandler = *const fn (message: InputMessage) void;

// ---- The window ----

pub const WindowOptions = struct {
    title: []const u8,
    /// The client area's size in logical pixels; the window opens at this size times the scale.
    logical_width: u32,
    logical_height: u32,
};

/// The atoms the window uses - X's names for properties, protocols and types - interned once when it opens, each a
/// field named as X names it (`internAtoms`).
pub const Atoms = struct {
    WM_PROTOCOLS: Atom,
    WM_DELETE_WINDOW: Atom,
    _NET_WM_PING: Atom,
    _NET_WM_PID: Atom,
    _NET_WM_NAME: Atom,
    _NET_WM_ICON_NAME: Atom,
    UTF8_STRING: Atom,
    _NET_SUPPORTED: Atom,
    _NET_WM_STATE: Atom,
    _NET_WM_STATE_FULLSCREEN: Atom,
    _NET_WM_STATE_MAXIMIZED_VERT: Atom,
    _NET_WM_STATE_MAXIMIZED_HORZ: Atom,
    _NET_WM_STATE_HIDDEN: Atom,
    _NET_ACTIVE_WINDOW: Atom,
};

/// Which of EWMH's requests the window manager says it carries out - the atoms its `_NET_SUPPORTED` lists. A request
/// it does not list would be ignored while zimr reported success.
pub const EwmhSupport = struct {
    window_state: bool = false,
    fullscreen: bool = false,
    hidden: bool = false,
    active_window: bool = false,
};

/// The events the window selects: keys, buttons, the pointer's motion and its entering and leaving, exposure, its
/// structure (map, unmap, configure), focus, and its properties (the window manager's `_NET_WM_STATE`).
const window_event_mask: c_long = KeyPressMask | KeyReleaseMask | ButtonPressMask | ButtonReleaseMask |
    EnterWindowMask | LeaveWindowMask | PointerMotionMask | ExposureMask | StructureNotifyMask | FocusChangeMask |
    PropertyChangeMask;

/// How long `open` waits for the window manager to map the window before going on: the first frame must not present
/// to an unmapped window, which blocks on some drivers.
const map_wait_milliseconds: f64 = 1000;

/// How close a release and the press after it are, on the server's clock, to be one auto-repeat rather than a person's
/// two keystrokes - GLFW's 20 ms: nobody types the same key 50 times a second.
const repeat_pair_milliseconds: Time = 20;

/// Logs a failed X request instead of ending the program, as Xlib's own handler would: a request can fail for reasons
/// the program survives - a window already gone at teardown.
fn logXError(display: ?*Display, event: *XErrorEvent) callconv(.c) c_int {
    _ = display;
    var message_buffer: [160]u8 = undefined;
    const message: []const u8 = bufPrint(&message_buffer, "an X request failed: error {d}, request {d}.{d}, " ++
        "resource 0x{x}", .{ event.error_code, event.request_code, event.minor_code, event.resourceid }) catch
        "an X request failed";
    console.log(.warn, message);
    return 0;
}

/// Interns every atom of `Atoms` in one request (`XInternAtoms`), each by its field's name.
fn internAtoms(xlib: *const Xlib, display: *Display) Atoms {
    const fields: std.lang.Type.Struct = @typeInfo(Atoms).@"struct";
    const names: [fields.field_names.len][*:0]const u8 = comptime listed_names: {
        var listed: [fields.field_names.len][*:0]const u8 = undefined;
        for (fields.field_names, 0..) |field_name, index| {
            listed[index] = field_name;
        }
        break :listed_names listed;
    };
    var values: [fields.field_names.len]Atom = @splat(None);
    _ = xlib.XInternAtoms(display, &names, names.len, False, &values);
    var atoms: Atoms = undefined;
    inline for (fields.field_names, 0..) |field_name, index| {
        @field(atoms, field_name) = values[index];
    }
    return atoms;
}

/// The most atoms an atom-list property is read for: EWMH's whole list is under a hundred.
const atom_list_capacity: usize = 256;

/// The atoms `owner`'s property lists (`_NET_SUPPORTED`, `_NET_WM_STATE`), copied into `out`; empty when there is no
/// such property. A property of 32-bit items comes back from Xlib as an array of C longs - 8 bytes each on 64-bit
/// Linux - which is what an `Atom` is.
fn readAtomList(
    xlib: *const Xlib,
    display: *Display,
    owner: XID,
    property: Atom,
    out: []Atom,
) []Atom {
    var actual_type: Atom = None;
    var actual_format: c_int = 0;
    var item_count: c_ulong = 0;
    var bytes_after: c_ulong = 0;
    var data: ?[*]u8 = null;
    const status: c_int = xlib.XGetWindowProperty(
        display,
        owner,
        property,
        0,
        zm.maxInt(c_long),
        False,
        XA_ATOM,
        &actual_type,
        &actual_format,
        &item_count,
        &bytes_after,
        &data,
    );
    const bytes: [*]u8 = data orelse return out[0..0];
    defer _ = xlib.XFree(@ptrCast(bytes));
    const is_atom_list: bool = status == Success and actual_type == XA_ATOM and actual_format == 32;
    if (!is_atom_list) {
        return out[0..0];
    }
    const listed: [*]const Atom = @ptrCast(@alignCast(bytes));
    const count: usize = @min(item_count, out.len);
    @memcpy(out[0..count], listed[0..count]);
    return out[0..count];
}

/// Whether `atoms` lists `wanted`.
fn listsAtom(atoms: []const Atom, wanted: Atom) bool {
    for (atoms) |atom| {
        if (atom == wanted) {
            return true;
        }
    }
    return false;
}

/// What the window manager supports of EWMH, from the root window's `_NET_SUPPORTED`.
fn readEwmhSupport(
    xlib: *const Xlib,
    display: *Display,
    root: XID,
    atoms: Atoms,
) EwmhSupport {
    var listed_buffer: [atom_list_capacity]Atom = undefined;
    const listed: []const Atom = readAtomList(xlib, display, root, atoms._NET_SUPPORTED, &listed_buffer);
    return .{
        .window_state = listsAtom(listed, atoms._NET_WM_STATE),
        .fullscreen = listsAtom(listed, atoms._NET_WM_STATE_FULLSCREEN),
        .hidden = listsAtom(listed, atoms._NET_WM_STATE_HIDDEN),
        .active_window = listsAtom(listed, atoms._NET_ACTIVE_WINDOW),
    };
}

/// The desktop's dots per inch: its `Xft.dpi` (`xftDpiOf`), or 96 when it sets none.
fn readDpi(xlib: *const Xlib, display: *Display) f32 {
    const resources: [*:0]const u8 = xlib.XResourceManagerString(display) orelse return default_dpi;
    return xftDpiOf(span(resources)) orelse default_dpi;
}

/// The `ZIMR_SCALE` setting, when it is a number.
fn readScaleOverride() ?f32 {
    var setting_buffer: [32]u8 = undefined;
    const setting: []const u8 = native_os.environmentVariable("ZIMR_SCALE", &setting_buffer) orelse return null;
    return parseFloat(f32, trim(u8, setting, " ")) catch null;
}

/// Whether the server's keycodes are evdev's - the Linux kernel's key codes plus 8, which `native_input` maps keys by:
/// keycode 9 is Escape and keycode 36 Enter. Every X server on Linux uses them today, XWayland's included; one that
/// does not is told of once, its keys perhaps misplaced.
fn hasEvdevKeycodes(xlib: *const Xlib, display: *Display) bool {
    const escape_keycode: KeyCode = 9;
    const enter_keycode: KeyCode = 36;
    const keycode_count: c_int = enter_keycode - escape_keycode + 1;
    var keysyms_per_keycode: c_int = 0;
    const mapping: ?[*]KeySym = xlib.XGetKeyboardMapping(display, escape_keycode, keycode_count, &keysyms_per_keycode);
    const keysyms: [*]KeySym = mapping orelse return true;
    defer _ = xlib.XFree(@ptrCast(keysyms));
    if (keysyms_per_keycode <= 0) {
        return true;
    }
    const per_keycode: usize = @intCast(keysyms_per_keycode);
    const enter_index: usize = (enter_keycode - escape_keycode) * per_keycode;
    return keysyms[0] == XK_Escape and keysyms[enter_index] == XK_Return;
}

/// The physical size of a logical one at `window_scale`, at least a pixel.
fn physicalSize(logical: u32, window_scale: f32) c_uint {
    const rounded: c_uint = @round(float(logical) * window_scale);
    return @max(rounded, 1);
}

pub const Window = struct {
    // ---- The members the native loop and the Vulkan host read: win32.Window's names and meanings ----

    /// The client area's size in physical pixels.
    client_width: u32,
    client_height: u32,
    /// The close button was pressed: the window manager's `WM_DELETE_WINDOW`.
    close_requested: bool,
    /// Nothing of the window can be seen: not mapped, or hidden by the window manager (`_NET_WM_STATE_HIDDEN` - a
    /// compositing window manager may keep a minimized window mapped).
    minimized: bool,
    /// The client size changed; the Vulkan host clears it once its swapchain follows.
    size_changed: bool,
    /// Whether the window manager was asked for fullscreen (`setFullscreen`), or reported it.
    is_fullscreen: bool = false,
    /// Set when the monitors may have changed: with stage L5's monitor list.
    monitors_changed: bool = false,
    /// Where input messages go; none until the program sets one.
    input_handler: ?InputHandler,
    /// The client area's size limits, in logical pixels (0: unlimited), handed to the window manager at the window's
    /// scale (`applySizeLimits`).
    min_client_width: f32 = 0,
    min_client_height: f32 = 0,
    max_client_width: f32 = 0,
    max_client_height: f32 = 0,

    // ---- X11's own ----

    xlib: Xlib,
    /// The connection to the X server.
    display: *Display,
    /// The window's id on the server.
    handle: XID,
    screen: c_int,
    root: XID,
    colormap: Colormap,
    atoms: Atoms,
    supports: EwmhSupport,
    /// The desktop's dots per inch (`Xft.dpi`), and the `ZIMR_SCALE` setting: the scale (`scale`).
    dpi: f32,
    scale_override: ?f32,
    /// Whether the window manager has mapped the window, and whether it hides it while mapped.
    is_mapped: bool = false,
    is_hidden_by_manager: bool = false,
    has_focus: bool = false,
    /// Whether a text field takes text (`setInputMethodEnabled`) - the input method's switch, from stage L4.
    is_text_input_on: bool = false,
    /// Whether the server sends a held key's repeats as presses alone (`XkbSetDetectableAutoRepeat`); otherwise each
    /// repeat comes as a release and a press, told apart by their times (`repeat_pair_milliseconds`).
    has_detectable_repeat: bool = false,
    /// The keys down, by X keycode: a press of one already down is an auto-repeat.
    keys_down: StaticBitSet(256) = .empty,
    is_pointer_inside: bool = false,
    /// The text of the latest key press, as UTF-8 (`InputMessage.text`).
    text_utf8: [256]u8 = undefined,

    /// Opens the window: connects to the X server, makes the window - its size the logical one times the scale - tells
    /// the window manager about it, maps it, and waits until it is mapped.
    pub fn open(window: *Window, options: WindowOptions) WindowError!void {
        const xlib: Xlib = loadLibrary(Xlib, &xlib_names) catch |err| {
            if (err == WindowError.LibraryMissing) {
                console.log(.err, "libX11.so.6 is not installed (Debian, Ubuntu: libx11-6): no window can open");
            }
            return err;
        };
        // Before any other call: the Vulkan driver presents from a thread of its own, on the same connection.
        _ = xlib.XInitThreads();
        const display: *Display = xlib.XOpenDisplay(null) orelse {
            var display_buffer: [128]u8 = undefined;
            const display_name: []const u8 = native_os.environmentVariable("DISPLAY", &display_buffer) orelse
                "unset";
            var message_buffer: [256]u8 = undefined;
            const message: []const u8 = bufPrint(&message_buffer, "cannot connect to the X server (DISPLAY: {s})", .{
                display_name,
            }) catch "cannot connect to the X server";
            console.log(.err, message);
            return WindowError.NoDisplay;
        };
        errdefer _ = xlib.XCloseDisplay(display);
        _ = xlib.XSetErrorHandler(&logXError);
        const screen: c_int = xlib.XDefaultScreen(display);
        const root: XID = xlib.XRootWindow(display, screen);
        const atoms: Atoms = internAtoms(&xlib, display);
        window.* = .{
            .client_width = 0,
            .client_height = 0,
            .close_requested = false,
            .minimized = true,
            .size_changed = false,
            .input_handler = null,
            .xlib = xlib,
            .display = display,
            .handle = None,
            .screen = screen,
            .root = root,
            .colormap = None,
            .atoms = atoms,
            .supports = readEwmhSupport(&xlib, display, root, atoms),
            .dpi = readDpi(&xlib, display),
            .scale_override = readScaleOverride(),
        };
        if (!hasEvdevKeycodes(&xlib, display)) {
            console.log(.warn, "this X server's keycodes are not evdev's: keys may be named wrongly");
        }
        try window.createWindow(options);
        window.setWindowManagerHints(options.title);
        var is_supported: Bool = False;
        _ = xlib.XkbSetDetectableAutoRepeat(display, True, &is_supported);
        window.has_detectable_repeat = is_supported != False;
        _ = xlib.XMapWindow(display, window.handle);
        window.waitUntilMapped();
        window.size_changed = false;
    }

    /// The X window itself, on the default visual, at the logical size times the scale, selecting the window's events.
    fn createWindow(window: *Window, options: WindowOptions) WindowError!void {
        const xlib: *const Xlib = &window.xlib;
        const visual: ?*Visual = xlib.XDefaultVisual(window.display, window.screen);
        const depth: c_int = xlib.XDefaultDepth(window.display, window.screen);
        window.colormap = xlib.XCreateColormap(window.display, window.root, visual, AllocNone);
        var attributes: XSetWindowAttributes = .{
            .border_pixel = 0,
            .colormap = window.colormap,
            .event_mask = window_event_mask,
        };
        const window_scale: f32 = window.scale();
        const width: c_uint = physicalSize(options.logical_width, window_scale);
        const height: c_uint = physicalSize(options.logical_height, window_scale);
        const handle: XID = xlib.XCreateWindow(
            window.display,
            window.root,
            0,
            0,
            width,
            height,
            0,
            depth,
            InputOutput,
            visual,
            CWBorderPixel | CWColormap | CWEventMask,
            &attributes,
        );
        if (handle == None) {
            _ = xlib.XFreeColormap(window.display, window.colormap);
            return WindowError.CreateWindowFailed;
        }
        window.handle = handle;
        window.client_width = width;
        window.client_height = height;
    }

    /// What the window manager is told before it maps the window: the protocols the window answers - the close button
    /// and the ping that shows the program alive - its process, its size hints, its class, and its title.
    fn setWindowManagerHints(window: *Window, title: []const u8) void {
        const xlib: *const Xlib = &window.xlib;
        var protocols: [2]Atom = .{ window.atoms.WM_DELETE_WINDOW, window.atoms._NET_WM_PING };
        _ = xlib.XSetWMProtocols(window.display, window.handle, &protocols, protocols.len);
        // A 32-bit property is passed as C longs.
        const process_id: c_long = std.c.getpid();
        const process_id_bytes: [*]const u8 = @ptrCast(&process_id);
        _ = xlib.XChangeProperty(
            window.display,
            window.handle,
            window.atoms._NET_WM_PID,
            XA_CARDINAL,
            32,
            PropModeReplace,
            process_id_bytes,
            1,
        );
        window.setNormalHints();
        // The class: the program's own name, and "zimr" - what a desktop groups windows and finds their icon by.
        if (xlib.XAllocClassHint()) |class_hints| {
            defer _ = xlib.XFree(class_hints);
            var name_buffer: [256]u8 = undefined;
            var name_z: [257:0]u8 = @splat(0);
            const program_name: []const u8 = native_os.programName(native_os.servicesIo(), &name_buffer) orelse "zimr";
            @memcpy(name_z[0..program_name.len], program_name);
            class_hints.* = .{ .res_name = &name_z, .res_class = "zimr" };
            _ = xlib.XSetClassHint(window.display, window.handle, class_hints);
        }
        window.setTitle(title);
    }

    /// The size hints (ICCCM's `WM_NORMAL_HINTS`): a position given is the client area's (`StaticGravity`), and the
    /// client area's limits at the window's scale - a limit not set leaves its side free.
    fn setNormalHints(window: *Window) void {
        const xlib: *const Xlib = &window.xlib;
        const hints: *XSizeHints = xlib.XAllocSizeHints() orelse return;
        defer _ = xlib.XFree(hints);
        hints.flags = PWinGravity;
        hints.win_gravity = StaticGravity;
        const window_scale: f32 = window.scale();
        const has_minimum: bool = window.min_client_width > 0 or window.min_client_height > 0;
        if (has_minimum) {
            hints.flags |= PMinSize;
            hints.min_width = @round(window.min_client_width * window_scale);
            hints.min_height = @round(window.min_client_height * window_scale);
        }
        const has_maximum: bool = window.max_client_width > 0 or window.max_client_height > 0;
        if (has_maximum) {
            hints.flags |= PMaxSize;
            hints.max_width = largest_window_size;
            hints.max_height = largest_window_size;
            if (window.max_client_width > 0) {
                hints.max_width = @round(window.max_client_width * window_scale);
            }
            if (window.max_client_height > 0) {
                hints.max_height = @round(window.max_client_height * window_scale);
            }
        }
        xlib.XSetWMNormalHints(window.display, window.handle, hints);
    }

    /// Handles events until the window manager has mapped the window, or `map_wait_milliseconds` have passed - a
    /// window manager that never maps it must not hang the program.
    fn waitUntilMapped(window: *Window) void {
        const start_ms: f64 = native_os.monotonicMilliseconds();
        while (!window.is_mapped) {
            const waited_ms: f64 = native_os.monotonicMilliseconds() - start_ms;
            if (waited_ms >= map_wait_milliseconds) {
                console.log(.warn, "the window manager has not shown the window after a second; going on");
                return;
            }
            window.waitForInput(map_wait_milliseconds - waited_ms);
            window.pump();
        }
    }

    /// Handles every event waiting, then sends what the handling asked of the server: call once per frame.
    pub fn pump(window: *Window) void {
        var event: XEvent = undefined;
        while (window.xlib.XPending(window.display) > 0) {
            _ = window.xlib.XNextEvent(window.display, &event);
            window.handleEvent(&event);
        }
        _ = window.xlib.XFlush(window.display);
    }

    /// Sleeps until an event arrives or `milliseconds` pass: on the connection's socket (`poll`), once everything
    /// already read is handled - `XPending` reads what the socket holds, so an event that came meanwhile wakes the
    /// sleep at once.
    pub fn waitForInput(window: *Window, milliseconds: f64) void {
        if (window.xlib.XPending(window.display) > 0) {
            return;
        }
        var watched: [1]std.c.pollfd = .{.{
            .fd = window.xlib.XConnectionNumber(window.display),
            .events = std.c.POLL.IN,
            .revents = 0,
        }};
        // Rounded up, so that a wait does not end a hair early; a second at most, whatever the caller asks.
        const timeout_ms: c_int = @ceil(clamp(milliseconds, 0, 1000));
        // An interrupted wait (EINTR) returns early, which the caller's loop absorbs.
        _ = std.c.poll(&watched, watched.len, timeout_ms);
    }

    /// Closes the window and the connection. The library stays open (see the top of this file).
    pub fn close(window: *Window) void {
        _ = window.xlib.XDestroyWindow(window.display, window.handle);
        _ = window.xlib.XFreeColormap(window.display, window.colormap);
        _ = window.xlib.XCloseDisplay(window.display);
    }

    /// Physical pixels per logical pixel (`scaleOf`): 1 at 96 dots per inch, 2 at 192.
    pub fn scale(window: *const Window) f32 {
        return scaleOf(window.dpi, window.scale_override);
    }

    /// Hands a message to the input handler, with the window's scale.
    fn forward(window: *const Window, message: InputMessage) void {
        const handler: InputHandler = window.input_handler orelse return;
        var scaled: InputMessage = message;
        scaled.scale = window.scale();
        handler(scaled);
    }

    /// Asks the window manager for something on the window's behalf (EWMH): a client message to the root window, the
    /// window manager's address.
    fn sendToWindowManager(window: *Window, message_type: Atom, data: [5]c_long) void {
        var event: XEvent = .{ .pad = @splat(0) };
        event.xclient = .{
            .type = ClientMessage,
            .serial = 0,
            .send_event = True,
            .display = window.display,
            .window = window.handle,
            .message_type = message_type,
            .format = 32,
            .data = .{ .l = data },
        };
        const mask: c_long = SubstructureNotifyMask | SubstructureRedirectMask;
        _ = window.xlib.XSendEvent(window.display, window.root, False, mask, &event);
    }

    fn handleEvent(window: *Window, event: *XEvent) void {
        switch (event.type) {
            KeyPress => window.handleKeyPress(&event.xkey),
            KeyRelease => window.handleKeyRelease(&event.xkey),
            ButtonPress, ButtonRelease => {
                const button: XButtonEvent = event.xbutton;
                window.forward(.{
                    .kind = if (button.type == ButtonPress) .button_press else .button_release,
                    .detail = button.button,
                    .x = button.x,
                    .y = button.y,
                });
            },
            MotionNotify => window.forward(.{ .kind = .motion, .x = event.xmotion.x, .y = event.xmotion.y }),
            EnterNotify => {
                window.is_pointer_inside = true;
                window.forward(.{ .kind = .enter, .x = event.xcrossing.x, .y = event.xcrossing.y });
            },
            LeaveNotify => {
                window.is_pointer_inside = false;
                window.forward(.{ .kind = .leave });
            },
            FocusIn, FocusOut => window.handleFocus(event.xfocus),
            ConfigureNotify => window.handleConfigure(event.xconfigure),
            MapNotify => {
                if (event.xmap.window == window.handle) {
                    window.is_mapped = true;
                    window.updateMinimized();
                }
            },
            UnmapNotify => {
                if (event.xunmap.window == window.handle) {
                    window.is_mapped = false;
                    window.updateMinimized();
                }
            },
            PropertyNotify => {
                const is_window_state: bool = event.xproperty.window == window.handle and
                    event.xproperty.atom == window.atoms._NET_WM_STATE;
                if (is_window_state) {
                    window.readWindowState();
                }
            },
            ClientMessage => window.handleClientMessage(event),
            else => {},
        }
    }

    /// A key going down: a press - an auto-repeat when the key is down already - with what the key types by itself,
    /// then the text it types with its modifiers, through `XLookupString`: Latin-1, turned into UTF-8; a keysym of
    /// Unicode's that has no Latin-1 bytes, its own character.
    fn handleKeyPress(window: *Window, key: *XKeyEvent) void {
        const keycode: u8 = @intCast(key.keycode);
        const is_repeat: bool = window.keys_down.isSet(keycode);
        window.keys_down.set(keycode);
        const label: u21 = labelOfKeysym(window.xlib.XLookupKeysym(key, 0));
        window.forward(.{ .kind = .key_press, .detail = keycode, .is_repeat = is_repeat, .label = label });
        var latin1_buffer: [128]u8 = undefined;
        var keysym: KeySym = 0;
        const byte_count: c_int = window.xlib.XLookupString(key, &latin1_buffer, latin1_buffer.len, &keysym, null);
        const latin1: []const u8 = latin1_buffer[0..@intCast(@max(byte_count, 0))];
        var text: []const u8 = latin1ToUtf8(latin1, &window.text_utf8);
        if (text.len == 0) {
            const code_point: u21 = codePointOfKeysym(keysym);
            const is_beyond_latin1: bool = code_point > 0xff;
            if (is_beyond_latin1) {
                const encoded_count: u3 = std.unicode.utf8Encode(code_point, &window.text_utf8) catch 0;
                text = window.text_utf8[0..encoded_count];
            }
        }
        if (text.len > 0) {
            window.forward(.{ .kind = .text, .text = text });
        }
    }

    /// A key coming up. Without detectable auto-repeat, a held key repeats as a release and a press together: a
    /// release with its key's press right behind it on the server's clock is such a pair, and is dropped - the press
    /// then reads as a repeat, the key still being down.
    fn handleKeyRelease(window: *Window, key: *XKeyEvent) void {
        const keycode: u8 = @intCast(key.keycode);
        if (!window.has_detectable_repeat and window.xlib.XEventsQueued(window.display, QueuedAfterReading) > 0) {
            var next: XEvent = undefined;
            _ = window.xlib.XPeekEvent(window.display, &next);
            const is_same_key_press: bool = next.type == KeyPress and next.xkey.window == key.window and
                next.xkey.keycode == key.keycode;
            // Times wrap around; their difference, taken the same way, does not mind.
            const is_repeat_pair: bool = is_same_key_press and next.xkey.time -% key.time < repeat_pair_milliseconds;
            if (is_repeat_pair) {
                return;
            }
        }
        window.keys_down.unset(keycode);
        window.forward(.{ .kind = .key_release, .detail = keycode });
    }

    /// Focus gained or lost. The changes a grab makes - a window manager's own key chords, a drag of the window - are
    /// not the window's (GLFW skips them too). Losing focus forgets the keys down, as the engine releases them: a key
    /// held across the change must not read as an auto-repeat when it is pressed again.
    fn handleFocus(window: *Window, focus: XFocusChangeEvent) void {
        const is_grab_change: bool = focus.mode == NotifyGrab or focus.mode == NotifyUngrab;
        if (is_grab_change) {
            return;
        }
        if (focus.type == FocusIn) {
            window.has_focus = true;
            window.forward(.{ .kind = .focus_in });
            return;
        }
        window.releasePointerLock();
        window.has_focus = false;
        window.keys_down = .empty;
        window.forward(.{ .kind = .focus_out });
    }

    /// The window's size, as the window manager gave it.
    fn handleConfigure(window: *Window, configure: XConfigureEvent) void {
        if (configure.window != window.handle) {
            return;
        }
        const width: u32 = @intCast(@max(configure.width, 0));
        const height: u32 = @intCast(@max(configure.height, 0));
        if (width != window.client_width or height != window.client_height) {
            window.client_width = width;
            window.client_height = height;
            window.size_changed = true;
        }
    }

    /// The window manager's protocols: the close button (`WM_DELETE_WINDOW`), and the ping that asks whether the
    /// program still answers (`_NET_WM_PING`), answered by sending it back to the root window.
    fn handleClientMessage(window: *Window, event: *XEvent) void {
        const message: XClientMessageEvent = event.xclient;
        if (message.message_type != window.atoms.WM_PROTOCOLS) {
            return;
        }
        const protocol: Atom = @bitCast(message.data.l[0]);
        if (protocol == window.atoms.WM_DELETE_WINDOW) {
            window.close_requested = true;
        } else if (protocol == window.atoms._NET_WM_PING) {
            var reply: XEvent = event.*;
            reply.xclient.window = window.root;
            const mask: c_long = SubstructureNotifyMask | SubstructureRedirectMask;
            _ = window.xlib.XSendEvent(window.display, window.root, False, mask, &reply);
        }
    }

    /// The window manager's state for the window (`_NET_WM_STATE`): hidden - minimized while still mapped - and
    /// fullscreen, which the window manager may change itself (a key of its own).
    fn readWindowState(window: *Window) void {
        var state_buffer: [atom_list_capacity]Atom = undefined;
        const state: []const Atom = readAtomList(
            &window.xlib,
            window.display,
            window.handle,
            window.atoms._NET_WM_STATE,
            &state_buffer,
        );
        window.is_hidden_by_manager = listsAtom(state, window.atoms._NET_WM_STATE_HIDDEN);
        window.updateMinimized();
        const is_fullscreen_now: bool = listsAtom(state, window.atoms._NET_WM_STATE_FULLSCREEN);
        if (is_fullscreen_now != window.is_fullscreen) {
            window.is_fullscreen = is_fullscreen_now;
            window.forward(.{ .kind = .fullscreen_changed, .is_on = is_fullscreen_now });
        }
    }

    fn updateMinimized(window: *Window) void {
        window.minimized = !window.is_mapped or window.is_hidden_by_manager;
    }

    /// Sets the title bar's text: `_NET_WM_NAME` in UTF-8, which window managers show, and the older `WM_NAME` too. A
    /// title longer than the buffer is cut at the last character boundary that fits.
    pub fn setTitle(window: *Window, title: []const u8) void {
        var title_z: [256:0]u8 = @splat(0);
        var fitting_length: usize = @min(title.len, title_z.len);
        // A UTF-8 continuation byte (10xxxxxx) at the cut means the cut splits a character: move the cut back.
        while (fitting_length > 0 and fitting_length < title.len and title[fitting_length] & 0xc0 == 0x80) {
            fitting_length -= 1;
        }
        @memcpy(title_z[0..fitting_length], title[0..fitting_length]);
        const xlib: *const Xlib = &window.xlib;
        _ = xlib.XStoreName(window.display, window.handle, &title_z);
        const title_length: c_int = @intCast(fitting_length);
        for ([_]Atom{ window.atoms._NET_WM_NAME, window.atoms._NET_WM_ICON_NAME }) |property| {
            _ = xlib.XChangeProperty(
                window.display,
                window.handle,
                property,
                window.atoms.UTF8_STRING,
                8,
                PropModeReplace,
                &title_z,
                title_length,
            );
        }
        _ = xlib.XFlush(window.display);
    }

    /// Fullscreen on or off, asked of the window manager (EWMH's `_NET_WM_STATE_FULLSCREEN`) and reported at once, as
    /// Windows reports it; a later change the window manager makes itself arrives as the window's state
    /// (`readWindowState`). A window manager that does not list fullscreen as supported cannot give it: reported off.
    pub fn setFullscreen(window: *Window, on: bool) void {
        if (!window.supports.fullscreen) {
            window.forward(.{ .kind = .fullscreen_changed, .is_on = false });
            return;
        }
        if (on != window.is_fullscreen) {
            const action: c_long = if (on) _NET_WM_STATE_ADD else _NET_WM_STATE_REMOVE;
            const fullscreen: c_long = @bitCast(window.atoms._NET_WM_STATE_FULLSCREEN);
            window.sendToWindowManager(window.atoms._NET_WM_STATE, .{ action, fullscreen, 0, source_application, 0 });
            _ = window.xlib.XFlush(window.display);
            window.is_fullscreen = on;
        }
        window.forward(.{ .kind = .fullscreen_changed, .is_on = on });
    }

    /// Asks to bring the window to the front: through the window manager when it supports it (`_NET_ACTIVE_WINDOW`),
    /// which may decline for a program the person is not using; else raised and given focus directly.
    pub fn bringToFront(window: *Window) void {
        if (window.supports.active_window) {
            // Asked by an application; the time of the person's last action unknown (`CurrentTime`); no window of
            // ours active now.
            window.sendToWindowManager(window.atoms._NET_ACTIVE_WINDOW, .{ source_application, 0, 0, 0, 0 });
        } else {
            _ = window.xlib.XRaiseWindow(window.display, window.handle);
            _ = window.xlib.XSetInputFocus(window.display, window.handle, RevertToParent, CurrentTime);
        }
        _ = window.xlib.XFlush(window.display);
    }

    /// The client area's size limits handed to the window manager (`setNormalHints`), and the window resized into them
    /// at once when it lies outside - in logical pixels at the window's scale, as Win32's does. A fullscreen or
    /// minimized window is left as it is: the limits apply once it returns.
    pub fn applySizeLimits(window: *Window) void {
        window.setNormalHints();
        if (window.is_fullscreen or window.minimized) {
            _ = window.xlib.XFlush(window.display);
            return;
        }
        const window_scale: f32 = window.scale();
        const current_width: f32 = float(window.client_width) / window_scale;
        const current_height: f32 = float(window.client_height) / window_scale;
        var width: f32 = current_width;
        var height: f32 = current_height;
        if (window.min_client_width > 0) {
            width = @max(width, window.min_client_width);
        }
        if (window.max_client_width > 0) {
            width = @min(width, window.max_client_width);
        }
        if (window.min_client_height > 0) {
            height = @max(height, window.min_client_height);
        }
        if (window.max_client_height > 0) {
            height = @min(height, window.max_client_height);
        }
        const is_inside: bool = width == current_width and height == current_height;
        if (!is_inside) {
            const rounded_width: c_uint = @round(width * window_scale);
            const rounded_height: c_uint = @round(height * window_scale);
            const physical_width: c_uint = @max(rounded_width, 1);
            const physical_height: c_uint = @max(rounded_height, 1);
            _ = window.xlib.XResizeWindow(window.display, window.handle, physical_width, physical_height);
        }
        _ = window.xlib.XFlush(window.display);
    }

    /// Text input on or off. The input method it switches, for dead keys, compose and the languages typed through
    /// one, comes with stage L4; until then text arrives either way, through `XLookupString`.
    pub fn setInputMethodEnabled(window: *Window, is_enabled: bool) void {
        window.is_text_input_on = is_enabled;
    }

    /// Pointer lock comes with stage L4 (linux_port_plan.md: grab, blank cursor, warp to the centre): until then it is
    /// refused at once, as a system that cannot lock refuses it.
    pub fn lockPointer(window: *Window) void {
        window.forward(.{ .kind = .pointer_lock_changed, .is_on = false });
    }

    /// Ends a pointer lock - none is ever granted before stage L4.
    pub fn releasePointerLock(window: *Window) void {
        _ = window;
    }

    /// The clipboard comes with stage L5 (`CLIPBOARD` selections): until then nothing is pasted.
    pub fn requestPaste(window: *Window) void {
        _ = window;
    }
};

// ---- Tests: the pure parts ----

test "x11: Xft.dpi is read from the resource database's text" {
    try expectEqual(@as(?f32, 144), xftDpiOf("Xft.dpi:\t144\n"));
    try expectEqual(@as(?f32, 96), xftDpiOf("Xft.antialias:\t1\nXft.dpi:\t96.000000\nXft.hinting:\t1\n"));
    try expectEqual(@as(?f32, 120), xftDpiOf("Xft.dpi: 120"));
    try expectEqual(@as(?f32, null), xftDpiOf("Xft.antialias:\t1\n"));
    try expectEqual(@as(?f32, null), xftDpiOf("Xft.dpi:\t0\n"));
    try expectEqual(@as(?f32, null), xftDpiOf("Xft.dpix:\t1\n"));
    try expectEqual(@as(?f32, null), xftDpiOf(""));
}

test "x11: the scale is the override when set, else the dots per inch over 96" {
    try expectEqual(@as(f32, 1.5), scaleOf(144, null));
    try expectEqual(@as(f32, 1), scaleOf(default_dpi, null));
    try expectEqual(@as(f32, 2), scaleOf(144, 2));
    try expectEqual(@as(f32, 1.5), scaleOf(144, 0));
}

test "x11: keysyms as code points - Latin-1's own, Unicode's offset ones, none for the others" {
    try expectEqual(@as(u21, 'v'), codePointOfKeysym(0x76));
    try expectEqual(@as(u21, 0xe9), codePointOfKeysym(0xe9));
    try expectEqual(@as(u21, 0x20ac), codePointOfKeysym(0x0100_20ac));
    try expectEqual(@as(u21, 0), codePointOfKeysym(XK_Return));
    try expectEqual(@as(u21, 0), codePointOfKeysym(0x1f));
    try expectEqual(@as(u21, 'a'), labelOfKeysym('A'));
    try expectEqual(@as(u21, 'z'), labelOfKeysym('z'));
    try expectEqual(@as(u21, 0), labelOfKeysym(XK_Escape));
}

test "x11: Latin-1 becomes UTF-8, whole characters only when the room runs out" {
    var out: [8]u8 = undefined;
    try expectEqualStrings("caf\u{e9}", latin1ToUtf8("caf\xe9", &out));
    var small: [4]u8 = undefined;
    // "abc" fits, and the two bytes of the e with an accent do not.
    try expectEqualStrings("abc", latin1ToUtf8("abc\xe9", &small));
    try expect(latin1ToUtf8("", &out).len == 0);
}
