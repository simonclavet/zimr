//! src/platform/linux.zig - the Linux platform: the contract's requests (`contract.zig`), carried out with the X11
//! window `native_loop.zig` owns (`x11.zig`) and the system's own calls, through the C library.
//!
//! Written in stages (linux_port_plan.md). This is stage L3's: the window - its size, title, fullscreen, focus and size
//! limits - the keyboard and the mouse, the clocks, saved values, sockets, and the queue of files. A request of a later
//! stage refuses by name at run time, once (`refuse`, as the unwritten platform's do), and answers as a platform with
//! nothing would:
//!
//!     L4   cursors, pointer lock (refused by the window itself until then), the window shown or placed on a monitor,
//!          keys' names in the person's layout (US names until then), the input method
//!     L5   the clipboard, web addresses opened, the screen kept awake, the monitors (until then one: the X screen)
//!     L6   sound, through ALSA
//!     L7   gamepads, through evdev (until then a script's only)
//!     L8   files dropped on the window, the file dialogs
//!
//! X11 has no composition events: an input method draws its own unfinished text (stage L4), so no `composition` event
//! comes from this platform.

const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const contract = @import("contract.zig");
const console = @import("console.zig");
const native_websocket = @import("../net_core.zig").native_websocket;
const native_loop = @import("../native_loop.zig");
const native_os = @import("../native_os.zig");
const native_window = @import("../native_window.zig");
const zm = @import("zm");
const float = zm.float;
const Size = contract.Size;
const Cursor = contract.Cursor;
const TextInputOptions = contract.TextInputOptions;
const TextInputArea = contract.TextInputArea;
const AudioFormat = contract.AudioFormat;
const AudioOutputKind = contract.AudioOutputKind;
const AudioRenderCallback = contract.AudioRenderCallback;
const GamepadSlot = contract.GamepadSlot;
const Gamepad = contract.Gamepad;
const Rumble = contract.Rumble;

/// How this platform's output gets its frames (`contract.AudioOutputKind`): ALSA's render thread will ask the renderer
/// for them as the device needs them (stage L6).
pub const audio_output_kind: AudioOutputKind = .pull_on_audio_thread;

/// Says, once for each request, that it is not written yet: a request called every frame says it at its first call
/// only. Each request instantiates this function with its own name, and so with its own flag.
fn refuse(comptime request: []const u8) void {
    const Said = struct {
        // lint:off module-var: once for each request - whether its refusal was said
        var is_said: bool = false;
    };
    if (Said.is_said) {
        return;
    }
    Said.is_said = true;
    var message_buffer: [160]u8 = undefined;
    const message: []const u8 = bufPrint(
        &message_buffer,
        "the Linux platform's `{s}` is not written yet",
        .{request},
    ) catch request;
    console.log(.warn, message);
}

/// The monotonic clock (`CLOCK_MONOTONIC`), in nanoseconds.
pub fn now() u64 {
    return @trunc(native_os.monotonicMilliseconds() * 1_000_000.0);
}

/// The window's drawing area, in logical pixels, and its scale.
pub fn size() Size {
    return native_loop.size();
}

/// The title bar's text (`x11.Window.setTitle`).
pub fn setTitle(title: []const u8) void {
    native_loop.setTitle(title);
}

/// Fullscreen through the window manager (`x11.Window.setFullscreen`); the outcome arrives as an event.
pub fn requestFullscreen(on: bool) void {
    native_loop.setFullscreen(on);
}

pub fn setCursor(cursor: Cursor) void {
    _ = cursor;
    refuse("setCursor");
}

/// The window answers the lock itself: refused, until stage L4 writes it.
pub fn requestPointerLock() void {
    native_loop.requestPointerLock();
}

pub fn releasePointerLock() void {
    native_loop.releasePointerLock();
}

pub fn keepAwake(on: bool) void {
    _ = on;
    refuse("keepAwake");
}

