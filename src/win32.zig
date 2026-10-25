//! THE WINDOWS LAYER - one window, its messages, a clock, and the Vulkan loader, declared by hand.
//! lint:off screaming-const: Windows' own names (WM_SIZE, CW_USEDEFAULT), exactly as Microsoft documents them;
//! win32-abi-check finds each one's twin in the headers by that same name.
//!
//! Zig's standard library declares almost nothing of user32 and kernel32 (no windowing at all), and loads no dynamic
//! libraries on Windows (`std.DynLib` is a compile error there). So the few operating-system functions zimr needs are
//! declared here with Windows' own names and types, exactly as Microsoft documents them, and linked through the
//! import libraries Zig ships for `x86_64-windows-gnu` - no Windows SDK at build time. `zig build win32-abi-check`
//! compares every structure, constant and function declared here with the MinGW headers, at compile time.
//!
//! ---- THE WINDOW ----
//!
//! `Window.open` registers a window class, creates one top-level window sized in LOGICAL pixels times the monitor's
//! scale, and shows it. Windows delivers messages by calling `windowProcedure`; the procedure finds its `Window`
//! through the window's user-data slot, which it fills from the creation parameters on the very first message
//! (`WM_NCCREATE`) - so no message is lost before `CreateWindowExW` returns, and no global is needed. A `Window`
//! must therefore not move after `open`.
//!
//! The program drains the message queue once per frame with `pump` (single-threaded: one thread pumps, renders and
//! presents). The window records what the frame loop must react to:
//!
//!     close_requested   the user closed the window
//!     minimized         the client area is zero-sized: render nothing until it returns
//!     size_changed      the client size changed (a resize, a restore, a monitor scale change): rebuild the swapchain
//!
//! ---- INPUT ----
//!
//! Input messages - keys, typed characters, the mouse, the wheel, losing focus - go to the program's input handler
//! (`Window.input_handler`) as they arrive, with the window's scale; `native_input.zig` turns them into the engine's
//! input calls. The window procedure does only Windows' own part of each first: a button press captures the mouse,
//! so a drag that leaves the window still reports, and the last release lets it go; a key message without a
//! scancode gets the one its virtual-key code maps to; and the menu key - Alt alone, F10, or Alt with a character - is
//! refused, since the window has no menu: Windows' menu mode would stall the frame loop until the next key, and a
//! character with no menu item beeps. Alt+Space, the window's own menu, still opens.
//!
//! ---- DOTS PER INCH ----
//!
//! The process declares itself per-monitor DPI aware (version 2), so Windows does not stretch its frames: the client
//! size is in physical pixels, and `scale` (dpi / 96) converts to the logical pixels the engine works in - the
//! browser's CSS pixels. When the window moves to a monitor with another scale, Windows sends `WM_DPICHANGED` with
//! the rectangle the window should take there; applying it keeps the window the same logical size.
//!
//! ---- VULKAN ----
//!
//! `openVulkanLibrary` loads `vulkan-1.dll` (installed with every GPU driver) and returns `vkGetInstanceProcAddr` as
//! an untyped function pointer. That is all this file knows about Vulkan: the Vulkan host casts it and fetches
//! everything else through it. A surface is created by the host from `module` and `handle`.

const std = @import("std");

const utf16LeToUtf8 = std.unicode.utf16LeToUtf8;
const utf8ToUtf16Le = std.unicode.utf8ToUtf16Le;
const utf8ToUtf16LeStringLiteral = std.unicode.utf8ToUtf16LeStringLiteral;
const zeroes = std.mem.zeroes;

// ---- Types ----

pub const BOOL = i32;
pub const WORD = u16;
pub const UINT = u32;
pub const DWORD = u32;
pub const LONG = i32;
pub const ATOM = u16;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const HRESULT = i32;
pub const LRESULT = isize;
pub const LONG_PTR = isize;

// Handles are opaque values the system hands out; they are never dereferenced (and are not always aligned pointers),
// so they are pointers to opaque types, whose alignment is 1.
pub const HWND = *opaque {};
pub const HINSTANCE = *opaque {};
pub const HMODULE = HINSTANCE;
pub const HICON = *opaque {};
pub const HCURSOR = *opaque {};
pub const HBRUSH = *opaque {};
pub const HMENU = *opaque {};
pub const DPI_AWARENESS_CONTEXT = *opaque {};

pub const WNDPROC = *const fn (
    window: HWND,
    message: UINT,
    w_param: WPARAM,
    l_param: LPARAM,
) callconv(.winapi) LRESULT;

pub const WNDCLASSEXW = extern struct {
    cbSize: UINT,
    style: UINT,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32,
    cbWndExtra: i32,
    hInstance: HINSTANCE,
    hIcon: ?HICON,
    hCursor: ?HCURSOR,
    hbrBackground: ?HBRUSH,
    lpszMenuName: ?[*:0]const u16,
    lpszClassName: [*:0]const u16,
    hIconSm: ?HICON,
};

pub const POINT = extern struct {
    x: LONG,
    y: LONG,
};

pub const MSG = extern struct {
    hwnd: ?HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
};

pub const RECT = extern struct {
    left: LONG,
    top: LONG,
    right: LONG,
    bottom: LONG,
};

pub const TRACKMOUSEEVENT = extern struct {
    cbSize: DWORD,
    dwFlags: DWORD,
    hwndTrack: ?HWND,
    dwHoverTime: DWORD,
};

pub const WINDOWPLACEMENT = extern struct {
    length: UINT,
    flags: UINT,
    showCmd: UINT,
    ptMinPosition: POINT,
    ptMaxPosition: POINT,
    rcNormalPosition: RECT,
};

pub const MONITORINFO = extern struct {
    cbSize: DWORD,
    rcMonitor: RECT,
    rcWork: RECT,
    dwFlags: DWORD,
};

pub const RAWINPUTDEVICE = extern struct {
    usUsagePage: u16,
    usUsage: u16,
    dwFlags: DWORD,
    hwndTarget: ?HWND,
};

pub const RAWINPUTHEADER = extern struct {
    dwType: DWORD,
    dwSize: DWORD,
    hDevice: ?*anyopaque,
    wParam: WPARAM,
};

/// A mouse's raw report. `ulButtons` holds the button flags and data as one word.
pub const RAWMOUSE = extern struct {
    usFlags: u16,
    ulButtons: u32,
    ulRawButtons: u32,
    lLastX: LONG,
    lLastY: LONG,
    ulExtraInformation: u32,
};

/// A raw input report as `GetRawInputData` writes it, for a mouse: the only device the window registers.
pub const RAWINPUT = extern struct {
    header: RAWINPUTHEADER,
    mouse: RAWMOUSE,
};

pub const CREATESTRUCTW = extern struct {
    lpCreateParams: ?*anyopaque,
    hInstance: ?HINSTANCE,
    hMenu: ?HMENU,
    hwndParent: ?HWND,
    cy: i32,
    cx: i32,
    y: i32,
    x: i32,
    style: LONG,
    lpszName: ?[*:0]const u16,
    lpszClass: ?[*:0]const u16,
    dwExStyle: DWORD,
};

// ---- Constants ----

pub const WM_DESTROY: UINT = 0x0002;
pub const WM_SIZE: UINT = 0x0005;
pub const WM_MOVE: UINT = 0x0003;
pub const WM_SETCURSOR: UINT = 0x0020;
pub const WM_INPUT: UINT = 0x00FF;
/// `WM_SETCURSOR`'s hit-test code for the client area, in its parameter's low word.
pub const HTCLIENT: usize = 1;
pub const WM_SETFOCUS: UINT = 0x0007;
pub const WM_KILLFOCUS: UINT = 0x0008;
pub const WM_CLOSE: UINT = 0x0010;
pub const WM_QUIT: UINT = 0x0012;
pub const WM_NCCREATE: UINT = 0x0081;
pub const WM_KEYDOWN: UINT = 0x0100;
pub const WM_KEYUP: UINT = 0x0101;
pub const WM_CHAR: UINT = 0x0102;
pub const WM_SYSKEYDOWN: UINT = 0x0104;
pub const WM_SYSKEYUP: UINT = 0x0105;
pub const WM_SYSCOMMAND: UINT = 0x0112;
pub const WM_MOUSEMOVE: UINT = 0x0200;
pub const WM_MOUSELEAVE: UINT = 0x02A3;
/// The first message number Windows leaves to programs for messages of their own.
pub const WM_APP: UINT = 0x8000;
/// zimr's own message, forwarded as input: the pointer entered the client area. Windows has no message for it - the
/// first WM_MOUSEMOVE after a WM_MOUSELEAVE is the moment - so the window procedure makes one there.
pub const message_pointer_entered: UINT = WM_APP + 1;
/// `TrackMouseEvent`'s request for one WM_MOUSELEAVE, the next time the pointer leaves the client area.
pub const TME_LEAVE: DWORD = 0x00000002;
/// zimr's own message, forwarded as input: the mouse's motion as raw input reported it while the pointer is locked,
/// in physical pixels - `w_param` the horizontal, `l_param` the vertical, both signed.
pub const message_pointer_motion: UINT = WM_APP + 2;
/// zimr's own message, forwarded as input: the pointer lock began (`w_param` 1) or ended (0).
pub const message_pointer_lock_changed: UINT = WM_APP + 3;
/// zimr's own message, forwarded as input: fullscreen began (`w_param` 1) or ended (0).
pub const message_fullscreen_changed: UINT = WM_APP + 4;
/// zimr's own message, forwarded as input: a text pasted, carried in the message's `text`.
pub const message_paste: UINT = WM_APP + 5;
/// The virtual keys of the paste commands, Ctrl+V and Shift+Insert, and of the modifiers they are read with.
pub const VK_SHIFT: i32 = 0x10;
pub const VK_CONTROL: i32 = 0x11;
pub const VK_MENU: i32 = 0x12;
pub const VK_INSERT: WPARAM = 0x2D;
/// Raw input's names for a mouse: the generic desktop usage page, and the mouse in it.
pub const HID_USAGE_PAGE_GENERIC: u16 = 0x01;
pub const HID_USAGE_GENERIC_MOUSE: u16 = 0x02;
/// `RegisterRawInputDevices`' flag for taking a registration back.
pub const RIDEV_REMOVE: DWORD = 0x00000001;
/// `GetRawInputData`'s request for the report itself, rather than its header alone.
pub const RID_INPUT: UINT = 0x10000003;
/// A raw input report's kind, for a mouse.
pub const RIM_TYPEMOUSE: DWORD = 0;
/// A mouse report's flag for an absolute position - a tablet or a remote desktop - in place of a motion.
pub const MOUSE_MOVE_ABSOLUTE: u16 = 0x01;
pub const WM_LBUTTONDOWN: UINT = 0x0201;
pub const WM_LBUTTONUP: UINT = 0x0202;
pub const WM_RBUTTONDOWN: UINT = 0x0204;
pub const WM_RBUTTONUP: UINT = 0x0205;
pub const WM_MBUTTONDOWN: UINT = 0x0207;
pub const WM_MBUTTONUP: UINT = 0x0208;
pub const WM_MOUSEWHEEL: UINT = 0x020A;
pub const WM_XBUTTONDOWN: UINT = 0x020B;
pub const WM_XBUTTONUP: UINT = 0x020C;
pub const WM_MOUSEHWHEEL: UINT = 0x020E;
pub const WM_DPICHANGED: UINT = 0x02E0;

