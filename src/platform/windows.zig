//! src/platform/windows.zig - the Windows platform: the contract's requests (`contract.zig`), carried out with the
//! window `native_loop.zig` owns and the system's own calls.
//!
//! Windows can carry out every request; a request that refuses names the call it is waiting for.

const std = @import("std");
const utf8ToUtf16LeStringLiteral = std.unicode.utf8ToUtf16LeStringLiteral;
const zeroes = std.mem.zeroes;
const asBytes = std.mem.asBytes;
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;
const endsWith = std.mem.endsWith;
const lastIndexOfScalar = std.mem.lastIndexOfScalar;
const bufPrint = std.fmt.bufPrint;
const indexOfScalar = std.mem.indexOfScalar;
const contract = @import("contract.zig");
const native_websocket = @import("../net_core.zig").native_websocket;
const console = @import("console.zig");
const native_loop = @import("../native_loop.zig");
const native_input = @import("../native_input.zig");
const native_os = @import("../native_os.zig");
const win32 = @import("../win32.zig");
const zm = @import("zm");
const float64 = zm.float64;
const Size = contract.Size;
const Cursor = contract.Cursor;
const TextInputOptions = contract.TextInputOptions;
const TextInputArea = contract.TextInputArea;
const AudioFormat = contract.AudioFormat;
const AudioOutputKind = contract.AudioOutputKind;
const AudioRenderCallback = contract.AudioRenderCallback;
const AudioRenderTiming = contract.AudioRenderTiming;

/// How this platform's output gets its frames (`contract.AudioOutputKind`): WASAPI's render thread asks the
/// renderer for exactly the frames the device's buffer has room for, as the device signals it (`startAudioPull`).
pub const audio_output_kind: AudioOutputKind = .pull_on_audio_thread;
const GamepadSlot = contract.GamepadSlot;
const Gamepad = contract.Gamepad;
const Rumble = contract.Rumble;

/// The performance counter's time, in nanoseconds.
pub fn now() u64 {
    return @trunc(native_os.monotonicMilliseconds() * 1_000_000.0);
}

/// The window's drawing area, in logical pixels, and its scale.
pub fn size() Size {
    return native_loop.size();
}

/// The title bar's text.
pub fn setTitle(title: []const u8) void {
    native_loop.setTitle(title);
}

/// Borderless fullscreen over the window's monitor (`win32.Window.setFullscreen`).
pub fn requestFullscreen(on: bool) void {
    native_loop.setFullscreen(on);
}

/// The system cursor shown over the window, by the contract's name for it.
pub fn setCursor(cursor: Cursor) void {
    const cursor_id: ?usize = switch (cursor) {
        .default => win32.IDC_ARROW,
        .text => win32.IDC_IBEAM,
        .pointer => win32.IDC_HAND,
        .crosshair => win32.IDC_CROSS,
        .move => win32.IDC_SIZEALL,
        .resize_horizontal => win32.IDC_SIZEWE,
        .resize_vertical => win32.IDC_SIZENS,
        .resize_diagonal_down => win32.IDC_SIZENWSE,
        .resize_diagonal_up => win32.IDC_SIZENESW,
        .not_allowed => win32.IDC_NO,
        .wait => win32.IDC_WAIT,
        .hidden => null,
    };
    native_loop.setCursorShape(cursor_id);
}

/// The cursor hidden and confined to the window, the mouse's motion read from raw input.
pub fn requestPointerLock() void {
    native_loop.requestPointerLock();
}

pub fn releasePointerLock() void {
    native_loop.releasePointerLock();
}

/// The display and the system kept on while `on`, as a video player keeps them; the screen saver and sleep wait.
pub fn keepAwake(on: bool) void {
    const awake: u32 = win32.ES_CONTINUOUS | win32.ES_DISPLAY_REQUIRED | win32.ES_SYSTEM_REQUIRED;
    _ = win32.SetThreadExecutionState(if (on) awake else win32.ES_CONTINUOUS);
}

/// Text input on, through the window's input method (`native_loop.startTextInput`) - except for a password, which
/// takes its keys straight, as the contract's options ask of a desktop.
pub fn startTextInput(options: TextInputOptions) void {
    const is_password: bool = options.kind == .password or options.kind == .numeric_password;
    native_loop.startTextInput(!is_password);
}

/// Places the input method's windows at the field (`native_loop.setTextInputArea`).
pub fn setTextInputArea(area: TextInputArea) void {
    native_loop.setTextInputArea(area);
}

/// Text input off, the input method with it.
pub fn stopTextInput() void {
    native_loop.stopTextInput();
}

/// Puts `text` on the clipboard as UTF-16, the clipboard's text format. The clipboard is opened for the window - an
/// owner it needs to accept the data - emptied, which makes the window its owner, and handed movable global memory,
/// which it owns from then on. Text that is not UTF-8 is not copied.
pub fn setClipboardText(text: []const u8) void {
    const unit_count: usize = std.unicode.calcUtf16LeLen(text) catch {
        console.log(.warn, "setClipboardText: the text is not UTF-8, and was not copied");
        return;
    };
    const memory: *anyopaque = win32.GlobalAlloc(win32.GMEM_MOVEABLE, (unit_count + 1) * @sizeOf(u16)) orelse return;
    const locked: *anyopaque = win32.GlobalLock(memory) orelse {
        _ = win32.GlobalFree(memory);
        return;
    };
    const units: [*]u16 = @ptrCast(@alignCast(locked));
    _ = std.unicode.utf8ToUtf16Le(units[0..unit_count], text) catch 0;
    units[unit_count] = 0;
    _ = win32.GlobalUnlock(memory);
    if (win32.OpenClipboard(native_loop.windowHandle()) == 0) {
        _ = win32.GlobalFree(memory);
        return;
    }
    _ = win32.EmptyClipboard();
    if (win32.SetClipboardData(win32.CF_UNICODETEXT, memory) == null) {
        _ = win32.GlobalFree(memory);
    }
    _ = win32.CloseClipboard();
}

/// The clipboard's text, delivered as a `paste` event. Ctrl+V and Shift+Insert paste without asking, as a browser's
/// paste command does (`win32.Window`'s WM_KEYDOWN).
pub fn requestPaste() void {
    native_loop.requestPaste();
}