/// Text input on (`native_loop.startTextInput`) - its input method only for a field that is not a password, as the
/// contract's options ask of a desktop. Text arrives either way, through `XLookupString`.
pub fn startTextInput(options: TextInputOptions) void {
    const is_password: bool = options.kind == .password or options.kind == .numeric_password;
    native_loop.startTextInput(!is_password);
}

/// Nothing to place: an X11 input method places its own window, at the pointer or the focus.
pub fn setTextInputArea(area: TextInputArea) void {
    _ = area;
}

pub fn stopTextInput() void {
    native_loop.stopTextInput();
}

pub fn setClipboardText(text: []const u8) void {
    _ = text;
    refuse("setClipboardText");
}

pub fn requestPaste() void {
    refuse("requestPaste");
}

pub fn openUrl(url: []const u8) void {
    _ = url;
    refuse("openUrl");
}

/// Saved values: files under `$XDG_DATA_HOME/zimr/<program>/`, or `~/.local/share/zimr/<program>/` (`native_os`).
pub fn loadValue(key: []const u8, buffer: []u8) ?[]u8 {
    return native_os.loadValue(key, buffer);
}

pub fn saveValue(key: []const u8, bytes: []const u8) void {
    native_os.saveValue(key, bytes);
}

pub fn removeValue(key: []const u8) void {
    native_os.removeValue(key);
}

/// Sound comes with stage L6: until then the format is granted as asked, and nothing plays - the engine's mixer starts
/// as it would.
pub fn startAudioPull(wanted: AudioFormat, render_callback: AudioRenderCallback) AudioFormat {
    _ = render_callback;
    refuse("startAudioPull");
    return wanted;
}

/// No output to stop before stage L6.
pub fn stopAudio() void {}

/// The clock sound is timed by: the system's monotonic clock, as the main thread and an audio thread both read it.
pub fn audioClockMilliseconds() f64 {
    return native_os.monotonicMilliseconds();
}

pub fn audioOutputLatencyMilliseconds() f64 {
    return 0;
}

pub fn audioOutputName() []const u8 {
    return "none (sound on Linux is not written yet)";
}

/// A script's gamepad in its slot (`native_loop.scriptedGamepad`); the system's own gamepads come with stage L7.
pub fn gamepad(slot: GamepadSlot) ?Gamepad {
    if (native_loop.scriptedGamepad(slot)) |scripted_slot| {
        return scripted_slot.scripted;
    }
    return null;
}

pub fn setGamepadRumble(slot: GamepadSlot, rumble: Rumble) void {
    _ = slot;
    _ = rumble;
    refuse("setGamepadRumble");
}

/// Standard error, each line prefixed with its level (`console.zig`).
pub const log = console.log;

// The requests written here, compiled in every build that runs on this platform - so a mistake in one fails the build
// before the engine calls it.
comptime {
    _ = &now;
    _ = &size;
    _ = &log;
}

/// The files the person hands the app wait in the loop's queue (`native_loop`); on Linux nothing fills it before stage
/// L8 - drops and dialogs - and a press on a Load or Save button is said and dropped (`native_loop.dropDialogRequest`).
pub fn pendingFileCount() u32 {
    return native_loop.pendingFileCount();
}

pub fn nextFileSize() u32 {
    return native_loop.nextFileSize();
}

pub fn nextFileName(out: []u8) u32 {
    return native_loop.nextFileName(out);
}

pub fn readNextFile(out: []u8) u32 {
    return native_loop.readNextFile(out);
}

pub fn discardNextFile() void {
    native_loop.discardNextFile();
}

pub fn setFilePickerArea(area: contract.ButtonArea, accept: []const u8) void {
    native_loop.setFilePickerArea(area, accept);
}

pub fn hideFilePicker() void {
    native_loop.hideFilePicker();
}

pub fn offerFile(bytes: []const u8, name: []const u8) void {
    native_loop.offerFile(bytes, name);
}

pub fn setSaveArea(area: contract.ButtonArea) void {
    native_loop.setSaveArea(area);
}

pub fn hideSave() void {
    native_loop.hideSave();
}

