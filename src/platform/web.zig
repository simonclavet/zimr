//! src/platform/web.zig - the browser's platform: the contract's requests (`contract.zig`), carried out through the
//! bridge's DOM functions (`web.zig`'s `dom`).
//!
//! A request the browser can carry out but the bridge does not reach yet refuses, naming what is missing. Fullscreen
//! and pointer lock are requested here; their outcomes become events when the bridge reports them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const contract = @import("contract.zig");
const web = @import("../web.zig");
const types = @import("../types.zig");
const dom = web.dom;
const Size = contract.Size;
const Cursor = contract.Cursor;
const TextInputOptions = contract.TextInputOptions;
const TextInputArea = contract.TextInputArea;
const AudioFormat = contract.AudioFormat;
const AudioOutputKind = contract.AudioOutputKind;

/// How this platform's output gets its frames (`contract.AudioOutputKind`), pushed for now: the browser's output
/// still queues blocks the mixer renders ahead.
pub const audio_output_kind: AudioOutputKind = .push;
const GamepadSlot = contract.GamepadSlot;
const Gamepad = contract.Gamepad;
const Rumble = contract.Rumble;

/// The browser's console.
pub fn log(level: std.log.Level, text: []const u8) void {
    const dom_level: dom.LogLevel = switch (level) {
        .debug => .debug,
        .info => .info,
        .warn => .warn,
        .err => .err,
    };
    dom.log(dom_level, text);
}

/// `performance.now()`, in nanoseconds: milliseconds since the page loaded, with a fraction.
pub fn now() u64 {
    return @trunc(dom.now_ms() * 1_000_000.0);
}

/// The canvas's size in CSS pixels, and `devicePixelRatio`.
pub fn size() Size {
    return .{
        .width = @floatFromInt(dom.canvas_css_width()),
        .height = @floatFromInt(dom.canvas_css_height()),
        .scale = dom.get_dpi_scale(),
    };
}

/// `document.title`.
pub fn setTitle(title: []const u8) void {
    dom.set_title(title);
}

/// The canvas made fullscreen, or the document left fullscreen - which the browser grants only during a user gesture.
pub fn requestFullscreen(on: bool) void {
    if (dom.is_fullscreen() != on) {
        dom.toggle_fullscreen();
    }
}

/// The canvas's CSS cursor. The bridge's table names the engine's cursors (`types.MouseCursor`), which hold no wait
/// cursor: `wait` shows the default.
pub fn setCursor(cursor: Cursor) void {
    if (cursor == .hidden) {
        dom.set_cursor_style(1);
        return;
    }
    dom.set_cursor_style(0);
    const engine_cursor: types.MouseCursor = switch (cursor) {
        // `hidden` returned above; `wait` has no CSS cursor in the bridge's table.
        .default, .wait, .hidden => .default,
        .text => .ibeam,
        .pointer => .pointing_hand,
        .crosshair => .crosshair,
        .move => .resize_all,
        .resize_horizontal => .resize_ew,
        .resize_vertical => .resize_ns,
        .resize_diagonal_down => .resize_nwse,
        .resize_diagonal_up => .resize_nesw,
        .not_allowed => .not_allowed,
    };
    dom.set_mouse_cursor(@intCast(@backingInt(engine_cursor)));
}

pub fn requestPointerLock() void {
    dom.request_pointer_lock();
}

pub fn releasePointerLock() void {
    dom.exit_pointer_lock();
}

/// The Screen Wake Lock API (`navigator.wakeLock`), asked again each time the page is shown: the browser releases a
/// lock whenever the page is hidden. A browser without the API keeps the screen as it would.
pub fn keepAwake(on: bool) void {
    dom.keep_awake(on);
}

/// In the browser a text field's own element takes the text - the bridge's overlay `<input>` or `<textarea>`, which
/// the fields show, place and hide themselves (`web.dom.show_overlay_input`) - and the browser runs its input methods
/// for that element, placing their windows itself: the three requests have nothing to do here.
pub fn startTextInput(options: TextInputOptions) void {
    _ = options;
}

pub fn setTextInputArea(area: TextInputArea) void {
    _ = area;
}

pub fn stopTextInput() void {}

/// `navigator.clipboard.writeText`, best effort: the browser may refuse without a user gesture.
pub fn setClipboardText(text: []const u8) void {
    dom.set_clipboard_text(text);
}

/// The clipboard's text, read with `navigator.clipboard.readText` and delivered as a `paste` event. The browser's
/// own paste command (Ctrl+V) needs no request: the bridge reports the page's `paste` event as it comes.
pub fn requestPaste() void {
    dom.request_paste();
}