/// Opens a web address in the default browser. Only `http:`, `https:` and `mailto:` addresses are opened: the
/// shell's `open` would also start programs and open files, which a browser's `window.open` never does. An address
/// longer than 2047 UTF-16 units, or not UTF-8, is left unopened too.
pub fn openUrl(url: []const u8) void {
    const schemes = [_][]const u8{ "http://", "https://", "mailto:" };
    const is_web_address: bool = for (schemes) |scheme| {
        if (startsWith(u8, url, scheme)) {
            break true;
        }
    } else false;
    if (!is_web_address or url.len >= 2048) {
        console.log(.warn, "openUrl: not opened - only http, https and mailto addresses are");
        return;
    }
    var wide_url: [2048:0]u16 = @splat(0);
    const wide_url_length: usize = std.unicode.utf8ToUtf16Le(&wide_url, url) catch return;
    wide_url[wide_url_length] = 0;
    const open_verb: [*:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("open");
    _ = win32.ShellExecuteW(null, open_verb, &wide_url, null, null, win32.SW_SHOWNORMAL);
}

// ---- Saved values: one file per key ----
//
// A program's values live in its own folder under the user's application data - %APPDATA%\zimr\<program>\, the
// program named by its executable - one file per key, `<key>.value`. A key's characters that a file name cannot hold
// are written as `%` and two hex digits. A value is written beside its file first and then moved over it in one step,
// so a crash in the middle of a save leaves the previous value whole.

/// Paths are built as UTF-8 here and converted once; this many bytes, and UTF-16 units, is room for any of them.
const path_room: usize = 1024;

/// `path` as a zero-terminated UTF-16 path in `wide`; null when it is not UTF-8 or does not fit.
fn wideOf(path: []const u8, wide: *[path_room:0]u16) ?[*:0]const u16 {
    if (path.len >= path_room) {
        return null;
    }
    const wide_path_length: usize = std.unicode.utf8ToUtf16Le(wide, path) catch return null;
    wide[wide_path_length] = 0;
    return wide;
}

/// Creates a folder; one that exists already is left as it is.
fn createFolder(path: []const u8) void {
    var wide: [path_room:0]u16 = undefined;
    const wide_path: [*:0]const u16 = wideOf(path, &wide) orelse return;
    _ = win32.CreateDirectoryW(wide_path, null);
}

/// The folder of this program's values, with a trailing separator, written into `buffer`; created with its parent
/// when `create` is set. Null when %APPDATA% is not set or the path does not fit.
fn valuesFolder(buffer: []u8, create: bool) ?[]const u8 {
    var appdata_buffer: [512]u8 = undefined;
    const appdata: []const u8 = win32.environmentVariable("APPDATA", &appdata_buffer) orelse return null;
    var module_units: [512]u16 = undefined;
    const module_length: usize = win32.GetModuleFileNameW(null, &module_units, module_units.len);
    var module_buffer: [1024]u8 = undefined;
    const module_utf8_length: usize = std.unicode.utf16LeToUtf8(&module_buffer, module_units[0..module_length]) catch
        return null;
    const module_path: []const u8 = module_buffer[0..module_utf8_length];
    const file_name: []const u8 = module_path[(lastIndexOfScalar(u8, module_path, '\\') orelse 0) + 1 ..];
    const program: []const u8 = if (endsWith(u8, file_name, ".exe")) file_name[0 .. file_name.len - 4] else file_name;
    if (create) {
        const zimr_folder: []const u8 = bufPrint(buffer, "{s}\\zimr", .{appdata}) catch return null;
        createFolder(zimr_folder);
    }
    const folder: []const u8 = bufPrint(buffer, "{s}\\zimr\\{s}\\", .{ appdata, program }) catch return null;
    if (create) {
        createFolder(folder[0 .. folder.len - 1]);
    }
    return folder;
}

/// The path of `key`'s file, with `suffix` after it, written into `buffer`.
fn valuePath(
    key: []const u8,
    suffix: []const u8,
    create_folder: bool,
    buffer: []u8,
) ?[]const u8 {
    const folder: []const u8 = valuesFolder(buffer, create_folder) orelse return null;
    var path_length: usize = folder.len;
    for (key) |byte| {
        // A letter, a digit, or one of "-_." stays as it is.
        const is_plain: bool = std.ascii.isAlphanumeric(byte) or indexOfScalar(u8, "-_.", byte) != null;
        const written: []const u8 = if (is_plain)
            bufPrint(buffer[path_length..], "{c}", .{byte}) catch return null
        else
            bufPrint(buffer[path_length..], "%{X:0>2}", .{byte}) catch return null;
        path_length += written.len;
    }
    const ending: []const u8 = bufPrint(buffer[path_length..], ".value{s}", .{suffix}) catch return null;
    return buffer[0 .. path_length + ending.len];
}

/// Whether a handle `CreateFileW` answered is its failure value, all bits set.
fn isInvalidHandle(handle: win32.HANDLE) bool {
    return @intFromPtr(handle) == ~@as(usize, 0);
}

/// Opens `wide_path` with `access`, as `disposition` says - open an existing file, or create one afresh.
fn openFile(
    wide_path: [*:0]const u16,
    access: win32.DWORD,
    share: win32.DWORD,
    disposition: win32.DWORD,
) win32.HANDLE {
    return win32.CreateFileW(wide_path, access, share, null, disposition, win32.FILE_ATTRIBUTE_NORMAL, null);
}

/// The value saved under `key`, read into `buffer`: null when there is none, or when it does not fit.
pub fn loadValue(key: []const u8, buffer: []u8) ?[]u8 {
    var path_buffer: [path_room]u8 = undefined;
    const path: []const u8 = valuePath(key, "", false, &path_buffer) orelse return null;
    var wide: [path_room:0]u16 = undefined;
    const wide_path: [*:0]const u16 = wideOf(path, &wide) orelse return null;
    const file: win32.HANDLE = openFile(wide_path, win32.GENERIC_READ, win32.FILE_SHARE_READ, win32.OPEN_EXISTING);
    if (isInvalidHandle(file)) {
        return null;
    }
    defer _ = win32.CloseHandle(file);
    var file_size: i64 = 0;
    if (win32.GetFileSizeEx(file, &file_size) == 0 or file_size < 0 or file_size > buffer.len) {
        return null;
    }
    const value: []u8 = buffer[0..@intCast(file_size)];
    var read_total: usize = 0;
    while (read_total < value.len) {
        const chunk: win32.DWORD = @intCast(@min(value.len - read_total, 1 << 30));
        var read_count: win32.DWORD = 0;
        if (win32.ReadFile(file, value.ptr + read_total, chunk, &read_count, null) == 0 or read_count == 0) {
            return null;
        }
        read_total += read_count;
    }
    return value;
}

/// Saves `bytes` under `key`: written beside the value's file, then moved over it in one step. A failure is logged,
/// and the previous value stays.
pub fn saveValue(key: []const u8, bytes: []const u8) void {
    var path_buffer: [path_room]u8 = undefined;
    var temporary_buffer: [path_room]u8 = undefined;
    const path: []const u8 = valuePath(key, "", true, &path_buffer) orelse return;
    const temporary: []const u8 = valuePath(key, ".new", false, &temporary_buffer) orelse return;
    var wide: [path_room:0]u16 = undefined;
    var temporary_wide: [path_room:0]u16 = undefined;
    const wide_path: [*:0]const u16 = wideOf(path, &wide) orelse return;
    const wide_temporary: [*:0]const u16 = wideOf(temporary, &temporary_wide) orelse return;
    const file: win32.HANDLE = openFile(wide_temporary, win32.GENERIC_WRITE, 0, win32.CREATE_ALWAYS);
    if (isInvalidHandle(file)) {
        console.log(.warn, "saveValue: the value's file could not be created");
        return;
    }
    var written_total: usize = 0;
    const is_written: bool = while (written_total < bytes.len) {
        const chunk: win32.DWORD = @intCast(@min(bytes.len - written_total, 1 << 30));
        var written_count: win32.DWORD = 0;
        if (win32.WriteFile(file, bytes.ptr + written_total, chunk, &written_count, null) == 0) {
            break false;
        }
        written_total += written_count;
    } else true;
    _ = win32.CloseHandle(file);
    const flags: win32.DWORD = win32.MOVEFILE_REPLACE_EXISTING | win32.MOVEFILE_WRITE_THROUGH;
    if (!is_written or win32.MoveFileExW(wide_temporary, wide_path, flags) == 0) {
        _ = win32.DeleteFileW(wide_temporary);
        console.log(.warn, "saveValue: the value could not be written; the previous one stays");
    }
}

/// Removes the value saved under `key`, if there is one.
pub fn removeValue(key: []const u8) void {
    var path_buffer: [path_room]u8 = undefined;
    const path: []const u8 = valuePath(key, "", false, &path_buffer) orelse return;
    var wide: [path_room:0]u16 = undefined;
    const wide_path: [*:0]const u16 = wideOf(path, &wide) orelse return;
    _ = win32.DeleteFileW(wide_path);
}

// ---- Sound: WASAPI ----
//
// The output pulls: a thread of the output's own, the render thread, asks the mixer's renderer for each block the
// device's stream has room for, as the stream signals it, and the renderer writes the block straight into the
// stream's buffer - no queue between the renderer and the device, and a sound starts in the next block the device
// asks for. The main thread only sends the renderer its commands, through the mixer's queues.
//
// The render thread owns everything of WASAPI's, from COM's initialization on. It opens the default output device in
// shared mode, event-driven - Windows signals an event whenever the stream's buffer has room - trying the low-latency
// stream first (`IAudioClient3`, a period as short as the device allows) and the standard one after, with Windows
// converting the format on the standard one (`AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM`), so that the engine mixes 48 000 Hz
// stereo float whatever the device's own format. At each signal it asks how much of the buffer is still waiting to
// play (`GetCurrentPadding`), borrows the rest (`GetBuffer`), has the renderer fill it, and gives it back
// (`ReleaseBuffer`); the renderer is told when the block will be heard - after the padding before it - for the
// latency readout (`AudioRenderTiming`).
//
// When the device goes away (`AUDCLNT_E_DEVICE_INVALIDATED`) or the default device changes - headphones plugged in -
// the thread opens the default device anew. Windows reports a change of default through `device_change_listener`, an
// `IMMNotificationClient` of the engine's own, called on a thread of Windows'. With no device at all, the thread asks
// the renderer for the frames that would have played, at the real rate, and drops them, as if playing to nowhere, so
// that the mixer's voices still advance and end; it looks for a device again each second, or at once when the default
// changes.

/// The most channels the output plays: the mixer's two.
const audio_most_channels: u16 = 2;
/// The stream's buffer asked for: 20 ms, two of the audio engine's usual 10 ms periods, in units of 100 ns.
const audio_stream_buffer_duration: win32.REFERENCE_TIME = 200_000;
/// How long the render thread waits for a device's signal before waiting again, in milliseconds; and how long it waits,
/// with no device, before looking for one again.
const audio_wait_milliseconds: win32.DWORD = 2_000;
const audio_device_retry_ms: f64 = 1_000;
/// How long the render thread pauses before opening a stream again after one failed.
const audio_stream_retry_ms: f64 = 100;

/// The frames rendered at once while no device is open, to be dropped (`renderAndDiscard`).
const discarded_block_frame_capacity: usize = 1_024;

/// The output's state, shared by the main thread and the render thread as each field says.
const WasapiOutput = struct {
    /// The format the output was opened at; written by `startAudioPull` before the render thread starts.
    format: AudioFormat = .{ .sample_rate = 48_000, .channels = 2 },
    thread: ?std.Thread = null,
    /// The renderer the render thread asks for frames (`startAudioPull`). Written before the thread starts, and not
    /// changed while it runs; null while the output is stopped.
    render_callback: ?AudioRenderCallback = null,
    /// Frames rendered while no device is open, to be dropped: the sound keeps its time, as a device would have played
    /// it (`drainWithoutDevice`). Render thread only.
    discard_samples: [discarded_block_frame_capacity * audio_most_channels]f32 = undefined,
    /// Signaled to wake the render thread at once: to stop, or to reopen the default device.
    wake_event: ?win32.HANDLE = null,
    is_stopping: std.atomic.Value(bool) = .{ .raw = false },
    is_device_change_pending: std.atomic.Value(bool) = .{ .raw = false },
    /// The stream open now, for the latency readout: whether it is the low-latency kind, and its latency as WASAPI
    /// reports it (`GetStreamLatency`), in microseconds. Written by the render thread when a stream opens, read by the
    /// main thread.
    is_low_latency_stream: std.atomic.Value(bool) = .{ .raw = false },
    stream_latency_microseconds: std.atomic.Value(u32) = .{ .raw = 0 },
    /// The stream's buffer and, for the low-latency stream, its periods - the one it runs at, the shortest the device
    /// allows and its default - in frames (`openLowLatencyClient`, `playOnDefaultDevice`): what the readout's output
    /// line shows (`audioOutputName`), how soon a sound can start depending on them. 0 where unknown. Written by the
    /// render thread when a stream opens, read by the main thread.
    stream_buffer_frames: std.atomic.Value(u32) = .{ .raw = 0 },
    stream_period_frames: std.atomic.Value(u32) = .{ .raw = 0 },
    shortest_period_frames: std.atomic.Value(u32) = .{ .raw = 0 },
    default_period_frames: std.atomic.Value(u32) = .{ .raw = 0 },
    /// The output line `audioOutputName` writes, with the stream's numbers. Main thread only.
    output_name_buffer: [160]u8 = undefined,
};

// lint:off module-var: the one sound output: its state, shared with its render thread, and the thread itself
var audio_output: WasapiOutput = .{};

/// Asks the renderer for `frame_count` frames and drops them, in blocks the discard room holds: with no device, the
/// renderer still runs at the real rate, so that its voices keep their time and end. Render thread only.
fn renderAndDiscard(render_callback: AudioRenderCallback, frame_count: u64) void {
    const channel_count: usize = audio_output.format.channels;
    var frames_left: u64 = frame_count;
    while (frames_left > 0) {
        const block_frame_count: usize = @intCast(@min(frames_left, discarded_block_frame_capacity));
        const block: []f32 = audio_output.discard_samples[0 .. block_frame_count * channel_count];
        // Played to nowhere: the block is out as soon as it is asked for.
        const now_ms: f64 = native_os.monotonicMilliseconds();
        const timing: AudioRenderTiming = .{ .asked_at_ms = now_ms, .first_frame_out_ms = now_ms };
        render_callback.render(render_callback.context, block, timing);
        frames_left -= block_frame_count;
    }
}

/// With no device: waits up to `duration_ms`, waking every 10 ms to take the frames that would have played meanwhile,
/// until the output stops or the default device changes. Render thread only.
fn drainWithoutDevice(duration_ms: f64) void {
    const wake_event: win32.HANDLE = audio_output.wake_event orelse return;
    const wake_events: [1]win32.HANDLE = .{wake_event};
    const frames_per_millisecond: f64 = float64(audio_output.format.sample_rate) / 1000.0;
    const started_ms: f64 = native_os.monotonicMilliseconds();
    var drained_until_ms: f64 = started_ms;
    while (!audio_output.is_stopping.load(.acquire) and !audio_output.is_device_change_pending.load(.acquire)) {
        const current_ms: f64 = native_os.monotonicMilliseconds();
        if (current_ms - started_ms >= duration_ms) {
            return;
        }
        _ = win32.WaitForMultipleObjects(1, &wake_events, 0, 10);
        const due_frames: u64 = @floor((native_os.monotonicMilliseconds() - drained_until_ms) * frames_per_millisecond);
        if (due_frames == 0) {
            continue;
        }
        const due_frames_float: f64 = @floatFromInt(due_frames);
        drained_until_ms += due_frames_float / frames_per_millisecond;
        const render_callback: AudioRenderCallback = audio_output.render_callback orelse return;
        renderAndDiscard(render_callback, due_frames);
    }
}

/// The listener Windows calls when output devices change (`IMMNotificationClient`), on a thread of Windows'. A static
/// object: its reference count is fixed, Windows' `AddRef` and `Release` changing nothing. A new default device for
/// ordinary sound marks the stream for reopening and wakes the render thread; every other notice is acknowledged.
const DeviceChangeListener = struct {
    fn queryInterface(
        listener: *win32.IMMNotificationClient,
        interface_id: *const win32.GUID,
        object: *?*anyopaque,
    ) callconv(.winapi) win32.HRESULT {
        const is_unknown: bool = eql(u8, asBytes(interface_id), asBytes(&win32.IID_IUnknown));
        const is_notification_client: bool = eql(u8, asBytes(interface_id), asBytes(&win32.IID_IMMNotificationClient));
        if (!is_unknown and !is_notification_client) {
            object.* = null;
            return win32.E_NOINTERFACE;
        }
        object.* = listener;
        return win32.S_OK;
    }

    fn addRef(listener: *win32.IMMNotificationClient) callconv(.winapi) u32 {
        _ = listener;
        return 1;
    }

    fn release(listener: *win32.IMMNotificationClient) callconv(.winapi) u32 {
        _ = listener;
        return 1;
    }

    fn onDeviceStateChanged(
        listener: *win32.IMMNotificationClient,
        device_id: [*:0]const u16,
        new_state: win32.DWORD,
    ) callconv(.winapi) win32.HRESULT {
        _ = listener;
        _ = device_id;
        _ = new_state;
        return win32.S_OK;
    }

    fn onDeviceAddedOrRemoved(
        listener: *win32.IMMNotificationClient,
        device_id: [*:0]const u16,
    ) callconv(.winapi) win32.HRESULT {
        _ = listener;
        _ = device_id;
        return win32.S_OK;
    }

    fn onDefaultDeviceChanged(
        listener: *win32.IMMNotificationClient,
        flow: win32.DWORD,
        role: win32.DWORD,
        device_id: ?[*:0]const u16,
    ) callconv(.winapi) win32.HRESULT {
        _ = listener;
        _ = device_id;
        const is_default_output: bool = flow == win32.eRender and role == win32.eConsole;
        if (is_default_output) {
            audio_output.is_device_change_pending.store(true, .release);
            if (audio_output.wake_event) |wake_event| {
                _ = win32.SetEvent(wake_event);
            }
        }
        return win32.S_OK;
    }

    fn onPropertyValueChanged(
        listener: *win32.IMMNotificationClient,
        device_id: [*:0]const u16,
        key: win32.PROPERTYKEY,
    ) callconv(.winapi) win32.HRESULT {
        _ = listener;
        _ = device_id;
        _ = key;
        return win32.S_OK;
    }

    const vtable: win32.IMMNotificationClient.VTable = .{
        .QueryInterface = &queryInterface,
        .AddRef = &addRef,
        .Release = &release,
        .OnDeviceStateChanged = &onDeviceStateChanged,
        .OnDeviceAdded = &onDeviceAddedOrRemoved,
        .OnDeviceRemoved = &onDeviceAddedOrRemoved,
        .OnDefaultDeviceChanged = &onDefaultDeviceChanged,
        .OnPropertyValueChanged = &onPropertyValueChanged,
    };
};

// lint:off module-var: the device-change listener Windows holds while it is registered
var device_change_listener: win32.IMMNotificationClient = .{ .vtable = &DeviceChangeListener.vtable };

/// How a stream ended: the output stopped; the default device changed or the device went away, and the default is
/// to be opened at once; or the stream failed, and is to be opened again after a pause (`audio_stream_retry_ms`), so
/// that a failure repeating at once does not spin the thread.
const StreamEnd = enum { stopped, device_changed, failed };

/// Fills `room_frames` frames of the stream's buffer: borrows them (`GetBuffer`), has the renderer write the block
/// into them, and gives them back (`ReleaseBuffer`). False when the stream refuses. `padding_frames` are already in
/// the buffer, waiting to play: the new frames reach the device after them, which is what the renderer is told
/// (`AudioRenderTiming`). Render thread only.
fn fillStreamRoom(
    render_client: *win32.IAudioRenderClient,
    room_frames: u32,
    padding_frames: u32,
) bool {
    var stream_bytes: ?[*]u8 = null;
    if (render_client.vtable.GetBuffer(render_client, room_frames, &stream_bytes) < 0) {
        return false;
    }
    const channel_count: usize = audio_output.format.channels;
    const stream_floats: [*]f32 = @ptrCast(@alignCast(stream_bytes.?));
    const stream_samples: []f32 = stream_floats[0 .. room_frames * channel_count];
    // The renderer writes straight into the device's buffer: the device's room is the block. Its first frame plays
    // once the `padding_frames` before it have played: `padding / rate` after now.
    const render_callback: AudioRenderCallback = audio_output.render_callback orelse return false;
    const asked_at_ms: f64 = native_os.monotonicMilliseconds();
    const sample_rate: f64 = float64(audio_output.format.sample_rate);
    const padding_ms: f64 = float64(padding_frames) * 1000.0 / sample_rate;
    const timing: AudioRenderTiming = .{
        .asked_at_ms = asked_at_ms,
        .first_frame_out_ms = asked_at_ms + padding_ms,
    };
    render_callback.render(render_callback.context, stream_samples, timing);
    return render_client.vtable.ReleaseBuffer(render_client, room_frames, 0) >= 0;
}

/// The stream's loop: at each signal of `render_event`, has the renderer fill the room in the stream's buffer, until
/// the output stops, the default device changes, or the stream fails. Render thread only.
/// How far ahead of the device the low-latency stream is kept, beyond one period: 2 ms, 96 frames at 48 kHz.
const fill_margin_milliseconds: f64 = 2;

/// How full the stream's buffer is kept, in frames (`streamUntilChange`). The audio engine reads one period from the
/// buffer each period and then signals the render thread, which has until the engine's next read - a period - to
/// write the next one: that is its slack against a dropout, however full the buffer is. Sound queued beyond one period
/// only delays every new sound by as much. So the low-latency stream, whose period is known
/// (`stream_period_frames`), is kept at one period and a small margin, in case the engine reads a little early; the
/// standard stream, whose period is the engine's own and unreported, is kept full, as before.
fn fillTargetFrames(buffer_frames: u32) u32 {
    const period_frames: u32 = audio_output.stream_period_frames.load(.acquire);
    if (period_frames == 0) {
        return buffer_frames;
    }
    const frames_per_millisecond: f64 = float64(audio_output.format.sample_rate) / 1000.0;
    const margin_frames: u32 = @round(fill_margin_milliseconds * frames_per_millisecond);
    return @min(buffer_frames, period_frames + margin_frames);
}

fn streamUntilChange(
    client: *win32.IAudioClient,
    render_client: *win32.IAudioRenderClient,
    render_event: win32.HANDLE,
    buffer_frames: u32,
) StreamEnd {
    const wake_event: win32.HANDLE = audio_output.wake_event orelse return .stopped;
    const wait_events: [2]win32.HANDLE = .{ render_event, wake_event };
    while (true) {
        const wait_result: win32.DWORD = win32.WaitForMultipleObjects(2, &wait_events, 0, audio_wait_milliseconds);
        if (audio_output.is_stopping.load(.acquire)) {
            return .stopped;
        }
        if (audio_output.is_device_change_pending.load(.acquire)) {
            return .device_changed;
        }
        if (wait_result == win32.WAIT_TIMEOUT) {
            continue;
        }
        var padding_frames: u32 = 0;
        const padding_result: win32.HRESULT = client.vtable.GetCurrentPadding(client, &padding_frames);
        if (padding_result == win32.AUDCLNT_E_DEVICE_INVALIDATED) {
            return .device_changed;
        }
        if (padding_result < 0) {
            return .failed;
        }
        // Topped up to the fill target (`fillTargetFrames`), not to the buffer's end.
        const target_frames: u32 = fillTargetFrames(buffer_frames);
        if (padding_frames >= target_frames) {
            continue;
        }
        const room_frames: u32 = target_frames - padding_frames;
        if (!fillStreamRoom(render_client, room_frames, padding_frames)) {
            return .failed;
        }
    }
}

/// Activates a fresh `IAudioClient` on `device`: each attempt at opening a stream gets its own, a client whose stream
/// failed to open being released rather than tried again. Null when the device refuses.
fn activateClient(device: *win32.IMMDevice) ?*win32.IAudioClient {
    var client_object: ?*anyopaque = null;
    if (device.vtable.Activate(device, &win32.IID_IAudioClient, win32.CLSCTX_ALL, null, &client_object) < 0) {
        return null;
    }
    return @ptrCast(@alignCast(client_object.?));
}

/// Opens a low-latency shared stream on `device` (`IAudioClient3`, Windows 10 and later) at the engine's shortest
/// period for `stream_format` - often 128 to 160 frames at 48 kHz, 2.7 to 3.3 ms, where the device's driver allows
/// less than the standard 10 ms - so that a sound starts within one short period of being asked for. No conversion
/// is asked for: the engine must run at the stream's format. Null when the device has no `IAudioClient3`, or refuses
/// the format or the period; the caller then opens the standard stream (`openStandardClient`). Render thread only.
fn openLowLatencyClient(device: *win32.IMMDevice, stream_format: *const win32.WAVEFORMATEX) ?*win32.IAudioClient {
    const client: *win32.IAudioClient = activateClient(device) orelse return null;
    var client3_object: ?*anyopaque = null;
    if (client.vtable.QueryInterface(client, &win32.IID_IAudioClient3, &client3_object) < 0) {
        _ = client.vtable.Release(client);
        return null;
    }
    const client3: *win32.IAudioClient3 = @ptrCast(@alignCast(client3_object.?));
    defer _ = client3.vtable.Release(client3);
    var default_period_frames: u32 = 0;
    var period_step_frames: u32 = 0;
    var shortest_period_frames: u32 = 0;
    var longest_period_frames: u32 = 0;
    const period_result: win32.HRESULT = client3.vtable.GetSharedModeEnginePeriod(
        client3,
        stream_format,
        &default_period_frames,
        &period_step_frames,
        &shortest_period_frames,
        &longest_period_frames,
    );
    if (period_result < 0) {
        _ = client.vtable.Release(client);
        return null;
    }
    const stream_result: win32.HRESULT = client3.vtable.InitializeSharedAudioStream(
        client3,
        win32.AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
        shortest_period_frames,
        stream_format,
        null,
    );
    if (stream_result < 0) {
        _ = client.vtable.Release(client);
        return null;
    }
    audio_output.stream_period_frames.store(shortest_period_frames, .release);
    audio_output.shortest_period_frames.store(shortest_period_frames, .release);
    audio_output.default_period_frames.store(default_period_frames, .release);
    return client;
}

/// Opens the standard shared stream on `device`: the engine's own period, 10 ms, a 20 ms buffer
/// (`audio_stream_buffer_duration`), and Windows converting the stream's format to the engine's. Null when the device
/// refuses it. Render thread only.
fn openStandardClient(device: *win32.IMMDevice, stream_format: *const win32.WAVEFORMATEX) ?*win32.IAudioClient {
    const client: *win32.IAudioClient = activateClient(device) orelse return null;
    const stream_flags: win32.DWORD = win32.AUDCLNT_STREAMFLAGS_EVENTCALLBACK |
        win32.AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
        win32.AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY |
        win32.AUDCLNT_STREAMFLAGS_NOPERSIST;
    const initialize_result: win32.HRESULT = client.vtable.Initialize(
        client,
        win32.AUDCLNT_SHAREMODE_SHARED,
        stream_flags,
        audio_stream_buffer_duration,
        0,
        stream_format,
        null,
    );
    if (initialize_result < 0) {
        _ = client.vtable.Release(client);
        return null;
    }
    return client;
}

/// Says which stream opened and the size of its buffer, once for each device: how soon a sound can start depends on
/// it.
fn reportStream(is_low_latency: bool, buffer_frames: u32) void {
    var message_buffer: [96]u8 = undefined;
    const stream_kind: []const u8 = if (is_low_latency) "a low-latency" else "the standard";
    const message: []const u8 = bufPrint(
        &message_buffer,
        "windows audio: {s} shared stream, a buffer of {d} frames",
        .{ stream_kind, buffer_frames },
    ) catch "windows audio: a shared stream";
    console.log(.info, message);
}

/// Plays on the default output device until the output stops, the device changes or goes, or the stream fails, and
/// says which; null when no stream could be opened on it. Render thread only.
fn playOnDefaultDevice(enumerator: *win32.IMMDeviceEnumerator) ?StreamEnd {
    // The event outlives the client holding it: made first, it is closed last.
    const render_event: win32.HANDLE = win32.CreateEventW(null, 0, 0, null) orelse return null;
    defer _ = win32.CloseHandle(render_event);
    var default_device: ?*win32.IMMDevice = null;
    const device_result: win32.HRESULT = enumerator.vtable.GetDefaultAudioEndpoint(
        enumerator,
        win32.eRender,
        win32.eConsole,
        &default_device,
    );
    if (device_result < 0) {
        return null;
    }
    const device: *win32.IMMDevice = default_device.?;
    defer _ = device.vtable.Release(device);
    const format: AudioFormat = audio_output.format;
    const bytes_per_frame: u16 = @sizeOf(f32) * format.channels;
    const stream_format: win32.WAVEFORMATEX = .{
        .wFormatTag = win32.WAVE_FORMAT_IEEE_FLOAT,
        .nChannels = format.channels,
        .nSamplesPerSec = format.sample_rate,
        .nAvgBytesPerSec = format.sample_rate * bytes_per_frame,
        .nBlockAlign = bytes_per_frame,
        .wBitsPerSample = 32,
        .cbSize = 0,
    };
    // The low-latency stream first; a device without it, or refusing the format, gets the standard one.
    const low_latency_client: ?*win32.IAudioClient = openLowLatencyClient(device, &stream_format);
    const client: *win32.IAudioClient = low_latency_client orelse openStandardClient(device, &stream_format) orelse {
        return null;
    };
    defer _ = client.vtable.Release(client);
    var buffer_frames: u32 = 0;
    if (client.vtable.GetBufferSize(client, &buffer_frames) < 0) {
        return null;
    }
    reportStream(low_latency_client != null, buffer_frames);
    audio_output.stream_buffer_frames.store(buffer_frames, .release);
    if (low_latency_client == null) {
        // The standard stream's period is the engine's own, which it does not say; none shown.
        audio_output.stream_period_frames.store(0, .release);
        audio_output.shortest_period_frames.store(0, .release);
        audio_output.default_period_frames.store(0, .release);
    }
    // WASAPI's own latency past the buffer, in units of 100 ns: kept for the latency readout.
    var stream_latency: win32.REFERENCE_TIME = 0;
    if (client.vtable.GetStreamLatency(client, &stream_latency) >= 0) {
        const stream_latency_microseconds: u32 = @intCast(@divTrunc(@max(stream_latency, 0), 10));
        audio_output.stream_latency_microseconds.store(stream_latency_microseconds, .release);
    }
    audio_output.is_low_latency_stream.store(low_latency_client != null, .release);
    if (client.vtable.SetEventHandle(client, render_event) < 0) {
        return null;
    }
    var render_client_object: ?*anyopaque = null;
    if (client.vtable.GetService(client, &win32.IID_IAudioRenderClient, &render_client_object) < 0) {
        return null;
    }
    const render_client: *win32.IAudioRenderClient = @ptrCast(@alignCast(render_client_object.?));
    defer _ = render_client.vtable.Release(render_client);
    // The buffer is filled to its target (`fillTargetFrames`) before the stream starts, so that the device's first
    // period has something to play rather than an empty buffer.
    if (!fillStreamRoom(render_client, fillTargetFrames(buffer_frames), 0)) {
        return null;
    }
    if (client.vtable.Start(client) < 0) {
        return null;
    }
    defer _ = client.vtable.Stop(client);
    return streamUntilChange(client, render_client, render_event, buffer_frames);
}

/// The render thread: COM for itself, the device enumerator, Windows' notice of device changes - then streams on the
/// default device, one after another, until the output stops; between them, with no device, it renders to nowhere at
/// the real rate (`drainWithoutDevice`). Subnormal numbers are the renderer's own concern: it flushes them for each
/// block it renders, on whatever thread (`sound.zig`, `enterFlushToZero`).
fn renderThreadMain() void {
    // Scheduled as audio work (MMCSS's "Pro Audio" task), ahead of ordinary threads, while the thread lives.
    var multimedia_task_index: win32.DWORD = 0;
    const pro_audio_task: [*:0]const u16 = utf8ToUtf16LeStringLiteral("Pro Audio");
    const multimedia_registration: ?win32.HANDLE = win32.AvSetMmThreadCharacteristicsW(
        pro_audio_task,
        &multimedia_task_index,
    );
    defer if (multimedia_registration) |registration| {
        _ = win32.AvRevertMmThreadCharacteristics(registration);
    };
    const com_result: win32.HRESULT = win32.CoInitializeEx(null, win32.COINIT_MULTITHREADED);
    if (com_result < 0) {
        console.log(.err, "windows audio: COM would not start on the render thread; the sound drains unplayed");
        while (!audio_output.is_stopping.load(.acquire)) {
            drainWithoutDevice(audio_device_retry_ms);
        }
        return;
    }
    defer win32.CoUninitialize();
    var enumerator_object: ?*anyopaque = null;
    const enumerator_result: win32.HRESULT = win32.CoCreateInstance(
        &win32.CLSID_MMDeviceEnumerator,
        null,
        win32.CLSCTX_ALL,
        &win32.IID_IMMDeviceEnumerator,
        &enumerator_object,
    );
    if (enumerator_result < 0) {
        console.log(.err, "windows audio: no device enumerator; the sound drains unplayed");
        while (!audio_output.is_stopping.load(.acquire)) {
            drainWithoutDevice(audio_device_retry_ms);
        }
        return;
    }
    const enumerator: *win32.IMMDeviceEnumerator = @ptrCast(@alignCast(enumerator_object.?));
    defer _ = enumerator.vtable.Release(enumerator);
    const listener_result: win32.HRESULT = enumerator.vtable.RegisterEndpointNotificationCallback(
        enumerator,
        &device_change_listener,
    );
    defer if (listener_result >= 0) {
        _ = enumerator.vtable.UnregisterEndpointNotificationCallback(enumerator, &device_change_listener);
    };
    var has_reported_no_device: bool = false;
    while (!audio_output.is_stopping.load(.acquire)) {
        audio_output.is_device_change_pending.store(false, .release);
        if (playOnDefaultDevice(enumerator)) |stream_end| {
            has_reported_no_device = false;
            if (stream_end == .failed) {
                drainWithoutDevice(audio_stream_retry_ms);
            }
            continue;
        }
        if (!has_reported_no_device) {
            const no_device_message: []const u8 =
                "windows audio: no output device could be opened; the sound drains unplayed until one is";
            console.log(.warn, no_device_message);
            has_reported_no_device = true;
        }
        drainWithoutDevice(audio_device_retry_ms);
    }
}

/// Stops the render thread - it closes the stream - and drops what was queued.
pub fn stopAudio() void {
    const thread: std.Thread = audio_output.thread orelse return;
    audio_output.is_stopping.store(true, .release);
    if (audio_output.wake_event) |wake_event| {
        _ = win32.SetEvent(wake_event);
    }
    thread.join();
    audio_output.thread = null;
    audio_output.render_callback = null;
    if (audio_output.wake_event) |wake_event| {
        _ = win32.CloseHandle(wake_event);
    }
    audio_output.wake_event = null;
}

/// The clock sound is timed by: the system's monotonic clock (the performance counter), the same on every thread.
pub fn audioClockMilliseconds() f64 {
    return native_os.monotonicMilliseconds();
}

/// Past the device's buffer, what WASAPI reports of its stream's latency (`GetStreamLatency`); the buffer itself is
/// in each block's timing already (`padding`). The driver and the converter beyond it are not reported.
pub fn audioOutputLatencyMilliseconds() f64 {
    const microseconds: u32 = audio_output.stream_latency_microseconds.load(.acquire);
    return float64(microseconds) / 1000.0;
}

/// Which stream plays: the low-latency one (`IAudioClient3`) or the standard one.
/// The output, as the latency readout's first line names it: the stream, and the numbers how soon a sound can start
/// depends on - its period (the shortest the device allows, and its default), its buffer, and how full the render
/// thread keeps it (`fillTargetFrames`), in milliseconds at the stream's rate. The low-latency stream runs at the
/// shortest period, kept one period and a margin full: that margin is about what is queued ahead of a new block.
pub fn audioOutputName() []const u8 {
    const is_low_latency: bool = audio_output.is_low_latency_stream.load(.acquire);
    const stream_kind: []const u8 = if (is_low_latency) "low-latency stream" else "standard stream";
    const frames_per_millisecond: f64 = float64(audio_output.format.sample_rate) / 1000.0;
    const buffer_ms: f64 = float64(audio_output.stream_buffer_frames.load(.acquire)) / frames_per_millisecond;
    const period_ms: f64 = float64(audio_output.stream_period_frames.load(.acquire)) / frames_per_millisecond;
    const shortest_ms: f64 = float64(audio_output.shortest_period_frames.load(.acquire)) / frames_per_millisecond;
    const default_ms: f64 = float64(audio_output.default_period_frames.load(.acquire)) / frames_per_millisecond;
    const buffer: []u8 = &audio_output.output_name_buffer;
    if (period_ms > 0) {
        const kept_frames: u32 = fillTargetFrames(audio_output.stream_buffer_frames.load(.acquire));
        const kept_ms: f64 = float64(kept_frames) / frames_per_millisecond;
        return bufPrint(
            buffer,
            "WASAPI, {s}: period {d:.1} ms (shortest {d:.1}, default {d:.1}), buffer {d:.1} ms, kept {d:.1} ms",
            .{ stream_kind, period_ms, shortest_ms, default_ms, buffer_ms, kept_ms },
        ) catch stream_kind;
    }
    if (buffer_ms > 0) {
        return bufPrint(buffer, "WASAPI, {s}: buffer {d:.1} ms", .{ stream_kind, buffer_ms }) catch stream_kind;
    }
    return bufPrint(buffer, "WASAPI, {s}", .{stream_kind}) catch stream_kind;
}

/// Opens the output at `wanted` - up to two channels; Windows converts the rate on the standard stream - and starts
/// its render thread, which opens the device and asks `render_callback` for the frames the device has room for, at
/// each of its signals. The format is granted at once: the device opens on the render thread, and a device that cannot
/// open makes the thread render to nowhere at the real rate (`drainWithoutDevice`) rather than refuse the format.
/// `render_callback` is written before the render thread starts, which makes it visible there.
pub fn startAudioPull(wanted: AudioFormat, render_callback: AudioRenderCallback) AudioFormat {
    stopAudio();
    const granted: AudioFormat = .{
        .sample_rate = wanted.sample_rate,
        .channels = @min(wanted.channels, audio_most_channels),
    };
    audio_output.format = granted;
    audio_output.render_callback = render_callback;
    audio_output.is_stopping.store(false, .monotonic);
    audio_output.is_device_change_pending.store(false, .monotonic);
    const wake_event: win32.HANDLE = win32.CreateEventW(null, 0, 0, null) orelse {
        console.log(.err, "windows audio: no event to wake a render thread; the sound is not played");
        return granted;
    };
    audio_output.wake_event = wake_event;
    audio_output.thread = std.Thread.spawn(.{}, renderThreadMain, .{}) catch {
        console.log(.err, "windows audio: no render thread could start; the sound is not played");
        _ = win32.CloseHandle(wake_event);
        audio_output.wake_event = null;
        return granted;
    };
    return granted;
}

// ---- Gamepads, through XInput ----

/// XInput's four slots.
const xinput_slot_count: usize = 4;

/// How long a slot found empty waits before XInput is asked about it again: asking about an empty slot is slow -
/// XInput looks for a gamepad there each time - so a program polling four slots every frame would pay for it in every
/// frame. A gamepad plugged in shows within this time.
const empty_slot_wait_ns: u64 = 1_000_000_000;

/// XInput's two functions, looked up at first use (`lookUpXInput`); null when Windows has no XInput, and so no
/// gamepads.
const XInput = struct {
    get_state: ?win32.XInputGetStateFn = null,
    set_state: ?win32.XInputSetStateFn = null,
    is_looked_up: bool = false,
};

// lint:off module-var: XInput's two functions, looked up once
var xinput: XInput = .{};
// lint:off module-var: when each slot found empty may be asked again, in `now`'s nanoseconds
var empty_slot_asked_at: [xinput_slot_count]?u64 = @splat(null);
// lint:off module-var: when each slot's rumble ends, in `now`'s nanoseconds; null when it is still
var rumble_ends_at: [xinput_slot_count]?u64 = @splat(null);

/// Finds XInput: the newest of its DLLs Windows has - `xinput1_4` since Windows 8, `xinput1_3` with the DirectX
/// runtime, `xinput9_1_0` since Vista - loaded by name, as GLFW and SDL load it, so that no version is needed for
/// the program to start.
fn lookUpXInput() void {
    if (xinput.is_looked_up) {
        return;
    }
    xinput.is_looked_up = true;
    const library_names = [_][:0]const u16{
        utf8ToUtf16LeStringLiteral("xinput1_4.dll"),
        utf8ToUtf16LeStringLiteral("xinput1_3.dll"),
        utf8ToUtf16LeStringLiteral("xinput9_1_0.dll"),
    };
    for (library_names) |library_name| {
        const library: win32.HMODULE = win32.LoadLibraryW(library_name) orelse continue;
        const get_state: *const anyopaque = win32.GetProcAddress(library, "XInputGetState") orelse continue;
        xinput.get_state = @ptrCast(get_state);
        if (win32.GetProcAddress(library, "XInputSetState")) |set_state| {
            xinput.set_state = @ptrCast(set_state);
        }
        return;
    }
}

/// A stick's position, from XInput's -32768 to 32767 into the contract's -1 to 1.
fn stickPosition(value: i16) f32 {
    const value_float: f32 = @floatFromInt(value);
    const position: f32 = value_float / 32767.0;
    return if (position < -1) -1 else position;
}

/// The contract's gamepad from XInput's: each button 0 or 1, the triggers from 0 to 1, the sticks' vertical axes
/// turned over - XInput's up is positive, the contract's (the browser's) down. XInput reports no guide button.
fn gamepadOfXInput(pad: win32.XINPUT_GAMEPAD) Gamepad {
    var read: Gamepad = .{ .buttons = .initFill(0), .axes = .initFill(0) };
    const button_bits = [_]struct { button: contract.GamepadButton, bit: u16 }{
        .{ .button = .south, .bit = win32.XINPUT_GAMEPAD_A },
        .{ .button = .east, .bit = win32.XINPUT_GAMEPAD_B },
        .{ .button = .west, .bit = win32.XINPUT_GAMEPAD_X },
        .{ .button = .north, .bit = win32.XINPUT_GAMEPAD_Y },
        .{ .button = .left_shoulder, .bit = win32.XINPUT_GAMEPAD_LEFT_SHOULDER },
        .{ .button = .right_shoulder, .bit = win32.XINPUT_GAMEPAD_RIGHT_SHOULDER },
        .{ .button = .back, .bit = win32.XINPUT_GAMEPAD_BACK },
        .{ .button = .start, .bit = win32.XINPUT_GAMEPAD_START },
        .{ .button = .left_stick, .bit = win32.XINPUT_GAMEPAD_LEFT_THUMB },
        .{ .button = .right_stick, .bit = win32.XINPUT_GAMEPAD_RIGHT_THUMB },
        .{ .button = .dpad_up, .bit = win32.XINPUT_GAMEPAD_DPAD_UP },
        .{ .button = .dpad_down, .bit = win32.XINPUT_GAMEPAD_DPAD_DOWN },
        .{ .button = .dpad_left, .bit = win32.XINPUT_GAMEPAD_DPAD_LEFT },
        .{ .button = .dpad_right, .bit = win32.XINPUT_GAMEPAD_DPAD_RIGHT },
    };
    for (button_bits) |button_bit| {
        const is_down: bool = pad.wButtons & button_bit.bit != 0;
        read.buttons.set(button_bit.button, if (is_down) 1 else 0);
    }
    const left_trigger: f32 = @floatFromInt(pad.bLeftTrigger);
    const right_trigger: f32 = @floatFromInt(pad.bRightTrigger);
    read.buttons.set(.left_trigger, left_trigger / 255.0);
    read.buttons.set(.right_trigger, right_trigger / 255.0);
    read.axes.set(.left_x, stickPosition(pad.sThumbLX));
    read.axes.set(.left_y, -stickPosition(pad.sThumbLY));
    read.axes.set(.right_x, stickPosition(pad.sThumbRX));
    read.axes.set(.right_y, -stickPosition(pad.sThumbRY));
    return read;
}

/// Ends a slot's rumble once its time is up: XInput's motors run until told otherwise, so the platform tells them,
/// the first time the slot is read after the rumble's end - every frame, as the engine reads every slot.
fn stopEndedRumble(slot: usize, now_ns: u64) void {
    const ends_at: u64 = rumble_ends_at[slot] orelse return;
    if (now_ns < ends_at) {
        return;
    }
    rumble_ends_at[slot] = null;
    const set_state: win32.XInputSetStateFn = xinput.set_state orelse return;
    var stopped: win32.XINPUT_VIBRATION = .{ .wLeftMotorSpeed = 0, .wRightMotorSpeed = 0 };
    _ = set_state(@intCast(slot), &stopped);
}

/// The gamepad in a slot, read through XInput; null for an empty slot, a slot past XInput's four, or no XInput. A slot
/// found empty is not asked again for a second (`empty_slot_wait_ns`). A slot a script has taken over answers with the
/// script's gamepad instead (`native_loop.scriptedGamepad`).
pub fn gamepad(slot: GamepadSlot) ?Gamepad {
    if (native_loop.scriptedGamepad(slot)) |scripted_slot| {
        return scripted_slot.scripted;
    }
    if (slot >= xinput_slot_count) {
        return null;
    }
    lookUpXInput();
    const get_state: win32.XInputGetStateFn = xinput.get_state orelse return null;
    const now_ns: u64 = now();
    stopEndedRumble(slot, now_ns);
    if (empty_slot_asked_at[slot]) |asked_at| {
        if (now_ns - asked_at < empty_slot_wait_ns) {
            return null;
        }
    }
    var state: win32.XINPUT_STATE = zeroes(win32.XINPUT_STATE);
    if (get_state(slot, &state) != 0) {
        empty_slot_asked_at[slot] = now_ns;
        return null;
    }
    empty_slot_asked_at[slot] = null;
    return gamepadOfXInput(state.Gamepad);
}

/// A motor's speed for XInput, 0 to 65535, from a strength held to 0 to 1.
fn motorSpeed(strength: f32) u16 {
    const held: f32 = if (strength < 0) 0 else if (strength > 1) 1 else strength;
    return @round(held * 65535.0);
}

/// Runs a slot's two motors - the heavy one (`low`) on the left, the light one (`high`) on the right - for
/// `rumble.milliseconds`, stopped then (`stopEndedRumble`); 0 milliseconds stops them now.
pub fn setGamepadRumble(slot: GamepadSlot, rumble: Rumble) void {
    if (slot >= xinput_slot_count) {
        return;
    }
    lookUpXInput();
    const set_state: win32.XInputSetStateFn = xinput.set_state orelse return;
    var vibration: win32.XINPUT_VIBRATION = .{
        .wLeftMotorSpeed = motorSpeed(rumble.low),
        .wRightMotorSpeed = motorSpeed(rumble.high),
    };
    if (rumble.milliseconds == 0) {
        vibration = .{ .wLeftMotorSpeed = 0, .wRightMotorSpeed = 0 };
    }
    _ = set_state(slot, &vibration);
    const duration_ns: u64 = @as(u64, rumble.milliseconds) * 1_000_000;
    rumble_ends_at[slot] = if (rumble.milliseconds == 0) null else now() + duration_ns;
}

/// Standard error, each line prefixed with its level (`console.zig`).
pub const log = console.log;

// The requests written here, compiled in every build that runs on this platform - so a mistake in one fails the build
// before the engine calls it. A refusal cannot be named: compiling it is the refusal.
comptime {
    _ = &now;
    _ = &size;
    _ = &log;
}

/// Files the person hands the app - chosen with the system's Open dialog from the app's Load button, or dropped on
/// the window - and the file it offers, saved where the person chooses in the Save dialog (`native_loop`).
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
/// multiplayer servers listen on unless told otherwise (`zig build signal-server`).
pub fn socketOriginUrl(out: []u8) []const u8 {
    const local_server: []const u8 = "ws://127.0.0.1:7777";
    // An address cut short would lead elsewhere - another port - so a buffer too small for it gets none.
    if (out.len < local_server.len) {
        return out[0..0];
    }
    @memcpy(out[0..local_server.len], local_server);
    return out[0..local_server.len];
}

/// The system's clock reads 100-nanosecond ticks since 1601; the Unix epoch is 11 644 473 600 seconds later.
pub fn epochMillis() f64 {
    var file_time: win32.FILETIME = undefined;
    win32.GetSystemTimePreciseAsFileTime(&file_time);
    const ticks_since_1601: u64 = (@as(u64, file_time.dwHighDateTime) << 32) | file_time.dwLowDateTime;
    const ticks_at_unix_epoch: u64 = 116_444_736_000_000_000;
    const ticks_since_unix_epoch: u64 = ticks_since_1601 -| ticks_at_unix_epoch;
    const ticks_per_millisecond: f64 = 10_000;
    const ticks: f64 = @floatFromInt(ticks_since_unix_epoch);
    return ticks / ticks_per_millisecond;
}

/// The performance counter (`QueryPerformanceCounter`), in milliseconds.
pub fn monotonicMilliseconds() f64 {
    return native_os.monotonicMilliseconds();
}

/// The monitors, as Windows lists them (`native_loop.monitorCount`, `monitor`, `currentMonitor`).
pub fn monitorCount() u32 {
    return native_loop.monitorCount();
}

pub fn monitor(index: u32) ?contract.Monitor {
    return native_loop.monitor(index);
}

pub fn currentMonitor() u32 {
    return native_loop.currentMonitor();
}

/// How the window is shown, its focus, placement and size limits (`native_loop`).
pub fn showWindow(show: contract.WindowShow) void {
    native_loop.showWindow(show);
}

pub fn focusWindow() void {
    native_loop.focusWindow();
}

pub fn setWindowPosition(monitor_index: u32, x: f32, y: f32) void {
    native_loop.setWindowPosition(monitor_index, x, y);
}

/// The app asks to end (`native_loop.requestQuit`): the window closes as if its close button were pressed.
pub fn requestQuit() void {
    native_loop.requestQuit();
}

pub fn setWindowSizeLimits(limits: contract.SizeLimits) void {
    native_loop.setWindowSizeLimits(limits);
}

/// A key's label in the current keyboard layout, as Windows names it (`GetKeyNameTextW`): for a letter key, the
/// letter it types in that layout; for the others, the layout's own name, in its language. The key's position is its
/// scancode (`native_input.scancodeOfEngineKey`).
pub fn keyName(key: contract.KeyboardKey, buffer: []u8) ?[]const u8 {
    const scancode: u16 = native_input.scancodeOfEngineKey(key) orelse return null;
    // As a key message's lParam: the scancode in bits 16 to 23, the extended flag in bit 24.
    const is_extended: bool = scancode >= 0x100;
    const extended_bit: i32 = if (is_extended) 1 << 24 else 0;
    const key_parameter: i32 = (@as(i32, scancode & 0xff) << 16) | extended_bit;
    var name_units: [64]u16 = undefined;
    const unit_count: i32 = win32.GetKeyNameTextW(key_parameter, &name_units, name_units.len);
    if (unit_count <= 0) {
        return null;
    }
    var name_bytes: [256]u8 = undefined;
    const name_utf16: []const u16 = name_units[0..@intCast(unit_count)];
    const byte_count: usize = std.unicode.utf16LeToUtf8(&name_bytes, name_utf16) catch return null;
    if (byte_count > buffer.len) {
        return null;
    }
    @memcpy(buffer[0..byte_count], name_bytes[0..byte_count]);
    return buffer[0..byte_count];
}
