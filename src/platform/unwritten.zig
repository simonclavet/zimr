//! src/platform/unwritten.zig - a native platform not yet written: Linux, macOS and Android, until each has its own.
//!
//! Every request of the contract (`contract.zig`) is here, each refused by name at run time: it says once that it is
//! not written (`refuse`) and answers as a platform with nothing yet would - nothing, zero, false, null, an empty text,
//! an empty window, a closed socket. A build for these systems therefore compiles the whole engine, as `zig build
//! platforms-check` does for every platform, so that code which compiles only for Windows or the browser is found the
//! day it is written rather than when a port starts. `template.zig` refuses each request at compile time instead,
//! where the engine calls it, for a platform being written request by request; this file refuses at run time because
//! its purpose is the build. Nothing runs on it: the window and its loop are refused too (`native_loop.zig`).
//!
//! A port starts by copying this file into its own (`linux.zig`, say), pointing `platform.current` at it, and
//! replacing each refusal with the system's own calls, as the contract documents each request.

const std = @import("std");
const builtin = @import("builtin");
const bufPrint = std.fmt.bufPrint;
const contract = @import("contract.zig");
const console = @import("console.zig");
const native_os = @import("../native_os.zig");
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

/// How this platform's output would get its frames (`contract.AudioOutputKind`): a native device asks for them.
pub const audio_output_kind: AudioOutputKind = .pull_on_audio_thread;

/// The system this build is for, as the refusals name it: Android is Linux's kernel with its own ABI.
const system_name: []const u8 = if (builtin.target.abi.isAndroid()) "android" else @tagName(builtin.target.os.tag);

/// Says, once for each request, that it is not written: a request called every frame says it at its first call only.
/// Each request instantiates this function with its own name, and so with its own flag.
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
        "the {s} platform's `{s}` is not written",
        .{ system_name, request },
    ) catch request;
    console.log(.warn, message);
}

pub fn now() u64 {
    refuse("now");
    return 0;
}

pub fn size() Size {
    refuse("size");
    return .{ .width = 0, .height = 0, .scale = 1 };
}

pub fn setTitle(title: []const u8) void {
    _ = title;
    refuse("setTitle");
}

pub fn requestFullscreen(on: bool) void {
    _ = on;
    refuse("requestFullscreen");
}

pub fn setCursor(cursor: Cursor) void {
    _ = cursor;
    refuse("setCursor");
}

pub fn requestPointerLock() void {
    refuse("requestPointerLock");
}

pub fn releasePointerLock() void {
    refuse("releasePointerLock");
}

pub fn keepAwake(on: bool) void {
    _ = on;
    refuse("keepAwake");
}

pub fn startTextInput(options: TextInputOptions) void {
    _ = options;
    refuse("startTextInput");
}

pub fn setTextInputArea(area: TextInputArea) void {
    _ = area;
    refuse("setTextInputArea");
}

