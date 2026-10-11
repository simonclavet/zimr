//! src/platform/template.zig - where a new platform starts: every request of the contract (`contract.zig`), each
//! declaring itself not yet written.
//!
//! Copy this file for the new platform and replace each refusal with the system's own calls, as the contract's
//! documentation of each request describes. The copy keeps the contract from the start - names and types are what
//! `requirePlatform` checks - and until a request is written, the build fails only where the engine calls it, naming
//! it. A request the system cannot carry out keeps a refusal for good, its message changed to the reason.

const std = @import("std");
const contract = @import("contract.zig");
const Size = contract.Size;
const Cursor = contract.Cursor;
const TextInputOptions = contract.TextInputOptions;
const TextInputArea = contract.TextInputArea;
const AudioFormat = contract.AudioFormat;
const AudioOutputKind = contract.AudioOutputKind;
const AudioRenderCallback = contract.AudioRenderCallback;

/// How this platform's output gets its frames (`contract.AudioOutputKind`): a new platform's device asks for them,
/// and the output calls the renderer (`startAudioPull`).
pub const audio_output_kind: AudioOutputKind = .pull_on_audio_thread;
const GamepadSlot = contract.GamepadSlot;
const Gamepad = contract.Gamepad;
const Rumble = contract.Rumble;

pub fn now() u64 {
    @compileError("template platform: `now` is not written");
}

pub fn size() Size {
    @compileError("template platform: `size` is not written");
}

pub fn setTitle(title: []const u8) void {
    _ = title;
    @compileError("template platform: `setTitle` is not written");
}

pub fn requestFullscreen(on: bool) void {
    _ = on;
    @compileError("template platform: `requestFullscreen` is not written");
}

pub fn setCursor(cursor: Cursor) void {
    _ = cursor;
    @compileError("template platform: `setCursor` is not written");
}

pub fn requestPointerLock() void {
    @compileError("template platform: `requestPointerLock` is not written");
}

pub fn releasePointerLock() void {
    @compileError("template platform: `releasePointerLock` is not written");
}

pub fn keepAwake(on: bool) void {
    _ = on;
    @compileError("template platform: `keepAwake` is not written");
}

pub fn startTextInput(options: TextInputOptions) void {
    _ = options;
    @compileError("template platform: `startTextInput` is not written");
}

pub fn setTextInputArea(area: TextInputArea) void {
    _ = area;
    @compileError("template platform: `setTextInputArea` is not written");
}

pub fn stopTextInput() void {
    @compileError("template platform: `stopTextInput` is not written");
}

pub fn setClipboardText(text: []const u8) void {
    _ = text;
    @compileError("template platform: `setClipboardText` is not written");
}

pub fn requestPaste() void {
    @compileError("template platform: `requestPaste` is not written");
}

pub fn openUrl(url: []const u8) void {
    _ = url;
    @compileError("template platform: `openUrl` is not written");
}

pub fn loadValue(key: []const u8, buffer: []u8) ?[]u8 {
    _ = key;
    _ = buffer;
    @compileError("template platform: `loadValue` is not written");
}

pub fn saveValue(key: []const u8, bytes: []const u8) void {
    _ = key;
    _ = bytes;
    @compileError("template platform: `saveValue` is not written");
}

pub fn removeValue(key: []const u8) void {
    _ = key;
    @compileError("template platform: `removeValue` is not written");
}

pub fn startAudio(wanted: AudioFormat) AudioFormat {
    _ = wanted;
    @compileError("template platform: `startAudio` is not written");
}

pub fn startAudioPull(wanted: AudioFormat, render_callback: AudioRenderCallback) AudioFormat {
    _ = wanted;
    _ = render_callback;
    @compileError("template platform: `startAudioPull` is not written");
}

pub fn queueAudio(samples: []const f32) void {
    _ = samples;
    @compileError("template platform: `queueAudio` is not written");
}

pub fn queuedAudioFrames() u32 {
    @compileError("template platform: `queuedAudioFrames` is not written");
}

pub fn mixIntoQueuedAudio(samples: []const f32) void {
    _ = samples;
    @compileError("template platform: `mixIntoQueuedAudio` is not written");
}