/// WebSockets through the native client (`net_core.native_websocket`), which speaks the protocol itself.
pub fn openSocket(url: []const u8) u32 {
    return native_websocket.open(url);
}

pub fn socketState(handle: u32) contract.SocketState {
    comptime contract.requireSameValues(native_websocket.State, contract.SocketState);
    return @fromBackingInt(@intCast(@backingInt(native_websocket.state(handle))));
}

pub fn sendSocket(handle: u32, bytes: []const u8) void {
    native_websocket.send(handle, bytes);
}

pub fn pollSocket(handle: u32, out: []u8) ?[]const u8 {
    return native_websocket.poll(handle, out);
}

pub fn closeSocket(handle: u32) void {
    native_websocket.close(handle);
}

/// A native app came from no server, so its origin is the signaling server on this machine, at the port both
/// multiplayer servers listen on unless told otherwise (`zig build signal-server`) - as on Windows.
pub fn socketOriginUrl(out: []u8) []const u8 {
    const local_server: []const u8 = "ws://127.0.0.1:7777";
    // An address cut short would lead elsewhere - another port - so a buffer too small for it gets none.
    if (out.len < local_server.len) {
        return out[0..0];
    }
    @memcpy(out[0..local_server.len], local_server);
    return out[0..local_server.len];
}

/// The wall clock (`CLOCK_REALTIME`), in milliseconds since the Unix epoch.
pub fn epochMillis() f64 {
    var wall_time: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &wall_time);
    const seconds: f64 = @floatFromInt(wall_time.sec);
    const nanoseconds: f64 = @floatFromInt(wall_time.nsec);
    return seconds * 1000.0 + nanoseconds / 1_000_000.0;
}

/// The monotonic clock (`CLOCK_MONOTONIC`), in milliseconds.
pub fn monotonicMilliseconds() f64 {
    return native_os.monotonicMilliseconds();
}

/// One monitor until stage L5 lists them (XRandR): the X screen, the whole desktop.
pub fn monitorCount() u32 {
    return 1;
}

/// The X screen as the one monitor: its size in logical pixels at the window's scale, its refresh rate unknown (0).
pub fn monitor(index: u32) ?contract.Monitor {
    if (index != 0) {
        return null;
    }
    const window: *native_window.Window = native_loop.theWindow();
    const window_scale: f32 = window.scale();
    const screen_width: c_int = window.xlib.XDisplayWidth(window.display, window.screen);
    const screen_height: c_int = window.xlib.XDisplayHeight(window.display, window.screen);
    var described: contract.Monitor = .{
        .x = 0,
        .y = 0,
        .width = float(screen_width) / window_scale,
        .height = float(screen_height) / window_scale,
        .scale = window_scale,
        .refresh_hz = 0,
        .is_primary = true,
    };
    described.setName("X screen");
    return described;
}

pub fn currentMonitor() u32 {
    return 0;
}

pub fn showWindow(show: contract.WindowShow) void {
    _ = show;
    refuse("showWindow");
}

/// Asks to bring the window to the front (`x11.Window.bringToFront`).
pub fn focusWindow() void {
    native_loop.focusWindow();
}

pub fn setWindowPosition(monitor_index: u32, x: f32, y: f32) void {
    _ = monitor_index;
    _ = x;
    _ = y;
    refuse("setWindowPosition");
}

/// The drawing area's size limits, handed to the window manager and applied at once (`x11.Window.applySizeLimits`).
pub fn setWindowSizeLimits(limits: contract.SizeLimits) void {
    native_loop.setWindowSizeLimits(limits);
}

/// The app asks to end (`native_loop.requestQuit`): the window closes as if its close button were pressed.
pub fn requestQuit() void {
    native_loop.requestQuit();
}

/// A key's US name (`contract.usKeyName`) until stage L4 reads the person's own layout.
pub fn keyName(key: contract.KeyboardKey, buffer: []u8) ?[]const u8 {
    return contract.usKeyName(key, buffer);
}