pub const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF0000;
pub const CS_VREDRAW: UINT = 0x0001;
pub const CS_HREDRAW: UINT = 0x0002;
pub const CS_OWNDC: UINT = 0x0020;
pub const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));
pub const SW_SHOW: i32 = 5;
/// `ShowWindow`'s commands for the three window states.
pub const SW_MAXIMIZE: i32 = 3;
pub const SW_MINIMIZE: i32 = 6;
pub const SW_RESTORE: i32 = 9;
/// Sent when Windows is about to size the window, asking for the sizes it may take (`MINMAXINFO`).
pub const WM_GETMINMAXINFO: UINT = 0x0024;
pub const PM_REMOVE: UINT = 0x0001;
pub const GWLP_USERDATA: i32 = -21;
pub const SIZE_MINIMIZED: WPARAM = 1;
pub const SWP_NOZORDER: UINT = 0x0004;
pub const SWP_NOACTIVATE: UINT = 0x0010;
pub const SWP_NOSIZE: UINT = 0x0001;
/// Sent to every top-level window when the displays change: a monitor plugged in or out, a resolution changed.
pub const WM_DISPLAYCHANGE: UINT = 0x007E;
/// Sent to every top-level window when a system setting changes - a monitor's scale among them.
pub const WM_SETTINGCHANGE: UINT = 0x001A;
pub const SWP_NOMOVE: UINT = 0x0002;
pub const SWP_FRAMECHANGED: UINT = 0x0020;
pub const SWP_NOOWNERZORDER: UINT = 0x0200;
pub const GWL_STYLE: i32 = -16;
/// `MonitorFromWindow`'s choice when the window spans none: the nearest monitor.
pub const MONITOR_DEFAULTTONEAREST: DWORD = 2;
/// `SetThreadExecutionState`'s flags: the request lasts until changed (`ES_CONTINUOUS`), and keeps the display on
/// and the system awake.
pub const ES_SYSTEM_REQUIRED: u32 = 0x00000001;
pub const ES_DISPLAY_REQUIRED: u32 = 0x00000002;
pub const ES_CONTINUOUS: u32 = 0x80000000;
pub const SW_SHOWNORMAL: i32 = 1;
/// Files: the access asked for, the sharing allowed, how to open, and the plain attribute.
pub const GENERIC_READ: DWORD = 0x80000000;
pub const GENERIC_WRITE: DWORD = 0x40000000;
pub const FILE_SHARE_READ: DWORD = 0x00000001;
pub const CREATE_ALWAYS: DWORD = 2;
pub const OPEN_EXISTING: DWORD = 3;
pub const FILE_ATTRIBUTE_NORMAL: DWORD = 0x00000080;
/// `MoveFileExW`: replace a file already there, and return only once the move is on the disk.
pub const MOVEFILE_REPLACE_EXISTING: DWORD = 0x00000001;
pub const MOVEFILE_WRITE_THROUGH: DWORD = 0x00000008;
/// The clipboard's format for UTF-16 text, and the movable global memory it is handed in.
pub const CF_UNICODETEXT: UINT = 13;
pub const GMEM_MOVEABLE: UINT = 0x0002;
/// A kernel object handle: a file, a process.
pub const HANDLE = *anyopaque;
pub const USER_DEFAULT_SCREEN_DPI: UINT = 96;
pub const SC_KEYMENU: WPARAM = 0xF100;
pub const MK_LBUTTON: WPARAM = 0x0001;
pub const MK_RBUTTON: WPARAM = 0x0002;
pub const MK_MBUTTON: WPARAM = 0x0010;
pub const MK_XBUTTON1: WPARAM = 0x0020;
pub const MK_XBUTTON2: WPARAM = 0x0040;
pub const XBUTTON1: u32 = 0x0001;
pub const XBUTTON2: u32 = 0x0002;
pub const VK_SNAPSHOT: WPARAM = 0x2C;
pub const MAPVK_VK_TO_VSC: UINT = 0;
pub const MAPVK_VK_TO_CHAR: UINT = 2;
/// The standard arrow cursor's resource number (a resource number travels in a pointer's place).
pub const IDC_ARROW: usize = 32512;
pub const IDC_IBEAM: usize = 32513;
pub const IDC_WAIT: usize = 32514;
pub const IDC_CROSS: usize = 32515;
pub const IDC_SIZENWSE: usize = 32642;
pub const IDC_SIZENESW: usize = 32643;
pub const IDC_SIZEWE: usize = 32644;
pub const IDC_SIZENS: usize = 32645;
pub const IDC_SIZEALL: usize = 32646;
pub const IDC_NO: usize = 32648;
pub const IDC_HAND: usize = 32649;
/// `DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2`: a pseudo-handle, the value -4.
pub const dpi_awareness_context_per_monitor_aware_v2: isize = -4;

// ---- Functions ----

pub extern "kernel32" fn GetModuleHandleW(lpModuleName: ?[*:0]const u16) callconv(.winapi) ?HMODULE;
pub extern "kernel32" fn LoadLibraryW(lpLibFileName: [*:0]const u16) callconv(.winapi) ?HMODULE;
pub extern "kernel32" fn GetProcAddress(
    hModule: HMODULE,
    lpProcName: [*:0]const u8,
) callconv(.winapi) ?*const anyopaque;
pub extern "kernel32" fn FreeLibrary(hLibModule: HMODULE) callconv(.winapi) BOOL;
pub extern "kernel32" fn QueryPerformanceCounter(lpPerformanceCount: *i64) callconv(.winapi) BOOL;
pub extern "kernel32" fn QueryPerformanceFrequency(lpFrequency: *i64) callconv(.winapi) BOOL;
pub extern "kernel32" fn Sleep(dwMilliseconds: DWORD) callconv(.winapi) void;
pub extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
pub extern "kernel32" fn GetEnvironmentVariableW(
    lpName: [*:0]const u16,
    lpBuffer: ?[*]u16,
    nSize: DWORD,
) callconv(.winapi) DWORD;

pub extern "user32" fn RegisterClassExW(lpWndClass: *const WNDCLASSEXW) callconv(.winapi) ATOM;
pub extern "user32" fn UnregisterClassW(lpClassName: [*:0]const u16, hInstance: ?HINSTANCE) callconv(.winapi) BOOL;
/// What the system's Open and Save dialogs are given, and give back (`GetOpenFileNameW`, `GetSaveFileNameW`): the
/// owner window, the filter - pairs of a description and its patterns, each null-terminated, the list ending in an
/// empty string - and the buffer the chosen path is written into.
pub const OPENFILENAMEW = extern struct {
    lStructSize: DWORD,
    hwndOwner: ?HWND,
    hInstance: ?HINSTANCE,
    lpstrFilter: ?[*]const u16,
    lpstrCustomFilter: ?[*]u16,
    nMaxCustFilter: DWORD,
    nFilterIndex: DWORD,
    lpstrFile: ?[*]u16,
    nMaxFile: DWORD,
    lpstrFileTitle: ?[*]u16,
    nMaxFileTitle: DWORD,
    lpstrInitialDir: ?[*:0]const u16,
    lpstrTitle: ?[*:0]const u16,
    Flags: DWORD,
    nFileOffset: WORD,
    nFileExtension: WORD,
    lpstrDefExt: ?[*:0]const u16,
    lCustData: LPARAM,
    lpfnHook: ?*anyopaque,
    lpTemplateName: ?[*:0]const u16,
    pvReserved: ?*anyopaque,
    dwReserved: DWORD,
    FlagsEx: DWORD,
};

/// A Save dialog asks before replacing an existing file.
pub const OFN_OVERWRITEPROMPT: DWORD = 0x0000_0002;
/// The dialogs leave the process's current directory as it was.
pub const OFN_NOCHANGEDIR: DWORD = 0x0000_0008;
pub const OFN_PATHMUSTEXIST: DWORD = 0x0000_0800;
pub const OFN_FILEMUSTEXIST: DWORD = 0x0000_1000;
pub const OFN_EXPLORER: DWORD = 0x0008_0000;

pub extern "comdlg32" fn GetOpenFileNameW(form: *OPENFILENAMEW) callconv(.winapi) BOOL;
pub extern "comdlg32" fn GetSaveFileNameW(form: *OPENFILENAMEW) callconv(.winapi) BOOL;

/// A batch of files dropped on a window: its paths read with `DragQueryFileW`, then freed with `DragFinish`.
pub const HDROP = *opaque {};
pub const WM_DROPFILES: UINT = 0x0233;
pub extern "shell32" fn DragAcceptFiles(hwnd: HWND, accept: BOOL) callconv(.winapi) void;
pub extern "shell32" fn DragQueryFileW(
    drop: HDROP,
    index: UINT,
    file: ?[*]u16,
    size: UINT,
) callconv(.winapi) UINT;
pub extern "shell32" fn DragFinish(drop: HDROP) callconv(.winapi) void;

/// A moment as the system's clock counts it: 100-nanosecond ticks since 1601-01-01 UTC, in two halves.
pub const FILETIME = extern struct {
    dwLowDateTime: DWORD,
    dwHighDateTime: DWORD,
};
/// The wall clock, to the system's finest precision (Windows 8 and later).
pub extern "kernel32" fn GetSystemTimePreciseAsFileTime(time: *FILETIME) callconv(.winapi) void;

pub extern "user32" fn CreateWindowExW(
    dwExStyle: DWORD,
    lpClassName: [*:0]const u16,
    lpWindowName: [*:0]const u16,
    dwStyle: DWORD,
    X: i32,
    Y: i32,
    nWidth: i32,
    nHeight: i32,
    hWndParent: ?HWND,
    hMenu: ?HMENU,
    hInstance: ?HINSTANCE,
    lpParam: ?*anyopaque,
) callconv(.winapi) ?HWND;
pub extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn MapVirtualKeyW(uCode: UINT, uMapType: UINT) callconv(.winapi) UINT;
/// Asks Windows for a WM_MOUSELEAVE the next time the pointer leaves `hwndTrack`'s client area - once: each entry asks
/// again.
pub extern "user32" fn TrackMouseEvent(event: *TRACKMOUSEEVENT) callconv(.winapi) BOOL;
/// The extra information of the message being handled: for a mouse message Windows made from a pen or a touch, a
/// signature saying which (`native_input.pointerKindOfExtraInfo`). Valid only while that message is handled.
pub extern "user32" fn GetMessageExtraInfo() callconv(.winapi) LPARAM;
pub extern "user32" fn ClientToScreen(hWnd: HWND, lpPoint: *POINT) callconv(.winapi) BOOL;
/// Confines the cursor to a rectangle of the screen; null frees it.
pub extern "user32" fn ClipCursor(lpRect: ?*const RECT) callconv(.winapi) BOOL;
pub extern "user32" fn GetCursorPos(lpPoint: *POINT) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowTextW(hWnd: HWND, lpString: [*:0]const u16) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowPlacement(hWnd: HWND, lpwndpl: *WINDOWPLACEMENT) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowPlacement(hWnd: HWND, lpwndpl: *const WINDOWPLACEMENT) callconv(.winapi) BOOL;
pub extern "user32" fn MonitorFromWindow(hwnd: HWND, dwFlags: DWORD) callconv(.winapi) ?*anyopaque;
pub extern "user32" fn GetMonitorInfoW(hMonitor: *anyopaque, lpmi: *MONITORINFO) callconv(.winapi) BOOL;

/// A monitor's information with its device's name: `GetMonitorInfoW` fills this larger form when `cbSize` says so
/// (pass it cast to `*MONITORINFO`, whose fields it begins with).
pub const MONITORINFOEXW = extern struct {
    cbSize: DWORD,
    rcMonitor: RECT,
    rcWork: RECT,
    dwFlags: DWORD,
    szDevice: [32]u16,
};
/// `MONITORINFOEXW.dwFlags`: the primary monitor.
pub const MONITORINFOF_PRIMARY: DWORD = 1;

/// Called by `EnumDisplayMonitors` once per monitor; returning nonzero goes on to the next.
pub const MONITORENUMPROC = *const fn (
    monitor: ?*anyopaque,
    device_context: ?*anyopaque,
    rect: ?*RECT,
    data: LPARAM,
) callconv(.winapi) BOOL;
pub extern "user32" fn EnumDisplayMonitors(
    hdc: ?*anyopaque,
    lprcClip: ?*const RECT,
    lpfnEnum: MONITORENUMPROC,
    dwData: LPARAM,
) callconv(.winapi) BOOL;

/// A display device's mode (`EnumDisplaySettingsW`). The C struct has a union of 16 bytes - a printer's orientation
/// and paper, or a display's position and orientation - kept here as bytes, since only the display's own fields after
/// it are read. Its layout is checked below: a field out of place would read garbage on a real machine, where nothing
/// here can see it.
pub const DEVMODEW = extern struct {
    dmDeviceName: [32]u16,
    dmSpecVersion: u16,
    dmDriverVersion: u16,
    dmSize: u16,
    dmDriverExtra: u16,
    dmFields: DWORD,
    dmPrinterOrDisplay: [16]u8,
    dmColor: i16,
    dmDuplex: i16,
    dmYResolution: i16,
    dmTTOption: i16,
    dmCollate: i16,
    dmFormName: [32]u16,
    dmLogPixels: u16,
    dmBitsPerPel: DWORD,
    dmPelsWidth: DWORD,
    dmPelsHeight: DWORD,
    dmDisplayFlags: DWORD,
    dmDisplayFrequency: DWORD,
    dmICMMethod: DWORD,
    dmICMIntent: DWORD,
    dmMediaType: DWORD,
    dmDitherType: DWORD,
    dmReserved1: DWORD,
    dmReserved2: DWORD,
    dmPanningWidth: DWORD,
    dmPanningHeight: DWORD,

    comptime {
        const is_laid_out_as_windows: bool = @sizeOf(DEVMODEW) == 220 and
            @offsetOf(DEVMODEW, "dmSize") == 68 and
            @offsetOf(DEVMODEW, "dmPrinterOrDisplay") == 76 and
            @offsetOf(DEVMODEW, "dmBitsPerPel") == 168 and
            @offsetOf(DEVMODEW, "dmDisplayFrequency") == 184;
        if (!is_laid_out_as_windows) {
            @compileError("DEVMODEW is not laid out as Windows lays out DEVMODEW");
        }
    }
};
/// `EnumDisplaySettingsW`'s mode number for the mode the display is in now.
pub const ENUM_CURRENT_SETTINGS: DWORD = 0xffff_ffff;
pub extern "user32" fn EnumDisplaySettingsW(
    lpszDeviceName: [*:0]const u16,
    iModeNum: DWORD,
    lpDevMode: *DEVMODEW,
) callconv(.winapi) BOOL;