/// `window.open`, in a new tab.
pub fn openUrl(url: []const u8) void {
    dom.open_url(url);
}

/// The value saved under `key` in `localStorage`, read into `buffer`: null when there is none, when storage is
/// unavailable, or when the value does not fit. `localStorage` holds text, so values are kept base64-encoded - any
/// bytes come back as they went in; the decoding's scratch comes from the wasm page allocator, freed before returning.
pub fn loadValue(key: []const u8, buffer: []u8) ?[]u8 {
    const scratch: Allocator = std.heap.wasm_allocator;
    const decoded: []u8 = (dom.persistence_load_bytes(scratch, key) catch return null) orelse return null;
    defer scratch.free(decoded);
    if (decoded.len > buffer.len) {
        return null;
    }
    @memcpy(buffer[0..decoded.len], decoded);
    return buffer[0..decoded.len];
}

/// Saves `bytes` under `key` in `localStorage`, base64-encoded (`loadValue`). A failure - storage full or
/// unavailable - is logged, and the value is not kept.
pub fn saveValue(key: []const u8, bytes: []const u8) void {
    const status: i32 = dom.persistence_save_bytes(std.heap.wasm_allocator, key, bytes) catch -1;
    if (status != 0) {
        log(.warn, "web platform: a value could not be saved (storage full or unavailable)");
    }
}

pub fn removeValue(key: []const u8) void {
    _ = dom.persistence_remove(key);
}

/// The page's sound output: an AudioWorklet playing the blocks the mixer queues (`bridge.zig`'s
/// `audio_output_program`). The audio context is opened at the rate asked for, which browsers resample from to their
/// device's; it grants that rate, or 0 when the browser has no AudioWorklet - the mixer then logs the difference, and
/// its blocks are dropped.
pub fn startAudio(wanted: AudioFormat) AudioFormat {
    const granted_rate: u32 = web.dom.audio_output_start(wanted.sample_rate, wanted.channels);
    return .{ .sample_rate = granted_rate, .channels = wanted.channels };
}

/// Posts a block to the output's processor - or, before the processor can play, holds it (draining at the real rate).
pub fn queueAudio(samples: []const f32) void {
    web.dom.audio_output_queue(samples);
}

/// Frames posted and not yet reported played, or held and not yet drained.
pub fn queuedAudioFrames() u32 {
    return web.dom.audio_output_queued_frames();
}

/// Adds samples onto the frames queued and not yet played, aligned to the queue's end: in the worklet by a message,
/// or on the main thread for the script processor and for blocks still held.
pub fn mixIntoQueuedAudio(samples: []const f32) void {
    web.dom.audio_output_mix_into_queued(samples);
}

/// Closes the audio context.
pub fn stopAudio() void {
    web.dom.audio_output_stop();
}

/// The gamepad in a slot, as the browser reads it (`navigator.getGamepads()`): its buttons in the standard gamepad's
/// order - the contract's - and its axes; null for an empty slot. A browser shows a page its gamepads only once a
/// button is pressed while the page has the focus.
pub fn gamepad(slot: GamepadSlot) ?Gamepad {
    const button_count: usize = @typeInfo(contract.GamepadButton).@"enum".field_names.len;
    const axis_count: usize = @typeInfo(contract.GamepadAxis).@"enum".field_names.len;
    var values: [21]f32 = undefined;
    comptime {
        if (button_count + axis_count != 21) {
            @compileError("the page writes 17 buttons and 4 axes");
        }
    }
    if (dom.gamepad_state(slot, &values) == 0) {
        return null;
    }
    var read: Gamepad = .{ .buttons = .initFill(0), .axes = .initFill(0) };
    for (0..button_count) |index| {
        read.buttons.set(@fromBackingInt(@intCast(index)), values[index]);
    }
    for (0..axis_count) |index| {
        read.axes.set(@fromBackingInt(@intCast(index)), values[button_count + index]);
    }
    return read;
}

/// A dual-rumble effect: the heavy motor (`low`) on the gamepad's left, the light one (`high`) on its right, as the
/// standard gamepad's `vibrationActuator` names them. Nothing happens on a gamepad without haptics.
pub fn setGamepadRumble(slot: GamepadSlot, rumble: Rumble) void {
    dom.gamepad_vibrate(slot, rumble.low, rumble.high, rumble.milliseconds);
}