pub fn stopTextInput() void {
    refuse("stopTextInput");
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

// Saved values are written: files under the system's folder for each program, the same Zig on every native system
// (`native_os.zig`). Android's folder comes from its activity, so there they stay refused.
pub fn loadValue(key: []const u8, buffer: []u8) ?[]u8 {
    if (comptime builtin.target.abi.isAndroid()) {
        refuse("loadValue");
        return null;
    }
    return native_os.loadValue(key, buffer);
}

pub fn saveValue(key: []const u8, bytes: []const u8) void {
    if (comptime builtin.target.abi.isAndroid()) {
        refuse("saveValue");
        return;
    }
    native_os.saveValue(key, bytes);
}

pub fn removeValue(key: []const u8) void {
    if (comptime builtin.target.abi.isAndroid()) {
        refuse("removeValue");
        return;
    }
    native_os.removeValue(key);
}

pub fn startAudioPull(wanted: AudioFormat, render_callback: AudioRenderCallback) AudioFormat {
    _ = render_callback;
    refuse("startAudioPull");
    // Granted as asked: nothing plays, and the engine's mixer starts as it would.
    return wanted;
}

pub fn audioClockMilliseconds() f64 {
    refuse("audioClockMilliseconds");
    return 0;
}

pub fn audioOutputLatencyMilliseconds() f64 {
    refuse("audioOutputLatencyMilliseconds");
    return 0;
}

pub fn audioOutputName() []const u8 {
    refuse("audioOutputName");
    return "";
}

pub fn stopAudio() void {
    refuse("stopAudio");
}

pub fn gamepad(slot: GamepadSlot) ?Gamepad {
    _ = slot;
    refuse("gamepad");
    return null;
}

pub fn setGamepadRumble(slot: GamepadSlot, rumble: Rumble) void {
    _ = slot;
    _ = rumble;
    refuse("setGamepadRumble");
}

pub fn log(level: std.log.Level, text: []const u8) void {
    // The log works from the start: standard error, as on the other native platforms (`console.zig`).
    console.log(level, text);
}

pub fn pendingFileCount() u32 {
    refuse("pendingFileCount");
    return 0;
}

pub fn nextFileSize() u32 {
    refuse("nextFileSize");
    return 0;
}

pub fn nextFileName(out: []u8) u32 {
    _ = out;
    refuse("nextFileName");
    return 0;
}

pub fn readNextFile(out: []u8) u32 {
    _ = out;
    refuse("readNextFile");
    return 0;
}

pub fn discardNextFile() void {
    refuse("discardNextFile");
}

pub fn setFilePickerArea(area: contract.ButtonArea, accept: []const u8) void {
    _ = area;
    _ = accept;
    refuse("setFilePickerArea");
}

pub fn hideFilePicker() void {
    refuse("hideFilePicker");
}

pub fn offerFile(bytes: []const u8, name: []const u8) void {
    _ = bytes;
    _ = name;
    refuse("offerFile");
}

pub fn setSaveArea(area: contract.ButtonArea) void {
    _ = area;
    refuse("setSaveArea");
}

pub fn hideSave() void {
    refuse("hideSave");
}

pub fn openSocket(url: []const u8) u32 {
    _ = url;
    refuse("openSocket");
    return 0;
}

pub fn socketState(handle: u32) contract.SocketState {
    _ = handle;
    refuse("socketState");
    return .closed;
}

pub fn sendSocket(handle: u32, bytes: []const u8) void {
    _ = handle;
    _ = bytes;
    refuse("sendSocket");
}

pub fn pollSocket(handle: u32, out: []u8) ?[]const u8 {
    _ = handle;
    _ = out;
    refuse("pollSocket");
    return null;
}

pub fn closeSocket(handle: u32) void {
    _ = handle;
    refuse("closeSocket");
}

pub fn socketOriginUrl(out: []u8) []const u8 {
    _ = out;
    refuse("socketOriginUrl");
    return "";
}

pub fn epochMillis() f64 {
    refuse("epochMillis");
    return 0;
}

pub fn monotonicMilliseconds() f64 {
    refuse("monotonicMilliseconds");
    return 0;
}

pub fn monitorCount() u32 {
    refuse("monitorCount");
    return 0;
}

pub fn monitor(index: u32) ?contract.Monitor {
    _ = index;
    refuse("monitor");
    return null;
}

pub fn currentMonitor() u32 {
    refuse("currentMonitor");
    return 0;
}

pub fn showWindow(show: contract.WindowShow) void {
    _ = show;
    refuse("showWindow");
}

pub fn focusWindow() void {
    refuse("focusWindow");
}

pub fn setWindowPosition(monitor_index: u32, x: f32, y: f32) void {
    _ = monitor_index;
    _ = x;
    _ = y;
    refuse("setWindowPosition");
}

pub fn setWindowSizeLimits(limits: contract.SizeLimits) void {
    _ = limits;
    refuse("setWindowSizeLimits");
}

pub fn requestQuit() void {
    refuse("requestQuit");
}

pub fn keyName(key: contract.KeyboardKey, buffer: []u8) ?[]const u8 {
    _ = key;
    _ = buffer;
    refuse("keyName");
    return null;
}

test "the unwritten platform keeps the contract" {
    comptime contract.requirePlatform(@This());
}