// ---- The display configuration ----
//
// Windows describes each active display as a path, from a source - what the desktop draws, known by its GDI device
// name, `\\.\DISPLAY1` - to a target, the monitor: its own name from its EDID, and its exact refresh rate as a ratio
// (59.94 Hz is 60000/1001, where a display mode's `dmDisplayFrequency` rounds it down to 59). Each struct below is
// checked against the layout Windows uses: a field out of place would read garbage on a real machine.

/// A locally unique identifier: here, a display adapter's.
pub const LUID = extern struct {
    LowPart: DWORD,
    HighPart: LONG,
};

/// A ratio, as the display configuration gives rates.
pub const DISPLAYCONFIG_RATIONAL = extern struct {
    Numerator: u32,
    Denominator: u32,
};

pub const DISPLAYCONFIG_PATH_SOURCE_INFO = extern struct {
    adapterId: LUID,
    id: u32,
    modeInfoIdx: u32,
    statusFlags: u32,
};

pub const DISPLAYCONFIG_PATH_TARGET_INFO = extern struct {
    adapterId: LUID,
    id: u32,
    modeInfoIdx: u32,
    outputTechnology: u32,
    rotation: u32,
    scaling: u32,
    refreshRate: DISPLAYCONFIG_RATIONAL,
    scanLineOrdering: u32,
    targetAvailable: BOOL,
    statusFlags: u32,
};

/// One active display: its source and its target.
pub const DISPLAYCONFIG_PATH_INFO = extern struct {
    sourceInfo: DISPLAYCONFIG_PATH_SOURCE_INFO,
    targetInfo: DISPLAYCONFIG_PATH_TARGET_INFO,
    flags: u32,

    comptime {
        const is_laid_out_as_windows: bool = @sizeOf(DISPLAYCONFIG_PATH_INFO) == 72 and
            @offsetOf(DISPLAYCONFIG_PATH_INFO, "targetInfo") == 20 and
            @offsetOf(DISPLAYCONFIG_PATH_TARGET_INFO, "refreshRate") == 28 and
            @sizeOf(DISPLAYCONFIG_PATH_TARGET_INFO) == 48;
        if (!is_laid_out_as_windows) {
            @compileError("DISPLAYCONFIG_PATH_INFO is not laid out as Windows lays it out");
        }
    }
};

/// One mode the configuration uses: a union in C, whose target form holds 64-bit fields - hence the alignment. Only
/// its room is needed here: `QueryDisplayConfig` fills it, and nothing reads it.
pub const DISPLAYCONFIG_MODE_INFO = extern struct {
    infoType: u32,
    id: u32,
    adapterId: LUID,
    mode: [6]u64,

    comptime {
        if (@sizeOf(DISPLAYCONFIG_MODE_INFO) != 64) {
            @compileError("DISPLAYCONFIG_MODE_INFO is not laid out as Windows lays it out");
        }
    }
};

/// The header of a request for one detail of a display (`DisplayConfigGetDeviceInfo`): which detail, the size of the
/// struct holding it, and which source or target.
pub const DISPLAYCONFIG_DEVICE_INFO_HEADER = extern struct {
    type: u32,
    size: u32,
    adapterId: LUID,
    id: u32,
};
pub const DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME: u32 = 1;
pub const DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME: u32 = 2;

/// A source's GDI device name, `\\.\DISPLAY1`: the name `MONITORINFOEXW.szDevice` knows the monitor by.
pub const DISPLAYCONFIG_SOURCE_DEVICE_NAME = extern struct {
    header: DISPLAYCONFIG_DEVICE_INFO_HEADER,
    viewGdiDeviceName: [32]u16,

    comptime {
        if (@sizeOf(DISPLAYCONFIG_SOURCE_DEVICE_NAME) != 84) {
            @compileError("DISPLAYCONFIG_SOURCE_DEVICE_NAME is not laid out as Windows lays it out");
        }
    }
};

/// A target's names: the monitor's own, from its EDID ("DELL U2412M"), empty for some built-in panels.
pub const DISPLAYCONFIG_TARGET_DEVICE_NAME = extern struct {
    header: DISPLAYCONFIG_DEVICE_INFO_HEADER,
    flags: u32,
    outputTechnology: u32,
    edidManufactureId: u16,
    edidProductCodeId: u16,
    connectorInstance: u32,
    monitorFriendlyDeviceName: [64]u16,
    monitorDevicePath: [128]u16,

    comptime {
        const is_laid_out_as_windows: bool = @sizeOf(DISPLAYCONFIG_TARGET_DEVICE_NAME) == 420 and
            @offsetOf(DISPLAYCONFIG_TARGET_DEVICE_NAME, "monitorFriendlyDeviceName") == 36;
        if (!is_laid_out_as_windows) {
            @compileError("DISPLAYCONFIG_TARGET_DEVICE_NAME is not laid out as Windows lays it out");
        }
    }
};

/// `QueryDisplayConfig`'s flag for the displays in use.
pub const QDC_ONLY_ACTIVE_PATHS: u32 = 0x0000_0002;
pub extern "user32" fn GetDisplayConfigBufferSizes(
    flags: u32,
    numPathArrayElements: *u32,
    numModeInfoArrayElements: *u32,
) callconv(.winapi) LONG;
pub extern "user32" fn QueryDisplayConfig(
    flags: u32,
    numPathArrayElements: *u32,
    pathArray: [*]DISPLAYCONFIG_PATH_INFO,
    numModeInfoArrayElements: *u32,
    modeInfoArray: [*]DISPLAYCONFIG_MODE_INFO,
    currentTopologyId: ?*u32,
) callconv(.winapi) LONG;
pub extern "user32" fn DisplayConfigGetDeviceInfo(
    requestPacket: *DISPLAYCONFIG_DEVICE_INFO_HEADER,
) callconv(.winapi) LONG;

// ---- XInput ----
//
// XInput reads an Xbox-style gamepad in each of four slots. Its DLL is loaded by name at run time (the platform's
// `gamepad`), so these are the types its two functions take, and their pointer types.

/// A gamepad's state as XInput reports it: the buttons as bits (`XINPUT_GAMEPAD_*`), the triggers from 0 to 255, the
/// sticks from -32768 to 32767 - right and UP positive.
pub const XINPUT_GAMEPAD = extern struct {
    wButtons: u16,
    bLeftTrigger: u8,
    bRightTrigger: u8,
    sThumbLX: i16,
    sThumbLY: i16,
    sThumbRX: i16,
    sThumbRY: i16,
};

/// A gamepad's state and a packet number, which changes whenever the state does.
pub const XINPUT_STATE = extern struct {
    dwPacketNumber: DWORD,
    Gamepad: XINPUT_GAMEPAD,

    comptime {
        if (@sizeOf(XINPUT_STATE) != 16 or @offsetOf(XINPUT_STATE, "Gamepad") != 4) {
            @compileError("XINPUT_STATE is not laid out as XInput lays it out");
        }
    }
};

/// The two motors' speeds, 0 to 65535: the left one heavy and slow, the right one light and fast.
pub const XINPUT_VIBRATION = extern struct {
    wLeftMotorSpeed: u16,
    wRightMotorSpeed: u16,
};

/// XInput's button bits.
pub const XINPUT_GAMEPAD_DPAD_UP: u16 = 0x0001;
pub const XINPUT_GAMEPAD_DPAD_DOWN: u16 = 0x0002;
pub const XINPUT_GAMEPAD_DPAD_LEFT: u16 = 0x0004;
pub const XINPUT_GAMEPAD_DPAD_RIGHT: u16 = 0x0008;
pub const XINPUT_GAMEPAD_START: u16 = 0x0010;
pub const XINPUT_GAMEPAD_BACK: u16 = 0x0020;
pub const XINPUT_GAMEPAD_LEFT_THUMB: u16 = 0x0040;
pub const XINPUT_GAMEPAD_RIGHT_THUMB: u16 = 0x0080;
pub const XINPUT_GAMEPAD_LEFT_SHOULDER: u16 = 0x0100;
pub const XINPUT_GAMEPAD_RIGHT_SHOULDER: u16 = 0x0200;
pub const XINPUT_GAMEPAD_A: u16 = 0x1000;
pub const XINPUT_GAMEPAD_B: u16 = 0x2000;
pub const XINPUT_GAMEPAD_X: u16 = 0x4000;
pub const XINPUT_GAMEPAD_Y: u16 = 0x8000;

/// `XInputGetState` and `XInputSetState`, as found in the DLL: 0 (`ERROR_SUCCESS`) when the slot has a gamepad.
pub const XInputGetStateFn = *const fn (dwUserIndex: DWORD, pState: *XINPUT_STATE) callconv(.winapi) DWORD;
pub const XInputSetStateFn = *const fn (dwUserIndex: DWORD, pVibration: *XINPUT_VIBRATION) callconv(.winapi) DWORD;