// The requests written here, compiled in every build that runs on this platform - so a mistake in one fails the build
// before the engine calls it. A refusal cannot be named: compiling it is the refusal.
comptime {
    _ = &now;
    _ = &size;
    _ = &setTitle;
    _ = &requestFullscreen;
    _ = &setCursor;
    _ = &requestPointerLock;
    _ = &releasePointerLock;
    _ = &setClipboardText;
    _ = &openUrl;
    _ = &loadValue;
    _ = &saveValue;
    _ = &removeValue;
    _ = &setGamepadRumble;
    _ = &log;
}

/// The browser's queue of files the person picked or dropped on the page (`web.userfile`).
pub fn pendingFileCount() u32 {
    return web.userfile.pendingCount();
}

pub fn nextFileSize() u32 {
    return web.userfile.nextSize();
}

pub fn nextFileName(out: []u8) u32 {
    return web.userfile.nextName(out);
}

pub fn readNextFile(out: []u8) u32 {
    return web.userfile.readNext(out);
}

pub fn discardNextFile() void {
    web.userfile.discardNext();
}

/// An invisible file input of the page over the app's Load button: the browser opens its picker only from the
/// person's own press on an element of the page. The area's app pixels are the page's CSS pixels.
pub fn setFilePickerArea(area: contract.ButtonArea, accept: []const u8) void {
    web.userfile.setPickerRect(area.x, area.y, area.width, area.height, accept);
}

pub fn hideFilePicker() void {
    web.userfile.hidePicker();
}

/// The file an invisible link of the page over the app's Save button downloads, for the same reason.
pub fn offerFile(bytes: []const u8, name: []const u8) void {
    web.userfile.offerDownload(bytes, name);
}

pub fn setSaveArea(area: contract.ButtonArea) void {
    web.userfile.setSaveRect(area.x, area.y, area.width, area.height);
}

pub fn hideSave() void {
    web.userfile.hideSave();
}

/// The page's WebSockets (`web.ws`).
pub fn openSocket(url: []const u8) u32 {
    return web.ws.open(url);
}

pub fn socketState(handle: u32) contract.SocketState {
    comptime contract.requireSameValues(web.ws.State, contract.SocketState);
    return @fromBackingInt(@intCast(@backingInt(web.ws.state(handle))));
}

pub fn sendSocket(handle: u32, bytes: []const u8) void {
    web.ws.send(handle, bytes);
}

pub fn pollSocket(handle: u32, out: []u8) ?[]const u8 {
    return web.ws.poll(handle, out);
}

pub fn closeSocket(handle: u32) void {
    web.ws.close(handle);
}

/// The page's own origin as a WebSocket address: the server that served the page.
pub fn socketOriginUrl(out: []u8) []const u8 {
    return web.ws.originUrl(out);
}

pub fn epochMillis() f64 {
    return web.dom.epochMillis();
}

/// One monitor: the screen the page is shown on - its size in CSS pixels, at the device pixel ratio. A page sees no
/// other monitor, and cannot tell the refresh rate.
pub fn monitorCount() u32 {
    return 1;
}

pub fn monitor(index: u32) ?contract.Monitor {
    if (index != 0) {
        return null;
    }
    var described: contract.Monitor = .{
        .x = 0,
        .y = 0,
        .width = dom.screen_width(),
        .height = dom.screen_height(),
        .scale = dom.get_dpi_scale(),
        .refresh_hz = 0,
        .is_primary = true,
    };
    described.setName("screen");
    return described;
}

pub fn currentMonitor() u32 {
    return 0;
}

// A page lives inside its browser's window, which only the person moves and sizes: the window requests refuse, each
// with its reason, so that code calling one for the web does not compile.

pub fn showWindow(show: contract.WindowShow) void {
    _ = show;
    @compileError("web platform: a page cannot minimize or maximize its browser's window");
}

pub fn focusWindow() void {
    @compileError("web platform: a page cannot bring its browser's window to the front");
}

pub fn setWindowPosition(monitor_index: u32, x: f32, y: f32) void {
    _ = monitor_index;
    _ = x;
    _ = y;
    @compileError("web platform: a page cannot move its browser's window");
}

pub fn setWindowSizeLimits(limits: contract.SizeLimits) void {
    _ = limits;
    @compileError("web platform: a page cannot limit its browser window's size");
}

/// A key's label: the US layout's for now. A page reads the person's layout only in Chromium, and only through a
/// promise (`navigator.keyboard.getLayoutMap`), a step still to take.
pub fn keyName(key: contract.KeyboardKey, buffer: []u8) ?[]const u8 {
    return contract.usKeyName(key, buffer);
}