pub fn stopAudio() void {
    @compileError("template platform: `stopAudio` is not written");
}

pub fn gamepad(slot: GamepadSlot) ?Gamepad {
    _ = slot;
    @compileError("template platform: `gamepad` is not written");
}

pub fn setGamepadRumble(slot: GamepadSlot, rumble: Rumble) void {
    _ = slot;
    _ = rumble;
    @compileError("template platform: `setGamepadRumble` is not written");
}

pub fn log(level: std.log.Level, text: []const u8) void {
    _ = level;
    _ = text;
    @compileError("template platform: `log` is not written");
}

test "the template platform keeps the contract" {
    comptime contract.requirePlatform(@This());
}

test {
    // The contract's own tests run with the template's.
    _ = contract;
}

pub fn pendingFileCount() u32 {
    @compileError("template platform: `pendingFileCount` is not written");
}

pub fn nextFileSize() u32 {
    @compileError("template platform: `nextFileSize` is not written");
}

pub fn nextFileName(out: []u8) u32 {
    _ = out;
    @compileError("template platform: `nextFileName` is not written");
}

pub fn readNextFile(out: []u8) u32 {
    _ = out;
    @compileError("template platform: `readNextFile` is not written");
}

pub fn discardNextFile() void {
    @compileError("template platform: `discardNextFile` is not written");
}

pub fn setFilePickerArea(area: contract.ButtonArea, accept: []const u8) void {
    _ = area;
    _ = accept;
    @compileError("template platform: `setFilePickerArea` is not written");
}

pub fn hideFilePicker() void {
    @compileError("template platform: `hideFilePicker` is not written");
}

pub fn offerFile(bytes: []const u8, name: []const u8) void {
    _ = bytes;
    _ = name;
    @compileError("template platform: `offerFile` is not written");
}

pub fn setSaveArea(area: contract.ButtonArea) void {
    _ = area;
    @compileError("template platform: `setSaveArea` is not written");
}

pub fn hideSave() void {
    @compileError("template platform: `hideSave` is not written");
}

pub fn openSocket(url: []const u8) u32 {
    _ = url;
    @compileError("template platform: `openSocket` is not written");
}

pub fn socketState(handle: u32) contract.SocketState {
    _ = handle;
    @compileError("template platform: `socketState` is not written");
}

pub fn sendSocket(handle: u32, bytes: []const u8) void {
    _ = handle;
    _ = bytes;
    @compileError("template platform: `sendSocket` is not written");
}

pub fn pollSocket(handle: u32, out: []u8) ?[]const u8 {
    _ = handle;
    _ = out;
    @compileError("template platform: `pollSocket` is not written");
}

pub fn closeSocket(handle: u32) void {
    _ = handle;
    @compileError("template platform: `closeSocket` is not written");
}

pub fn socketOriginUrl(out: []u8) []const u8 {
    _ = out;
    @compileError("template platform: `socketOriginUrl` is not written");
}

pub fn epochMillis() f64 {
    @compileError("template platform: `epochMillis` is not written");
}

pub fn monitorCount() u32 {
    @compileError("template platform: `monitorCount` is not written");
}

pub fn monitor(index: u32) ?contract.Monitor {
    _ = index;
    @compileError("template platform: `monitor` is not written");
}

pub fn currentMonitor() u32 {
    @compileError("template platform: `currentMonitor` is not written");
}

pub fn showWindow(show: contract.WindowShow) void {
    _ = show;
    @compileError("template platform: `showWindow` is not written");
}

pub fn focusWindow() void {
    @compileError("template platform: `focusWindow` is not written");
}

pub fn setWindowPosition(monitor_index: u32, x: f32, y: f32) void {
    _ = monitor_index;
    _ = x;
    _ = y;
    @compileError("template platform: `setWindowPosition` is not written");
}

pub fn setWindowSizeLimits(limits: contract.SizeLimits) void {
    _ = limits;
    @compileError("template platform: `setWindowSizeLimits` is not written");
}

pub fn keyName(key: contract.KeyboardKey, buffer: []u8) ?[]const u8 {
    _ = key;
    _ = buffer;
    @compileError("template platform: `keyName` is not written");
}