/// `GetDpiForMonitor`'s kind of DPI: the effective one, a monitor's scale times 96, as the person set it.
pub const MDT_EFFECTIVE_DPI: c_int = 0;
pub extern "shcore" fn GetDpiForMonitor(
    hmonitor: *anyopaque,
    dpiType: c_int,
    dpiX: *UINT,
    dpiY: *UINT,
) callconv(.winapi) HRESULT;
pub extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
/// A handle to the process `dwProcessId`, with the rights `dwDesiredAccess` asks for; null when it cannot be had (it
/// has ended, or the rights are refused). Closed with `CloseHandle`.
pub extern "kernel32" fn OpenProcess(
    dwDesiredAccess: DWORD,
    bInheritHandle: BOOL,
    dwProcessId: DWORD,
) callconv(.winapi) ?HANDLE;
/// Ends the process `hProcess` with exit code `uExitCode`, at once.
pub extern "kernel32" fn TerminateProcess(hProcess: HANDLE, uExitCode: UINT) callconv(.winapi) BOOL;
/// The id of the process `Process` is a handle to.
pub extern "kernel32" fn GetProcessId(Process: HANDLE) callconv(.winapi) DWORD;
/// `OpenProcess`'s right to end the process.
pub const PROCESS_TERMINATE: DWORD = 0x0001;
/// Opens or creates a file; answers INVALID_HANDLE_VALUE (all bits set) on failure.
pub extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: DWORD,
    dwShareMode: DWORD,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: DWORD,
    dwFlagsAndAttributes: DWORD,
    hTemplateFile: ?HANDLE,
) callconv(.winapi) HANDLE;
pub extern "kernel32" fn ReadFile(
    hFile: HANDLE,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: DWORD,
    lpNumberOfBytesRead: *DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn WriteFile(
    hFile: HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: DWORD,
    lpNumberOfBytesWritten: *DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetFileSizeEx(hFile: HANDLE, lpFileSize: *i64) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateDirectoryW(
    lpPathName: [*:0]const u16,
    lpSecurityAttributes: ?*anyopaque,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn DeleteFileW(lpFileName: [*:0]const u16) callconv(.winapi) BOOL;
pub extern "kernel32" fn MoveFileExW(
    lpExistingFileName: [*:0]const u16,
    lpNewFileName: [*:0]const u16,
    dwFlags: DWORD,
) callconv(.winapi) BOOL;
/// The running program's own path; the length written, without the terminating zero.
pub extern "kernel32" fn GetModuleFileNameW(
    hModule: ?HINSTANCE,
    lpFilename: [*]u16,
    nSize: DWORD,
) callconv(.winapi) DWORD;
pub extern "kernel32" fn GlobalAlloc(uFlags: UINT, dwBytes: usize) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn GlobalLock(hMem: *anyopaque) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn GlobalUnlock(hMem: *anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn GlobalFree(hMem: *anyopaque) callconv(.winapi) ?*anyopaque;
/// The clipboard: opened for one window at a time, emptied to take ownership, given data, closed.
pub extern "user32" fn OpenClipboard(hWndNewOwner: ?HWND) callconv(.winapi) BOOL;
pub extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn SetClipboardData(uFormat: UINT, hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
pub extern "user32" fn GetClipboardData(uFormat: UINT) callconv(.winapi) ?*anyopaque;
/// Whether a key is held: the answer's high bit, a negative number.
pub extern "user32" fn GetKeyState(nVirtKey: i32) callconv(.winapi) i16;
/// Tells Windows what the program needs kept on - the display, the system - until it says otherwise.
pub extern "kernel32" fn SetThreadExecutionState(esFlags: u32) callconv(.winapi) u32;
/// An input method's context for a window: the state of its compositions. The window has none while its input
/// method is off (`ImmAssociateContextEx` with no context): Windows then sends its keys straight on as `WM_CHAR`.
pub const HIMC = *opaque {};

/// Where an input method draws the text being composed: with `CFS_FORCE_POSITION`, at `ptCurrentPos` in client
/// pixels, whatever the method itself would choose.
pub const COMPOSITIONFORM = extern struct {
    dwStyle: DWORD,
    ptCurrentPos: POINT,
    rcArea: RECT,
};

/// Where an input method draws its list of candidates: with `CFS_EXCLUDE`, near `ptCurrentPos` and outside
/// `rcArea`, in client pixels.
pub const CANDIDATEFORM = extern struct {
    dwIndex: DWORD,
    dwStyle: DWORD,
    ptCurrentPos: POINT,
    rcArea: RECT,
};

pub const CFS_FORCE_POSITION: DWORD = 0x0020;
pub const CFS_EXCLUDE: DWORD = 0x0080;
/// `ImmAssociateContextEx`: the window gets back its default input method context.
pub const IACE_DEFAULT: DWORD = 0x0010;

pub extern "imm32" fn ImmGetContext(hwnd: HWND) callconv(.winapi) ?HIMC;
pub extern "imm32" fn ImmReleaseContext(hwnd: HWND, context: HIMC) callconv(.winapi) BOOL;
pub extern "imm32" fn ImmSetCompositionWindow(context: HIMC, form: *const COMPOSITIONFORM) callconv(.winapi) BOOL;
pub extern "imm32" fn ImmSetCandidateWindow(context: HIMC, form: *const CANDIDATEFORM) callconv(.winapi) BOOL;
pub extern "imm32" fn ImmAssociateContextEx(
    hwnd: HWND,
    context: ?HIMC,
    flags: DWORD,
) callconv(.winapi) BOOL;

/// Opens `lpFile` with its verb (`open`): a web address in the default browser.
pub extern "shell32" fn ShellExecuteW(
    hwnd: ?HWND,
    lpOperation: ?[*:0]const u16,
    lpFile: [*:0]const u16,
    lpParameters: ?[*:0]const u16,
    lpDirectory: ?[*:0]const u16,
    nShowCmd: i32,
) callconv(.winapi) ?*anyopaque;
pub extern "user32" fn SetCursorPos(X: i32, Y: i32) callconv(.winapi) BOOL;
/// Sets the cursor's shape; null hides it.
pub extern "user32" fn SetCursor(hCursor: ?HCURSOR) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn RegisterRawInputDevices(
    pRawInputDevices: [*]const RAWINPUTDEVICE,
    uiNumDevices: UINT,
    cbSize: UINT,
) callconv(.winapi) BOOL;
pub extern "user32" fn GetRawInputData(
    hRawInput: *anyopaque,
    uiCommand: UINT,
    pData: ?*anyopaque,
    pcbSize: *UINT,
    cbSizeHeader: UINT,
) callconv(.winapi) UINT;
pub extern "user32" fn SetCapture(hWnd: HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
pub extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: i32) callconv(.winapi) BOOL;
pub extern "user32" fn SetForegroundWindow(hWnd: HWND) callconv(.winapi) BOOL;
/// Whether the window is maximized.
pub extern "user32" fn IsZoomed(hWnd: HWND) callconv(.winapi) BOOL;
/// A key's name in the current keyboard layout: `lParam` holds its scancode in bits 16 to 23 and its extended flag in
/// bit 24, as a key message's does. Returns the name's length in UTF-16 units, 0 when there is none.
pub extern "user32" fn GetKeyNameTextW(
    lParam: LONG,
    lpString: [*]u16,
    cchSize: i32,
) callconv(.winapi) i32;

/// The sizes a window may take (`WM_GETMINMAXINFO`), its outer frame's: the smallest and largest a person can drag it
/// to are `ptMinTrackSize` and `ptMaxTrackSize`.
pub const MINMAXINFO = extern struct {
    ptReserved: POINT,
    ptMaxSize: POINT,
    ptMaxPosition: POINT,
    ptMinTrackSize: POINT,
    ptMaxTrackSize: POINT,
};
pub extern "user32" fn DefWindowProcW(
    hWnd: HWND,
    Msg: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
) callconv(.winapi) LRESULT;
pub extern "user32" fn PeekMessageW(
    lpMsg: *MSG,
    hWnd: ?HWND,
    wMsgFilterMin: UINT,
    wMsgFilterMax: UINT,
    wRemoveMsg: UINT,
) callconv(.winapi) BOOL;
pub extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.winapi) BOOL;
pub extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.winapi) LRESULT;
pub extern "user32" fn GetClientRect(hWnd: HWND, lpRect: *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn AdjustWindowRectExForDpi(
    lpRect: *RECT,
    dwStyle: DWORD,
    bMenu: BOOL,
    dwExStyle: DWORD,
    dpi: UINT,
) callconv(.winapi) BOOL;
pub extern "user32" fn GetDpiForWindow(hwnd: HWND) callconv(.winapi) UINT;
pub extern "user32" fn GetDpiForSystem() callconv(.winapi) UINT;
pub extern "user32" fn SetProcessDpiAwarenessContext(value: DPI_AWARENESS_CONTEXT) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowLongPtrW(
    hWnd: HWND,
    nIndex: i32,
    dwNewLong: LONG_PTR,
) callconv(.winapi) LONG_PTR;
pub extern "user32" fn GetWindowLongPtrW(hWnd: HWND, nIndex: i32) callconv(.winapi) LONG_PTR;
pub extern "user32" fn LoadCursorW(hInstance: ?HINSTANCE, lpCursorName: ?*const anyopaque) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn SetWindowPos(
    hWnd: HWND,
    hWndInsertAfter: ?HWND,
    X: i32,
    Y: i32,
    cx: i32,
    cy: i32,
    uFlags: UINT,
) callconv(.winapi) BOOL;

/// The low and high 16 bits of a message parameter (`LOWORD`, `HIWORD`).
/// Bits 0 to 15 of a message parameter (`LOWORD`).
pub fn lowWord(value: usize) u32 {
    return @intCast(value & 0xffff);
}

/// Bits 16 to 31 of a message parameter (`HIWORD`).
pub fn highWord(value: usize) u32 {
    return @intCast((value >> 16) & 0xffff);
}

/// Bits 0 to 15 as a signed number (`GET_X_LPARAM`): mouse coordinates are, and a captured mouse reports negative
/// ones left of or above the client area.
pub fn signedLowWord(value: usize) i16 {
    return @bitCast(@as(u16, @truncate(value)));
}

/// Bits 16 to 31 as a signed number (`GET_Y_LPARAM`, `GET_WHEEL_DELTA_WPARAM`): a mouse coordinate, or a wheel
/// distance - negative toward the user.
pub fn signedHighWord(value: usize) i16 {
    return @bitCast(@as(u16, @truncate(value >> 16)));
}

// ---- WASAPI ----
//
// Windows' audio output for applications (the Windows Audio Session API), reached through COM: an object is a pointer
// to a struct whose first field points to a table of functions - its vtable - in the order the interface declares
// them, each taking the object itself first. An interface extends IUnknown, so every table begins with
// `QueryInterface`, `AddRef` and `Release`. The device enumerator (`IMMDeviceEnumerator`) finds the default output
// device (`IMMDevice`); the device makes an audio client (`IAudioClient`), which opens a stream and gives a render
// client (`IAudioRenderClient`) for writing into the stream's buffer. Every interface here is laid out as the Windows
// SDK declares it; a method not used is still declared, keeping the ones after it at their places.

/// A COM identifier: 128 bits, in the field layout Windows writes them as text, `1CB9AD4C-DBFA-4C32-B178-C2F568A703B2`.
pub const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,
};

/// A duration in units of 100 nanoseconds: 10 000 to the millisecond.
pub const REFERENCE_TIME = i64;

/// The format of a stream: here 32-bit float samples (`WAVE_FORMAT_IEEE_FLOAT`), interleaved. Windows declares it
/// packed: 18 bytes, `cbSize` counting any extension after them - none here.
pub const WAVEFORMATEX = extern struct {
    wFormatTag: u16 align(1),
    nChannels: u16 align(1),
    nSamplesPerSec: u32 align(1),
    nAvgBytesPerSec: u32 align(1),
    nBlockAlign: u16 align(1),
    wBitsPerSample: u16 align(1),
    cbSize: u16 align(1),
};

/// A device property's key, passed to `IMMNotificationClient.OnPropertyValueChanged`.
pub const PROPERTYKEY = extern struct {
    fmtid: GUID,
    pid: DWORD,
};

comptime {
    if (@sizeOf(GUID) != 16) {
        @compileError("GUID is not laid out as Windows lays it out");
    }
    const is_waveformat_packed: bool = @sizeOf(WAVEFORMATEX) == 18 and
        @offsetOf(WAVEFORMATEX, "nSamplesPerSec") == 4 and
        @offsetOf(WAVEFORMATEX, "cbSize") == 16;
    if (!is_waveformat_packed) {
        @compileError("WAVEFORMATEX is not laid out as Windows lays it out");
    }
}

pub const WAVE_FORMAT_IEEE_FLOAT: u16 = 3;
pub const COINIT_MULTITHREADED: DWORD = 0x0;
pub const CLSCTX_ALL: DWORD = 0x17;
pub const S_OK: HRESULT = 0;
pub const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
/// The device a stream was opened on is gone - unplugged, or disabled.
pub const AUDCLNT_E_DEVICE_INVALIDATED: HRESULT = @bitCast(@as(u32, 0x88890004));
/// COM was initialized on this thread before, in the other apartment model; COM is usable, the call only failed to
/// change the model.
pub const RPC_E_CHANGED_MODE: HRESULT = @bitCast(@as(u32, 0x80010106));
pub const AUDCLNT_SHAREMODE_SHARED: DWORD = 0;
/// The stream signals an event whenever its buffer has room, rather than being polled.
pub const AUDCLNT_STREAMFLAGS_EVENTCALLBACK: DWORD = 0x0004_0000;
/// The stream's volume and mute are not remembered for the next run.
pub const AUDCLNT_STREAMFLAGS_NOPERSIST: DWORD = 0x0008_0000;
/// Windows converts the stream's format - its rate, its channels - to the device's own, at its default quality.
pub const AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM: DWORD = 0x8000_0000;
pub const AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY: DWORD = 0x0800_0000;
/// `EDataFlow` and `ERole`: the output devices, and the device for most sounds (as against communications).
pub const eRender: DWORD = 0;
pub const eConsole: DWORD = 0;
pub const WAIT_OBJECT_0: DWORD = 0;
pub const WAIT_TIMEOUT: DWORD = 0x102;

pub const IID_IUnknown: GUID = .{
    .Data1 = 0x00000000,
    .Data2 = 0x0000,
    .Data3 = 0x0000,
    .Data4 = .{ 0xc0, 0, 0, 0, 0, 0, 0, 0x46 },
};
pub const CLSID_MMDeviceEnumerator: GUID = .{
    .Data1 = 0xbcde0395,
    .Data2 = 0xe52f,
    .Data3 = 0x467c,
    .Data4 = .{ 0x8e, 0x3d, 0xc4, 0x57, 0x92, 0x91, 0x69, 0x2e },
};
pub const IID_IMMDeviceEnumerator: GUID = .{
    .Data1 = 0xa95664d2,
    .Data2 = 0x9614,
    .Data3 = 0x4f35,
    .Data4 = .{ 0xa7, 0x46, 0xde, 0x8d, 0xb6, 0x36, 0x17, 0xe6 },
};
pub const IID_IAudioClient: GUID = .{
    .Data1 = 0x1cb9ad4c,
    .Data2 = 0xdbfa,
    .Data3 = 0x4c32,
    .Data4 = .{ 0xb1, 0x78, 0xc2, 0xf5, 0x68, 0xa7, 0x03, 0xb2 },
};
/// `IAudioClient3`'s identifier, as Windows' audioclient.h has it.
pub const IID_IAudioClient3: GUID = .{
    .Data1 = 0x7ed4ee07,
    .Data2 = 0x8e67,
    .Data3 = 0x4cd4,
    .Data4 = .{ 0x8c, 0x1a, 0x2b, 0x7a, 0x59, 0x87, 0xad, 0x42 },
};
pub const IID_IAudioRenderClient: GUID = .{
    .Data1 = 0xf294acfc,
    .Data2 = 0x3146,
    .Data3 = 0x4483,
    .Data4 = .{ 0xa7, 0xbf, 0xad, 0xdc, 0xa7, 0xc2, 0x60, 0xe2 },
};
pub const IID_IMMNotificationClient: GUID = .{
    .Data1 = 0x7991eec9,
    .Data2 = 0x7e89,
    .Data3 = 0x4d85,
    .Data4 = .{ 0x83, 0x90, 0x6c, 0x70, 0x3c, 0xec, 0x60, 0xc0 },
};

pub const IMMDevice = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*IMMDevice, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IMMDevice) callconv(.winapi) u32,
        Release: *const fn (*IMMDevice) callconv(.winapi) u32,
        /// Makes an object of the given interface for this device: here an `IAudioClient`.
        Activate: *const fn (*IMMDevice, *const GUID, DWORD, ?*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
        OpenPropertyStore: *const anyopaque,
        GetId: *const anyopaque,
        GetState: *const anyopaque,
    };
};

pub const IAudioClient = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*IAudioClient, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IAudioClient) callconv(.winapi) u32,
        Release: *const fn (*IAudioClient) callconv(.winapi) u32,
        /// Opens the stream: share mode, flags, buffer duration, period (0 in shared mode), format, session.
        Initialize: *const fn (
            *IAudioClient,
            DWORD,
            DWORD,
            REFERENCE_TIME,
            REFERENCE_TIME,
            *const WAVEFORMATEX,
            ?*const GUID,
        ) callconv(.winapi) HRESULT,
        /// The stream buffer's size, in frames.
        GetBufferSize: *const fn (*IAudioClient, *u32) callconv(.winapi) HRESULT,
        /// The most time the stream takes, in 100-nanosecond units, from a frame leaving its buffer to the device:
        /// the audio engine's own latency, past the buffer.
        GetStreamLatency: *const fn (*IAudioClient, *REFERENCE_TIME) callconv(.winapi) HRESULT,
        /// How many frames of the buffer are written and not yet played.
        GetCurrentPadding: *const fn (*IAudioClient, *u32) callconv(.winapi) HRESULT,
        IsFormatSupported: *const anyopaque,
        GetMixFormat: *const anyopaque,
        /// The engine's period, the time between its wakeups: the default one, and the shortest.
        GetDevicePeriod: *const fn (*IAudioClient, ?*REFERENCE_TIME, ?*REFERENCE_TIME) callconv(.winapi) HRESULT,
        Start: *const fn (*IAudioClient) callconv(.winapi) HRESULT,
        Stop: *const fn (*IAudioClient) callconv(.winapi) HRESULT,
        Reset: *const anyopaque,
        /// The event the stream signals when its buffer has room (`AUDCLNT_STREAMFLAGS_EVENTCALLBACK`).
        SetEventHandle: *const fn (*IAudioClient, HANDLE) callconv(.winapi) HRESULT,
        /// Gives another interface of the stream: here its `IAudioRenderClient`.
        GetService: *const fn (*IAudioClient, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    };
};

/// The low-latency shared stream's client (Windows 10 and later): `IAudioClient`'s methods, `IAudioClient2`'s, then
/// three of its own. Its stream may run at a period shorter than the engine's standard 10 ms - as short as the driver
/// allows, often 128 to 160 frames at 48 kHz - with no conversion: the stream's format must be one the engine runs
/// at. Reached from an `IAudioClient` by `QueryInterface` with its own interface identifier (`IID_IAudioClient3`),
/// which fails on a Windows without it.
pub const IAudioClient3 = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*IAudioClient3, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IAudioClient3) callconv(.winapi) u32,
        Release: *const fn (*IAudioClient3) callconv(.winapi) u32,
        // IAudioClient's twelve, called through `IAudioClient` itself.
        Initialize: *const anyopaque,
        GetBufferSize: *const anyopaque,
        GetStreamLatency: *const anyopaque,
        GetCurrentPadding: *const anyopaque,
        IsFormatSupported: *const anyopaque,
        GetMixFormat: *const anyopaque,
        GetDevicePeriod: *const anyopaque,
        Start: *const anyopaque,
        Stop: *const anyopaque,
        Reset: *const anyopaque,
        SetEventHandle: *const anyopaque,
        GetService: *const anyopaque,
        // IAudioClient2's three.
        IsOffloadCapable: *const anyopaque,
        SetClientProperties: *const anyopaque,
        GetBufferSizeLimits: *const anyopaque,
        /// The engine's periods for a stream of the given format, in frames: its default, the step between the periods
        /// it allows, its shortest and its longest.
        GetSharedModeEnginePeriod: *const fn (
            *IAudioClient3,
            *const WAVEFORMATEX,
            *u32,
            *u32,
            *u32,
            *u32,
        ) callconv(.winapi) HRESULT,
        GetCurrentSharedModeEnginePeriod: *const anyopaque,
        /// Opens a shared stream at the given period, in frames: flags, period, format, session.
        InitializeSharedAudioStream: *const fn (
            *IAudioClient3,
            DWORD,
            u32,
            *const WAVEFORMATEX,
            ?*const GUID,
        ) callconv(.winapi) HRESULT,
    };

    comptime {
        // IUnknown's 3, IAudioClient's 12, IAudioClient2's 3 and its own 3, in Windows' order: a slot miscounted
        // would call the wrong method.
        if (@sizeOf(VTable) != 21 * @sizeOf(usize)) {
            @compileError("IAudioClient3's table has 21 methods");
        }
    }
};

pub const IAudioRenderClient = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*IAudioRenderClient, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IAudioRenderClient) callconv(.winapi) u32,
        Release: *const fn (*IAudioRenderClient) callconv(.winapi) u32,
        /// Lends the next `frames` frames of the stream's buffer, to be written.
        GetBuffer: *const fn (*IAudioRenderClient, u32, *?[*]u8) callconv(.winapi) HRESULT,
        /// Gives back the frames lent, written; flags 0.
        ReleaseBuffer: *const fn (*IAudioRenderClient, u32, DWORD) callconv(.winapi) HRESULT,
    };
};

/// The interface Windows calls back - on a thread of its own - when output devices come and go, or a default device
/// changes. The engine implements it (`platform/windows.zig`): an object whose first field points to this table.
pub const IMMNotificationClient = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*IMMNotificationClient, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IMMNotificationClient) callconv(.winapi) u32,
        Release: *const fn (*IMMNotificationClient) callconv(.winapi) u32,
        OnDeviceStateChanged: *const fn (*IMMNotificationClient, [*:0]const u16, DWORD) callconv(.winapi) HRESULT,
        OnDeviceAdded: *const fn (*IMMNotificationClient, [*:0]const u16) callconv(.winapi) HRESULT,
        OnDeviceRemoved: *const fn (*IMMNotificationClient, [*:0]const u16) callconv(.winapi) HRESULT,
        /// A direction's default device for a role changed; the id is null when it has none now.
        OnDefaultDeviceChanged: *const fn (
            *IMMNotificationClient,
            DWORD,
            DWORD,
            ?[*:0]const u16,
        ) callconv(.winapi) HRESULT,
        OnPropertyValueChanged: *const fn (
            *IMMNotificationClient,
            [*:0]const u16,
            PROPERTYKEY,
        ) callconv(.winapi) HRESULT,
    };
};

pub const IMMDeviceEnumerator = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*IMMDeviceEnumerator, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IMMDeviceEnumerator) callconv(.winapi) u32,
        Release: *const fn (*IMMDeviceEnumerator) callconv(.winapi) u32,
        EnumAudioEndpoints: *const anyopaque,
        /// The default device for a direction (`eRender`) and a role (`eConsole`).
        GetDefaultAudioEndpoint: *const fn (*IMMDeviceEnumerator, DWORD, DWORD, *?*IMMDevice) callconv(.winapi) HRESULT,
        GetDevice: *const anyopaque,
        /// Asks for a call whenever devices come, go, or a default changes (`IMMNotificationClient`).
        RegisterEndpointNotificationCallback: *const fn (
            *IMMDeviceEnumerator,
            *IMMNotificationClient,
        ) callconv(.winapi) HRESULT,
        UnregisterEndpointNotificationCallback: *const fn (
            *IMMDeviceEnumerator,
            *IMMNotificationClient,
        ) callconv(.winapi) HRESULT,
    };
};

pub extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: DWORD) callconv(.winapi) HRESULT;
pub extern "ole32" fn CoUninitialize() callconv(.winapi) void;
pub extern "ole32" fn CoCreateInstance(
    rclsid: *const GUID,
    pUnkOuter: ?*anyopaque,
    dwClsContext: DWORD,
    riid: *const GUID,
    ppv: *?*anyopaque,
) callconv(.winapi) HRESULT;
pub extern "kernel32" fn CreateEventW(
    lpEventAttributes: ?*anyopaque,
    bManualReset: BOOL,
    bInitialState: BOOL,
    lpName: ?[*:0]const u16,
) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn SetEvent(hEvent: HANDLE) callconv(.winapi) BOOL;
/// Registers the calling thread with the Multimedia Class Scheduler Service under a task name ("Pro Audio"): Windows
/// then schedules it ahead of ordinary work, so that a busy machine does not delay it. Returns null when it cannot.
pub extern "avrt" fn AvSetMmThreadCharacteristicsW(
    TaskName: [*:0]const u16,
    TaskIndex: *DWORD,
) callconv(.winapi) ?HANDLE;
pub extern "avrt" fn AvRevertMmThreadCharacteristics(AvrtHandle: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn WaitForMultipleObjects(
    nCount: DWORD,
    lpHandles: [*]const HANDLE,
    bWaitAll: BOOL,
    dwMilliseconds: DWORD,
) callconv(.winapi) DWORD;

// ---- Waiting for a message, or a moment ----

/// Waits for any of `pHandles` or for the thread's message queue to hold input of the kinds `dwWakeMask` names, at
/// most `dwMilliseconds`: `WAIT_OBJECT_0 + i` for handle `i`, `WAIT_OBJECT_0 + nCount` for a message.
pub extern "user32" fn MsgWaitForMultipleObjectsEx(
    nCount: DWORD,
    pHandles: ?[*]const HANDLE,
    dwMilliseconds: DWORD,
    dwWakeMask: DWORD,
    dwFlags: DWORD,
) callconv(.winapi) DWORD;
/// Every kind of message, input and others (`MsgWaitForMultipleObjectsEx`).
pub const QS_ALLINPUT: DWORD = 0x04FF;
/// Returns for a message already in the queue too, not only one arriving during the wait.
pub const MWMO_INPUTAVAILABLE: DWORD = 0x0004;
pub const INFINITE: DWORD = 0xFFFF_FFFF;
/// A waitable timer: signalled once when its due time comes (`SetWaitableTimer`). With
/// `CREATE_WAITABLE_TIMER_HIGH_RESOLUTION` (Windows 10 version 1803 and later) it keeps its due time to well under a
/// millisecond, where an ordinary one waits for the system's timer tick - 15.6 ms unless a program asks for less.
pub extern "kernel32" fn CreateWaitableTimerExW(
    lpTimerAttributes: ?*anyopaque,
    lpTimerName: ?[*:0]const u16,
    dwFlags: DWORD,
    dwDesiredAccess: DWORD,
) callconv(.winapi) ?HANDLE;
pub const CREATE_WAITABLE_TIMER_HIGH_RESOLUTION: DWORD = 0x0000_0002;
pub const TIMER_ALL_ACCESS: DWORD = 0x001F_0003;
/// Arms `hTimer`: due at `lpDueTime`, in units of 100 ns - negative for a time relative to now.
pub extern "kernel32" fn SetWaitableTimer(
    hTimer: HANDLE,
    lpDueTime: *const i64,
    lPeriod: i32,
    pfnCompletionRoutine: ?*anyopaque,
    lpArgToCompletionRoutine: ?*anyopaque,
    fResume: BOOL,
) callconv(.winapi) BOOL;

// ---- The environment ----

/// The environment variable `name`'s value as UTF-8, written into `buffer`: null when it is not set, longer than 255
/// UTF-16 units, or does not fit `buffer`.
pub fn environmentVariable(comptime name: []const u8, buffer: []u8) ?[]const u8 {
    const wide_name: [*:0]const u16 = utf8ToUtf16LeStringLiteral(name);
    var wide_value: [256]u16 = undefined;
    // The length without the terminating zero; 0 when unset, the size needed when the buffer is too small.
    const length: DWORD = GetEnvironmentVariableW(wide_name, &wide_value, wide_value.len);
    if (length == 0 or length >= wide_value.len) {
        return null;
    }
    const written: usize = utf16LeToUtf8(buffer, wide_value[0..length]) catch return null;
    return buffer[0..written];
}

// ---- The clock ----

/// A monotonic clock in milliseconds, from the performance counter.
pub fn monotonicMilliseconds() f64 {
    var counter: i64 = 0;
    var frequency: i64 = 1;
    _ = QueryPerformanceCounter(&counter);
    _ = QueryPerformanceFrequency(&frequency);
    const counter_float: f64 = @floatFromInt(counter);
    const frequency_float: f64 = @floatFromInt(frequency);
    return counter_float * 1000.0 / frequency_float;
}

// ---- The Vulkan loader ----

pub const VulkanLibrary = struct {
    module: HMODULE,
    /// `vkGetInstanceProcAddr`, untyped: the Vulkan host casts it to its own declaration.
    get_instance_proc_address: *const anyopaque,
};

pub const VulkanLibraryError = error{
    /// `vulkan-1.dll` is not installed: no Vulkan driver on this machine.
    VulkanNotInstalled,
    /// The library loaded but does not export `vkGetInstanceProcAddr`.
    VulkanLoaderIncomplete,
};

pub fn openVulkanLibrary() VulkanLibraryError!VulkanLibrary {
    const library_name: [*:0]const u16 = utf8ToUtf16LeStringLiteral("vulkan-1.dll");
    const module: HMODULE = LoadLibraryW(library_name) orelse return error.VulkanNotInstalled;
    const entry: *const anyopaque = GetProcAddress(module, "vkGetInstanceProcAddr") orelse {
        _ = FreeLibrary(module);
        return error.VulkanLoaderIncomplete;
    };
    return .{ .module = module, .get_instance_proc_address = entry };
}

pub fn closeVulkanLibrary(library: VulkanLibrary) void {
    _ = FreeLibrary(library.module);
}

// ---- The window ----

pub const WindowError = error{
    NoModuleHandle,
    TitleNotUtf8,
    RegisterClassFailed,
    CreateWindowFailed,
};

pub const WindowOptions = struct {
    title: []const u8,
    /// The client area's size in logical pixels; the window opens at this size times the monitor's scale.
    logical_width: u32,
    logical_height: u32,
};

/// An input message as the window received it, for the input handler: the message, its two parameters, and the
/// window's scale at that moment (mouse positions are in physical pixels).
pub const InputMessage = struct {
    message: UINT,
    w_param: WPARAM,
    l_param: LPARAM,
    scale: f32,
    /// For a key going down, what it types on the current layout without modifiers, lowercased (`keyLabel`); 0
    /// for every other message. Read here, where the layout is known, so the translation stays a pure function.
    label: u21 = 0,
    /// For a paste (`message_paste`), the pasted text as UTF-8, in the window's paste buffer until the next paste.
    text: []const u8 = &.{},
    /// For a mouse message, its extra information (`GetMessageExtraInfo`), read while the message was handled: it says
    /// whether a pen or a touch made it. 0 for every other message.
    extra_info: usize = 0,
};

/// Whether a key going down is Windows' paste command: V with Ctrl held and Alt not (AltGr is Ctrl and Alt together,
/// and types characters), or Insert with Shift held.
fn isPasteCommand(virtual_key: WPARAM) bool {
    const is_control_held: bool = GetKeyState(VK_CONTROL) < 0 and GetKeyState(VK_MENU) >= 0;
    const is_shift_held: bool = GetKeyState(VK_SHIFT) < 0;
    const is_control_v: bool = virtual_key == 'V' and is_control_held;
    const is_shift_insert: bool = virtual_key == VK_INSERT and is_shift_held;
    return is_control_v or is_shift_insert;
}

/// What a virtual key types on the current keyboard layout without modifiers, lowercased - `MapVirtualKeyW` gives
/// the unshifted character, a letter in capitals - or 0 for a key that types nothing by itself: Shift, an arrow, or
/// a dead key, which the high bit marks and which types only with the key after it.
fn keyLabel(virtual_key: UINT) u21 {
    const mapped: UINT = MapVirtualKeyW(virtual_key, MAPVK_VK_TO_CHAR);
    const is_dead_key: bool = mapped & 0x8000_0000 != 0;
    const character: UINT = mapped & 0xffff;
    if (is_dead_key or character == 0) {
        return 0;
    }
    if (character >= 'A' and character <= 'Z') {
        return @intCast(character - 'A' + 'a');
    }
    return @intCast(character);
}

/// Receives the window's input messages, once the window procedure has done Windows' own part of each.
pub const InputHandler = *const fn (message: InputMessage) void;

pub const Window = struct {
    module: HINSTANCE,
    handle: ?HWND,
    /// The window's dots per inch: 96 at 100% scale, 144 at 150%.
    dpi: u32,
    /// The client area's size in physical pixels.
    client_width: u32,
    client_height: u32,
    close_requested: bool,
    minimized: bool,
    size_changed: bool,
    /// Whether the pointer is over the client area: set at the first WM_MOUSEMOVE after it left, which asks Windows
    /// for the next WM_MOUSELEAVE; cleared by that WM_MOUSELEAVE.
    is_pointer_inside: bool = false,
    /// A batch of files dropped on the window, kept for the loop to read between frames (`takeDroppedFiles`).
    pending_drop: ?HDROP = null,
    /// Whether the pointer is locked (`lockPointer`): hidden, held at the client area's centre, its position held
    /// still for the engine, and the mouse's own motion read from raw input.
    is_pointer_locked: bool = false,
    /// Where the cursor was on the screen when the lock began; it returns there when the lock ends.
    cursor_before_lock: POINT = .{ .x = 0, .y = 0 },
    /// The cursor shown over the client area (`setCursorShape`): null for the window class's arrow, until a shape is
    /// set; and whether it is hidden instead.
    cursor: ?HCURSOR = null,
    is_cursor_hidden: bool = false,
    /// The text of the latest paste, as UTF-8 (`requestPaste`).
    paste_utf8: [32 * 1024]u8 = undefined,
    /// Whether the window covers its monitor without borders (`setFullscreen`), and where it was before, to return.
    is_fullscreen: bool = false,
    placement_before_fullscreen: WINDOWPLACEMENT = zeroes(WINDOWPLACEMENT),
    /// The client area's size limits, in logical pixels (0: unlimited), turned into the frame's at the window's own
    /// scale whenever Windows asks (`WM_GETMINMAXINFO`), so that they follow the window from monitor to monitor.
    min_client_width: f32 = 0,
    min_client_height: f32 = 0,
    max_client_width: f32 = 0,
    max_client_height: f32 = 0,
    /// Set when a message says the monitors may have changed - plugged in or out, a resolution or a scale - so that
    /// whoever keeps a list of them lists them again.
    monitors_changed: bool = false,
    /// Where input messages go; none until the program sets one.
    input_handler: ?InputHandler,
    title_utf16: [256:0]u16,

    const class_name: [*:0]const u16 = utf8ToUtf16LeStringLiteral("zimr_window");

    /// Opens the window IN PLACE: Windows keeps a pointer to `window`, which must not move until `close`.
    pub fn open(window: *Window, options: WindowOptions) WindowError!void {
        // Per-monitor DPI awareness, version 2. It fails harmlessly if the process is already aware (a manifest).
        const per_monitor_v2: usize = @bitCast(dpi_awareness_context_per_monitor_aware_v2);
        _ = SetProcessDpiAwarenessContext(@ptrFromInt(per_monitor_v2));
        const module: HINSTANCE = GetModuleHandleW(null) orelse return WindowError.NoModuleHandle;
        window.* = .{
            .module = module,
            .handle = null,
            .dpi = GetDpiForSystem(),
            .client_width = 0,
            .client_height = 0,
            .close_requested = false,
            .minimized = false,
            .size_changed = false,
            .input_handler = null,
            .title_utf16 = @splat(0),
        };
        const title_room: []u16 = window.title_utf16[0 .. window.title_utf16.len - 1];
        const title_length: usize = utf8ToUtf16Le(title_room, options.title) catch return WindowError.TitleNotUtf8;
        window.title_utf16[title_length] = 0;

        const window_class: WNDCLASSEXW = .{
            .cbSize = @sizeOf(WNDCLASSEXW),
            .style = CS_HREDRAW | CS_VREDRAW | CS_OWNDC,
            .lpfnWndProc = &windowProcedure,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = module,
            .hIcon = null,
            .hCursor = LoadCursorW(null, @ptrFromInt(IDC_ARROW)),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = class_name,
            .hIconSm = null,
        };
        if (RegisterClassExW(&window_class) == 0) {
            return WindowError.RegisterClassFailed;
        }

        // The outer size that gives this client size at the system's scale; WM_DPICHANGED corrects it if the
        // window opens on a monitor with another scale.
        var outer: RECT = .{
            .left = 0,
            .top = 0,
            .right = @intCast(options.logical_width * window.dpi / USER_DEFAULT_SCREEN_DPI),
            .bottom = @intCast(options.logical_height * window.dpi / USER_DEFAULT_SCREEN_DPI),
        };
        _ = AdjustWindowRectExForDpi(&outer, WS_OVERLAPPEDWINDOW, 0, 0, window.dpi);
        const handle: HWND = CreateWindowExW(
            0,
            class_name,
            &window.title_utf16,
            WS_OVERLAPPEDWINDOW,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            outer.right - outer.left,
            outer.bottom - outer.top,
            null,
            null,
            module,
            window,
        ) orelse {
            _ = UnregisterClassW(class_name, module);
            return WindowError.CreateWindowFailed;
        };
        window.handle = handle;
        window.dpi = GetDpiForWindow(handle);
        _ = ShowWindow(handle, SW_SHOW);
        // Files dropped on the window arrive as `WM_DROPFILES`.
        DragAcceptFiles(handle, 1);
        window.readClientSize();
        window.size_changed = false;
    }

    /// The batch of files dropped on the window since the last call, if any; the caller frees it (`DragFinish`).
    pub fn takeDroppedFiles(window: *Window) ?HDROP {
        const drop: ?HDROP = window.pending_drop;
        window.pending_drop = null;
        return drop;
    }

    /// The form both file dialogs start from: owned by the window, filtered by `filter`, the chosen path written
    /// into `path`.
    fn fileDialogForm(
        window: *const Window,
        filter: [*]const u16,
        path: []u16,
    ) OPENFILENAMEW {
        var form: OPENFILENAMEW = zeroes(OPENFILENAMEW);
        form.lStructSize = @sizeOf(OPENFILENAMEW);
        form.hwndOwner = window.handle;
        form.lpstrFilter = filter;
        form.nFilterIndex = 1;
        form.lpstrFile = path.ptr;
        form.nMaxFile = @intCast(path.len);
        return form;
    }

    /// Asks the person for a file to load, with the system's Open dialog: its path is written into `path`,
    /// null-terminated. Returns whether one was chosen. The dialog is modal: the window's frames wait while it is
    /// open.
    pub fn chooseFileToOpen(window: *Window, filter: [*]const u16, path: []u16) bool {
        path[0] = 0;
        var form: OPENFILENAMEW = window.fileDialogForm(filter, path);
        form.Flags = OFN_EXPLORER | OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;
        return GetOpenFileNameW(&form) != 0;
    }

    /// Asks the person where to save a file, with the system's Save dialog: `path` begins as the file's suggested
    /// name, null-terminated, and comes back as the chosen path; `default_extension` - without its dot - is added
    /// to a name typed without one. An existing file is replaced only once the person confirms.
    pub fn chooseFileToSave(
        window: *Window,
        filter: [*]const u16,
        default_extension: [*:0]const u16,
        path: []u16,
    ) bool {
        var form: OPENFILENAMEW = window.fileDialogForm(filter, path);
        form.lpstrDefExt = default_extension;
        form.Flags = OFN_EXPLORER | OFN_OVERWRITEPROMPT | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;
        return GetSaveFileNameW(&form) != 0;
    }

    /// Handles every waiting message, then returns: call once per frame.
    pub fn pump(window: *Window) void {
        _ = window;
        var message: MSG = undefined;
        while (PeekMessageW(&message, null, 0, 0, PM_REMOVE) != 0) {
            _ = TranslateMessage(&message);
            _ = DispatchMessageW(&message);
        }
    }

    /// Destroys the window and unregisters its class.
    pub fn close(window: *Window) void {
        if (window.handle) |handle| {
            _ = DestroyWindow(handle);
            window.handle = null;
        }
        _ = UnregisterClassW(class_name, window.module);
    }

    /// Physical pixels per logical pixel - the window's DPI over the standard 96: 1.0 at 100% scale, 1.5 at 150%.
    pub fn scale(window: *const Window) f32 {
        const dpi: f32 = @floatFromInt(window.dpi);
        const default_dpi: f32 = @floatFromInt(USER_DEFAULT_SCREEN_DPI);
        return dpi / default_dpi;
    }

    fn readClientSize(window: *Window) void {
        const handle: HWND = window.handle orelse return;
        var client: RECT = undefined;
        if (GetClientRect(handle, &client) != 0) {
            window.client_width = @intCast(@max(client.right - client.left, 0));
            window.client_height = @intCast(@max(client.bottom - client.top, 0));
        }
        window.minimized = window.client_width == 0 or window.client_height == 0;
        window.size_changed = true;
    }

    /// Hands an input message to the input handler, with the window's scale. A key message without a scancode -
    /// software keyboards send some - gets the one its virtual-key code maps to, so every key message names its key.
    /// Locks the pointer, as a first-person camera needs it. The mouse is registered for raw input, so its own motion
    /// keeps coming whatever the cursor does - and comes unaccelerated, as the hand moved. The cursor is held at the
    /// client area's centre, so a click cannot land in another window and the hidden cursor cannot wander, and it
    /// returns to where it was when the lock ends, as in a browser. The outcome is reported as input
    /// (`message_pointer_lock_changed`), as a browser reports `pointerlockchange`.
    pub fn lockPointer(window: *Window) void {
        const handle: HWND = window.handle orelse return;
        if (window.is_pointer_locked) {
            return;
        }
        const mouse = [1]RAWINPUTDEVICE{.{
            .usUsagePage = HID_USAGE_PAGE_GENERIC,
            .usUsage = HID_USAGE_GENERIC_MOUSE,
            .dwFlags = 0,
            .hwndTarget = handle,
        }};
        if (RegisterRawInputDevices(&mouse, mouse.len, @sizeOf(RAWINPUTDEVICE)) == 0) {
            window.forwardInput(message_pointer_lock_changed, 0, 0);
            return;
        }
        window.is_pointer_locked = true;
        _ = GetCursorPos(&window.cursor_before_lock);
        window.confinePointer();
        _ = SetCursor(null);
        window.forwardInput(message_pointer_lock_changed, 1, 0);
    }

    /// Ends a lock: the raw input registration taken back, and the cursor freed, put back where it was, and shown.
    pub fn releasePointerLock(window: *Window) void {
        if (!window.is_pointer_locked) {
            return;
        }
        window.is_pointer_locked = false;
        const mouse = [1]RAWINPUTDEVICE{.{
            .usUsagePage = HID_USAGE_PAGE_GENERIC,
            .usUsage = HID_USAGE_GENERIC_MOUSE,
            .dwFlags = RIDEV_REMOVE,
            .hwndTarget = null,
        }};
        _ = RegisterRawInputDevices(&mouse, mouse.len, @sizeOf(RAWINPUTDEVICE));
        _ = ClipCursor(null);
        _ = SetCursorPos(window.cursor_before_lock.x, window.cursor_before_lock.y);
        _ = SetCursor(window.shownCursor());
        window.forwardInput(message_pointer_lock_changed, 0, 0);
    }

    /// Holds the cursor at the client area's centre - a confinement rectangle of one point, in screen coordinates -
    /// when the lock begins, and again whenever the window moves or changes size.
    fn confinePointer(window: *Window) void {
        const handle: HWND = window.handle orelse return;
        var client: RECT = undefined;
        if (GetClientRect(handle, &client) == 0) {
            return;
        }
        var center: POINT = .{
            .x = @divTrunc(client.right - client.left, 2),
            .y = @divTrunc(client.bottom - client.top, 2),
        };
        _ = ClientToScreen(handle, &center);
        const one_point: RECT = .{ .left = center.x, .top = center.y, .right = center.x, .bottom = center.y };
        _ = ClipCursor(&one_point);
    }

    /// Reads one raw input report and forwards its motion (`message_pointer_motion`). A report of an absolute
    /// position - a tablet, a remote desktop - carries no motion, and a report of buttons alone none either; both
    /// are left out.
    fn forwardRawMotion(window: *Window, l_param: LPARAM) void {
        var report: RAWINPUT = undefined;
        var report_size: UINT = @sizeOf(RAWINPUT);
        const raw_input: *anyopaque = @ptrFromInt(@as(usize, @bitCast(l_param)));
        const written: UINT = GetRawInputData(raw_input, RID_INPUT, &report, &report_size, @sizeOf(RAWINPUTHEADER));
        // `GetRawInputData` answers (UINT)-1 when it fails.
        const failed: UINT = 0xffff_ffff;
        // Each check reads only what the ones before it vouched for: a whole report, then a mouse's, then its motion.
        const is_whole_report: bool = written != failed and written >= @sizeOf(RAWINPUTHEADER) + @sizeOf(RAWMOUSE);
        if (!is_whole_report) {
            return;
        }
        if (report.header.dwType != RIM_TYPEMOUSE) {
            return;
        }
        const is_absolute: bool = report.mouse.usFlags & MOUSE_MOVE_ABSOLUTE != 0;
        if (is_absolute) {
            return;
        }
        const has_motion: bool = report.mouse.lLastX != 0 or report.mouse.lLastY != 0;
        if (!has_motion) {
            return;
        }
        const horizontal: WPARAM = @bitCast(@as(isize, report.mouse.lLastX));
        const vertical: LPARAM = report.mouse.lLastY;
        window.forwardInput(message_pointer_motion, horizontal, vertical);
    }

    /// Turns the window's input method on or off. It is off from the window's opening and between text fields, so a
    /// game's keys never start a composition; it is on while a field takes text, and an input method - for Chinese,
    /// Japanese, Korean - composes the keys first, its committed text arriving as `WM_CHAR`, as typed text does.
    pub fn setInputMethodEnabled(window: *Window, is_enabled: bool) void {
        const handle: HWND = window.handle orelse return;
        const flags: DWORD = if (is_enabled) IACE_DEFAULT else 0;
        _ = ImmAssociateContextEx(handle, null, flags);
    }

    /// Places the input method's windows for a text field at `field`, in client pixels, its caret at `caret`: the
    /// composition drawn at the caret, as Dear ImGui places it, and the list of candidates kept outside the field,
    /// as SDL keeps it, so the list never covers the line being typed.
    pub fn placeInputMethod(window: *Window, field: RECT, caret: POINT) void {
        const handle: HWND = window.handle orelse return;
        const context: HIMC = ImmGetContext(handle) orelse return;
        defer _ = ImmReleaseContext(handle, context);
        const composition: COMPOSITIONFORM = .{ .dwStyle = CFS_FORCE_POSITION, .ptCurrentPos = caret, .rcArea = field };
        _ = ImmSetCompositionWindow(context, &composition);
        const candidates: CANDIDATEFORM = .{
            .dwIndex = 0,
            .dwStyle = CFS_EXCLUDE,
            .ptCurrentPos = caret,
            .rcArea = field,
        };
        _ = ImmSetCandidateWindow(context, &candidates);
    }

    /// Sets the title bar's text. The title is kept as UTF-16, which never needs more units than UTF-8 has bytes, so a
    /// title no longer than the buffer always fits; a longer one is cut at the last character boundary that does. A
    /// title that is not UTF-8 leaves the title as it was.
    pub fn setTitle(window: *Window, title: []const u8) void {
        const handle: HWND = window.handle orelse return;
        const room: []u16 = window.title_utf16[0 .. window.title_utf16.len - 1];
        var fitting_length: usize = @min(title.len, room.len);
        // A UTF-8 continuation byte (10xxxxxx) at the cut means the cut splits a character: move the cut back.
        while (fitting_length > 0 and fitting_length < title.len and title[fitting_length] & 0xc0 == 0x80) {
            fitting_length -= 1;
        }
        const length: usize = utf8ToUtf16Le(room, title[0..fitting_length]) catch return;
        window.title_utf16[length] = 0;
        _ = SetWindowTextW(handle, @ptrCast(&window.title_utf16));
    }

    /// Shows the system cursor `cursor_id` (an IDC_ value) over the client area from now on, or hides it (null). It
    /// changes at once when the pointer is over the client area, and WM_SETCURSOR keeps it there.
    pub fn setCursorShape(window: *Window, cursor_id: ?usize) void {
        if (cursor_id) |id| {
            window.cursor = LoadCursorW(null, @ptrFromInt(id));
            window.is_cursor_hidden = false;
        } else {
            window.is_cursor_hidden = true;
        }
        if (window.is_pointer_inside and !window.is_pointer_locked) {
            _ = SetCursor(window.shownCursor());
        }
    }

    /// The cursor to show over the client area: none while hidden, the shape set, or the arrow.
    fn shownCursor(window: *const Window) ?HCURSOR {
        if (window.is_cursor_hidden) {
            return null;
        }
        return window.cursor orelse LoadCursorW(null, @ptrFromInt(IDC_ARROW));
    }

    /// Fullscreen as borderless windowed: the window's frame removed and the window stretched over its monitor; the
    /// frame and the place it had are given back when fullscreen ends. Switching is immediate and needs no change of
    /// display mode, so other windows and the desktop stay as they were. The outcome is reported as input
    /// (`message_fullscreen_changed`), as a browser reports `fullscreenchange`.
    pub fn setFullscreen(window: *Window, on: bool) void {
        const handle: HWND = window.handle orelse return;
        if (on == window.is_fullscreen) {
            window.forwardInput(message_fullscreen_changed, @intFromBool(on), 0);
            return;
        }
        const style: LONG_PTR = GetWindowLongPtrW(handle, GWL_STYLE);
        const frame: LONG_PTR = WS_OVERLAPPEDWINDOW;
        if (on) {
            var monitor_info: MONITORINFO = zeroes(MONITORINFO);
            monitor_info.cbSize = @sizeOf(MONITORINFO);
            window.placement_before_fullscreen.length = @sizeOf(WINDOWPLACEMENT);
            const monitor: *anyopaque = MonitorFromWindow(handle, MONITOR_DEFAULTTONEAREST) orelse return;
            const has_placement: bool = GetWindowPlacement(handle, &window.placement_before_fullscreen) != 0;
            if (!has_placement or GetMonitorInfoW(monitor, &monitor_info) == 0) {
                window.forwardInput(message_fullscreen_changed, 0, 0);
                return;
            }
            const area: RECT = monitor_info.rcMonitor;
            _ = SetWindowLongPtrW(handle, GWL_STYLE, style & ~frame);
            const flags: UINT = SWP_NOOWNERZORDER | SWP_FRAMECHANGED;
            _ = SetWindowPos(handle, null, area.left, area.top, area.right - area.left, area.bottom - area.top, flags);
        } else {
            _ = SetWindowLongPtrW(handle, GWL_STYLE, style | frame);
            _ = SetWindowPlacement(handle, &window.placement_before_fullscreen);
            const flags: UINT = SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_FRAMECHANGED;
            _ = SetWindowPos(handle, null, 0, 0, 0, 0, flags);
        }
        window.is_fullscreen = on;
        window.forwardInput(message_fullscreen_changed, @intFromBool(on), 0);
    }

    /// Reads the clipboard's text and forwards it as a paste (`message_paste`). A clipboard without text, or one
    /// another program holds open, pastes nothing.
    pub fn requestPaste(window: *Window) void {
        const text: []const u8 = window.readClipboardText() orelse return;
        const handler: InputHandler = window.input_handler orelse return;
        handler(.{
            .message = message_paste,
            .w_param = 0,
            .l_param = 0,
            .scale = window.scale(),
            .text = text,
        });
    }

    /// The clipboard's text as UTF-8, written into the window's paste buffer - a text longer than the buffer keeps its
    /// first part, whole characters only - or null when there is no text or the clipboard cannot be opened.
    fn readClipboardText(window: *Window) ?[]const u8 {
        const handle: HWND = window.handle orelse return null;
        if (OpenClipboard(handle) == 0) {
            return null;
        }
        defer _ = CloseClipboard();
        const memory: *anyopaque = GetClipboardData(CF_UNICODETEXT) orelse return null;
        const locked: *anyopaque = GlobalLock(memory) orelse return null;
        defer _ = GlobalUnlock(memory);
        const units: [*:0]const u16 = @ptrCast(@alignCast(locked));
        var iterator: std.unicode.Utf16LeIterator = .init(units[0..std.mem.len(units)]);
        var written: usize = 0;
        while (iterator.nextCodepoint() catch null) |code_point| {
            const sequence_length: u3 = std.unicode.utf8CodepointSequenceLength(code_point) catch break;
            if (written + sequence_length > window.paste_utf8.len) {
                break;
            }
            _ = std.unicode.utf8Encode(code_point, window.paste_utf8[written..]) catch break;
            written += sequence_length;
        }
        return window.paste_utf8[0..written];
    }

    fn forwardInput(
        window: *Window,
        message: UINT,
        w_param: WPARAM,
        l_param: LPARAM,
    ) void {
        const handler: InputHandler = window.input_handler orelse return;
        var parameter_bits: usize = @bitCast(l_param);
        const is_key_message: bool = message == WM_KEYDOWN or message == WM_KEYUP or
            message == WM_SYSKEYDOWN or message == WM_SYSKEYUP;
        const has_scancode: bool = (parameter_bits >> 16) & 0xff != 0;
        if (is_key_message and !has_scancode) {
            const virtual_key: UINT = @truncate(w_param);
            const mapped_scancode: usize = MapVirtualKeyW(virtual_key, MAPVK_VK_TO_VSC);
            parameter_bits |= (mapped_scancode & 0xff) << 16;
        }
        const is_key_down: bool = message == WM_KEYDOWN or message == WM_SYSKEYDOWN;
        const is_mouse_message: bool = message >= WM_MOUSEMOVE and message <= WM_XBUTTONUP;
        var extra_info: usize = 0;
        if (is_mouse_message) {
            extra_info = @bitCast(GetMessageExtraInfo());
        }
        handler(.{
            .message = message,
            .w_param = w_param,
            .l_param = @bitCast(parameter_bits),
            .scale = window.scale(),
            .label = if (is_key_down) keyLabel(@truncate(w_param)) else 0,
            .extra_info = extra_info,
        });
    }

    /// Called by Windows for every message to the window, from inside `pump` (and during `CreateWindowExW`).
    /// Shows the window in a state: `SW_MINIMIZE`, `SW_MAXIMIZE` or `SW_RESTORE`.
    pub fn show(window: *Window, command: i32) void {
        const handle: HWND = window.handle orelse return;
        _ = ShowWindow(handle, command);
    }

    /// Asks to bring the window to the front. Windows grants it only to a program the person is using; otherwise it
    /// flashes the window's button on the taskbar.
    pub fn bringToFront(window: *Window) void {
        const handle: HWND = window.handle orelse return;
        _ = SetForegroundWindow(handle);
    }

    /// Moves the window, keeping its size, so that its client area's top-left corner lands at (`x`, `y`) on the
    /// desktop, in physical pixels. The frame's corner sits up and to the left of it by the frame's thickness at
    /// `dpi` - the scale of the monitor the window lands on, which the window takes there (`WM_DPICHANGED`).
    pub fn moveClientTo(window: *Window, x: i32, y: i32, dpi: u32) void {
        const handle: HWND = window.handle orelse return;
        var frame: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        _ = AdjustWindowRectExForDpi(&frame, WS_OVERLAPPEDWINDOW, 0, 0, dpi);
        _ = SetWindowPos(handle, null, x + frame.left, y + frame.top, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    }

    /// Resizes the window into its size limits when it lies outside them: its client area, in logical pixels at
    /// the window's scale, held to each limit set, and the frame resized around the result. Windows applies the
    /// limits itself only when a person drags the frame (`limitSize`); a window outside new limits is brought inside
    /// at once. A maximized, minimized or fullscreen window is left as it is: the limits apply once it is restored.
    pub fn applySizeLimits(window: *Window) void {
        const handle: HWND = window.handle orelse return;
        if (window.is_fullscreen or window.minimized or IsZoomed(handle) != 0) {
            return;
        }
        const dpi_value: f32 = @floatFromInt(window.dpi);
        const window_scale: f32 = dpi_value / 96.0;
        const physical_width: f32 = @floatFromInt(window.client_width);
        const physical_height: f32 = @floatFromInt(window.client_height);
        const current_width: f32 = physical_width / window_scale;
        const current_height: f32 = physical_height / window_scale;
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
        if (width == current_width and height == current_height) {
            return;
        }
        const frame: POINT = window.frameAround(width, height);
        _ = SetWindowPos(handle, null, 0, 0, frame.x, frame.y, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
    }

    /// Writes the client area's limits into the sizes Windows lets the frame take: each limit set - a client size in
    /// logical pixels - becomes physical at the window's scale, then the frame around it (`AdjustWindowRectExForDpi`).
    /// A fullscreen window, without a frame, keeps Windows' own sizes.
    fn limitSize(window: *const Window, limits: *MINMAXINFO) void {
        if (window.is_fullscreen) {
            return;
        }
        const has_minimum: bool = window.min_client_width > 0 or window.min_client_height > 0;
        if (has_minimum) {
            const frame: POINT = window.frameAround(window.min_client_width, window.min_client_height);
            if (window.min_client_width > 0) {
                limits.ptMinTrackSize.x = frame.x;
            }
            if (window.min_client_height > 0) {
                limits.ptMinTrackSize.y = frame.y;
            }
        }
        const has_maximum: bool = window.max_client_width > 0 or window.max_client_height > 0;
        if (has_maximum) {
            const frame: POINT = window.frameAround(window.max_client_width, window.max_client_height);
            if (window.max_client_width > 0) {
                limits.ptMaxTrackSize.x = frame.x;
            }
            if (window.max_client_height > 0) {
                limits.ptMaxTrackSize.y = frame.y;
            }
        }
    }

    /// The frame's size around a client area of `width` by `height` logical pixels, at the window's scale.
    fn frameAround(window: *const Window, width: f32, height: f32) POINT {
        const dpi_value: f32 = @floatFromInt(window.dpi);
        const window_scale: f32 = dpi_value / 96.0;
        var outer: RECT = .{
            .left = 0,
            .top = 0,
            .right = @round(width * window_scale),
            .bottom = @round(height * window_scale),
        };
        _ = AdjustWindowRectExForDpi(&outer, WS_OVERLAPPEDWINDOW, 0, 0, window.dpi);
        return .{ .x = outer.right - outer.left, .y = outer.bottom - outer.top };
    }

    fn windowProcedure(
        handle: HWND,
        message: UINT,
        w_param: WPARAM,
        l_param: LPARAM,
    ) callconv(.winapi) LRESULT {
        if (message == WM_NCCREATE) {
            // The creation parameters carry the `*Window`; keep it in the window's user-data slot.
            const creation: *const CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(l_param)));
            _ = SetWindowLongPtrW(handle, GWLP_USERDATA, @bitCast(@intFromPtr(creation.lpCreateParams)));
            return DefWindowProcW(handle, message, w_param, l_param);
        }
        const stored: LONG_PTR = GetWindowLongPtrW(handle, GWLP_USERDATA);
        if (stored == 0) {
            return DefWindowProcW(handle, message, w_param, l_param);
        }
        const window: *Window = @ptrFromInt(@as(usize, @bitCast(stored)));
        switch (message) {
            WM_CLOSE => {
                // The program decides when to destroy the window: after its last frame and its GPU teardown.
                window.close_requested = true;
                return 0;
            },
            WM_SIZE => {
                window.client_width = lowWord(@bitCast(l_param));
                window.client_height = highWord(@bitCast(l_param));
                window.minimized = w_param == SIZE_MINIMIZED or window.client_width == 0 or window.client_height == 0;
                window.size_changed = true;
                if (window.is_pointer_locked) {
                    window.confinePointer();
                }
                return 0;
            },
            WM_GETMINMAXINFO => {
                const limits: *MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(l_param)));
                window.limitSize(limits);
                return 0;
            },
            WM_DISPLAYCHANGE, WM_SETTINGCHANGE => {
                window.monitors_changed = true;
                return DefWindowProcW(handle, message, w_param, l_param);
            },
            WM_DPICHANGED => {
                // The new scale (horizontal and vertical are equal), and the rectangle Windows suggests at it.
                window.dpi = lowWord(w_param);
                window.monitors_changed = true;
                const suggested: *const RECT = @ptrFromInt(@as(usize, @bitCast(l_param)));
                _ = SetWindowPos(
                    handle,
                    null,
                    suggested.left,
                    suggested.top,
                    suggested.right - suggested.left,
                    suggested.bottom - suggested.top,
                    SWP_NOZORDER | SWP_NOACTIVATE,
                );
                return 0;
            },
            WM_KEYUP, WM_CHAR, WM_MOUSEWHEEL, WM_MOUSEHWHEEL, WM_SETFOCUS => {
                window.forwardInput(message, w_param, l_param);
                return 0;
            },
            WM_KEYDOWN => {
                window.forwardInput(message, w_param, l_param);
                // Windows' paste command for a window that is not an edit control: Ctrl+V or Shift+Insert, as a
                // browser reads it for a page. The key itself was forwarded first.
                if (isPasteCommand(w_param)) {
                    window.requestPaste();
                }
                return 0;
            },
            WM_DROPFILES => {
                // A batch of files dropped on the window: kept for the loop, which reads them between frames and
                // then lets the system free the batch. A batch still unread is freed first.
                if (window.pending_drop) |unread| {
                    DragFinish(unread);
                }
                window.pending_drop = @ptrFromInt(w_param);
                return 0;
            },
            WM_KILLFOCUS => {
                // A lock ends when focus leaves, on every platform: before the focus change is reported.
                window.releasePointerLock();
                window.forwardInput(message, w_param, l_param);
                return 0;
            },
            WM_INPUT => {
                if (window.is_pointer_locked) {
                    window.forwardRawMotion(l_param);
                }
                // Windows frees the report's buffer in its own handling.
                return DefWindowProcW(handle, message, w_param, l_param);
            },
            WM_SETCURSOR => {
                // Over the client area the window chooses: none while locked, else the shape set; elsewhere - the
                // borders, the title bar - Windows does.
                const hit_test: usize = @as(usize, @bitCast(l_param)) & 0xffff;
                if (hit_test != HTCLIENT) {
                    return DefWindowProcW(handle, message, w_param, l_param);
                }
                _ = SetCursor(if (window.is_pointer_locked) null else window.shownCursor());
                return 1;
            },
            WM_MOVE => {
                if (window.is_pointer_locked) {
                    window.confinePointer();
                }
                return 0;
            },
            WM_MOUSEMOVE => {
                // A locked pointer's position stands still, as a browser holds it; its motion comes from raw input.
                if (window.is_pointer_locked) {
                    return 0;
                }
                if (!window.is_pointer_inside) {
                    window.is_pointer_inside = true;
                    var tracking: TRACKMOUSEEVENT = .{
                        .cbSize = @sizeOf(TRACKMOUSEEVENT),
                        .dwFlags = TME_LEAVE,
                        .hwndTrack = handle,
                        .dwHoverTime = 0,
                    };
                    _ = TrackMouseEvent(&tracking);
                    window.forwardInput(message_pointer_entered, 0, 0);
                }
                window.forwardInput(message, w_param, l_param);
                return 0;
            },
            WM_MOUSELEAVE => {
                window.is_pointer_inside = false;
                window.forwardInput(message, w_param, l_param);
                return 0;
            },
            WM_SYSKEYDOWN, WM_SYSKEYUP => {
                // Alt combinations still reach Windows' own handling: Alt+F4 closes the window, Alt+Space opens
                // its menu.
                window.forwardInput(message, w_param, l_param);
                return DefWindowProcW(handle, message, w_param, l_param);
            },
            WM_SYSCOMMAND => {
                // The menu key: Alt alone or F10 (no character), or Alt with a character. The window has no menu, so
                // Windows would enter menu mode - stalling the frame loop until the next key - or, finding no menu
                // item for the character, beep (Alt+Enter, the usual fullscreen key, included). Only Alt+Space, which
                // opens the window's own menu, goes on.
                // Windows keeps the low four bits of a system command for itself; the command is the rest.
                const command: WPARAM = w_param & 0xfff0;
                const opens_window_menu: bool = l_param == ' ';
                if (command == SC_KEYMENU and !opens_window_menu) {
                    return 0;
                }
                return DefWindowProcW(handle, message, w_param, l_param);
            },
            WM_LBUTTONDOWN, WM_RBUTTONDOWN, WM_MBUTTONDOWN, WM_XBUTTONDOWN => {
                // Captured, a drag that leaves the window still reports its moves and its release.
                _ = SetCapture(handle);
                window.forwardInput(message, w_param, l_param);
                // An X button message handled returns TRUE; the others, 0.
                return @intFromBool(message == WM_XBUTTONDOWN);
            },
            WM_LBUTTONUP, WM_RBUTTONUP, WM_MBUTTONUP, WM_XBUTTONUP => {
                window.forwardInput(message, w_param, l_param);
                // The parameter holds the buttons still down after this release; with none, the capture ends.
                const all_buttons: WPARAM = MK_LBUTTON | MK_RBUTTON | MK_MBUTTON | MK_XBUTTON1 | MK_XBUTTON2;
                const buttons_still_down: WPARAM = w_param & all_buttons;
                if (buttons_still_down == 0) {
                    _ = ReleaseCapture();
                }
                return @intFromBool(message == WM_XBUTTONUP);
            },
            else => return DefWindowProcW(handle, message, w_param, l_param),
        }
    }
};
