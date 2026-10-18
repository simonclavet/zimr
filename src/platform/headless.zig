//! src/platform/headless.zig - the platform of a build with no window: a headless run, whose person is a script, and
//! the host's tests and tools, which have none.
//!
//! It keeps the time and the log, and the drawing area's size - the headless screen's in a run. What a person shares
//! with an app through a platform is kept as a platform keeps it, in memory and for the run only, so that every run
//! repeats exactly: a clipboard, saved values, grants of pointer lock and fullscreen, and the events reporting them,
//! which the run's frame driver delivers (`takeEvent`). Its gamepads are the script's, and its sound plays on the run's
//! clock, kept for a capture (`playAudioUntil`, `writeAudioCapture`). What needs a network or a person's files
//! refuses, saying so.

const std = @import("std");
const builtin = @import("builtin");
const native_os = @import("../native_os.zig");
const copyForwards = std.mem.copyForwards;
const eql = std.mem.eql;
const bufPrint = std.fmt.bufPrint;
const writeInt = std.mem.writeInt;
const ArrayList = std.ArrayList;
const Io = std.Io;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const readInt = std.mem.readInt;
const sliceAsBytes = std.mem.sliceAsBytes;
const contract = @import("contract.zig");
const console = @import("console.zig");
const host = @import("../host.zig");
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

/// How this platform's output gets its frames (`contract.AudioOutputKind`): at each frame, it asks the renderer for
/// the frames its clock has played since the last (`playAudioUntil`). Its push requests stay, for the tests of the
/// push path while other platforms still use it.
pub const audio_output_kind: AudioOutputKind = .pull_on_main_thread;
const GamepadSlot = contract.GamepadSlot;
const Gamepad = contract.Gamepad;
const Rumble = contract.Rumble;

/// Standard error, each line prefixed with its level (`console.zig`).
pub const log = console.log;

/// Windows' performance counter, in nanoseconds, from ntdll - which every Windows process has loaded, so it needs no C
/// library. Whole seconds and the remainder convert apart: the count times a billion overflows 64 bits after half an
/// hour of uptime at a 10 MHz counter.
fn windowsNow() u64 {
    var count: i64 = 0;
    var counts_per_second: i64 = 0;
    const has_count: bool = std.os.windows.ntdll.RtlQueryPerformanceCounter(&count).toBool();
    const has_rate: bool = std.os.windows.ntdll.RtlQueryPerformanceFrequency(&counts_per_second).toBool();
    if (!has_count or !has_rate or counts_per_second <= 0) {
        return 0;
    }
    const count_unsigned: u64 = @intCast(count);
    const rate: u64 = @intCast(counts_per_second);
    const whole_seconds: u64 = count_unsigned / rate;
    const remainder_counts: u64 = count_unsigned % rate;
    return whole_seconds * 1_000_000_000 + remainder_counts * 1_000_000_000 / rate;
}

/// The system's monotonic clock, in nanoseconds, read with no C library: on Windows the performance counter
/// (`windowsNow`), elsewhere `clock_gettime(CLOCK_MONOTONIC)`, a system call - or 0 on a system with neither. Windows
/// must branch first: there `std.posix.system` is the C library, whose `clock_gettime` needs libc linked.
pub fn now() u64 {
    if (comptime builtin.os.tag == .windows) {
        return windowsNow();
    }
    if (comptime !@hasDecl(std.posix.system, "clock_gettime")) {
        return 0;
    }
    var time: std.posix.timespec = undefined;
    if (std.posix.system.clock_gettime(.MONOTONIC, &time) != 0) {
        return 0;
    }
    const seconds: u64 = @intCast(time.sec);
    const nanoseconds: u64 = @intCast(time.nsec);
    return seconds * 1_000_000_000 + nanoseconds;
}

// ---- The person's side: what a headless run's script, standing in for a person, shares with the app through the
// platform - a clipboard, saved values - and the outcomes of the app's requests, waiting for the run's frame driver to
// deliver them as events (`takeEvent`), as a window's queued messages wait for its loop. A build without a run - the
// host's tests and tools - keeps them all the same, and nothing ever delivers the outcomes.

/// The most bytes the clipboard holds; a longer copy keeps its start, cut at a character boundary.
const clipboard_capacity: usize = 64 * 1024;
/// The most outcomes waiting at once; more are dropped until the driver delivers some.
const waiting_event_capacity: usize = 16;
/// The most values saved at once, and the longest key and value kept.
const saved_value_capacity: usize = 64;
const saved_key_room: usize = 128;
const saved_value_room: usize = 4096;
/// The longest title kept.
const title_room: usize = 256;

/// One saved value (`saveValue`), its key and bytes kept in place.
const SavedValue = struct {
    key_bytes: [saved_key_room]u8 = undefined,
    key_len: usize = 0,
    value_bytes: [saved_value_room]u8 = undefined,
    value_len: usize = 0,
};

// lint:off module-var: the drawing area's size, set by a headless run's frame driver
var drawing_size: Size = .{ .width = 1280, .height = 720, .scale = 1 };
// lint:off module-var: the clipboard the app and a headless run's script share
var clipboard_bytes: [clipboard_capacity]u8 = undefined;
// lint:off module-var: (see `clipboard_bytes`)
var clipboard_len: usize = 0;
// lint:off module-var: the outcomes of the app's requests, oldest first, until the frame driver delivers them
var waiting_events: [waiting_event_capacity]contract.Event = undefined;
// lint:off module-var: (see `waiting_events`)
var waiting_event_count: usize = 0;
// lint:off module-var: whether the pointer is locked, and whether the app is fullscreen, as granted
var is_pointer_locked: bool = false;
// lint:off module-var: (see `is_pointer_locked`)
var is_fullscreen: bool = false;
// lint:off module-var: whether a text field has text input on, as the app last asked
var is_text_input_on: bool = false;
// lint:off module-var: the cursor the app last asked for
var current_cursor: Cursor = .default;
// lint:off module-var: the title the app last set
var title_bytes: [title_room]u8 = undefined;
// lint:off module-var: (see `title_bytes`)
var title_len: usize = 0;
// lint:off module-var: the values the app saved, kept for the run
var saved_values: [saved_value_capacity]SavedValue = undefined;
// lint:off module-var: (see `saved_values`)
var saved_value_count: usize = 0;

/// Adds an outcome to the waiting events; dropped when they are full.
fn addWaitingEvent(event: contract.Event) void {
    if (waiting_event_count == waiting_event_capacity) {
        return;
    }
    waiting_events[waiting_event_count] = event;
    waiting_event_count += 1;
}

/// How much of `text` fits in `room` bytes, cut at a character boundary: a UTF-8 continuation byte (10xxxxxx) at the
/// cut means it would split a character, so the cut moves back.
fn keptLength(text: []const u8, room: usize) usize {
    var kept: usize = @min(text.len, room);
    while (kept > 0 and kept < text.len and text[kept] & 0xc0 == 0x80) {
        kept -= 1;
    }
    return kept;
}

/// The value saved under `key`, if any.
fn findSavedValue(key: []const u8) ?*SavedValue {
    for (saved_values[0..saved_value_count]) |*saved| {
        if (eql(u8, saved.key_bytes[0..saved.key_len], key)) {
            return saved;
        }
    }
    return null;
}

/// The drawing area: the headless screen's size once a headless run has set it (`setSize`), and before that - in the
/// host's tests and tools - 1280 by 720, a common laptop's layout. Always at scale 1: nothing shows on a monitor.
pub fn size() Size {
    return drawing_size;
}

/// Sets the drawing area's size: a headless run's frame driver sets its screen's, so the platform and the screen agree.
pub fn setSize(width: f32, height: f32) void {
    drawing_size = .{ .width = width, .height = height, .scale = 1 };
}

/// The oldest outcome waiting, taken - for a headless run's frame driver, which delivers each to the app before the
/// next frame, as a window's loop delivers its queued messages. A paste's bytes are the clipboard's: valid until the
/// app next copies, which is after it has received them.
pub fn takeEvent() ?contract.Event {
    if (waiting_event_count == 0) {
        return null;
    }
    const oldest: contract.Event = waiting_events[0];
    copyForwards(contract.Event, waiting_events[0 .. waiting_event_count - 1], waiting_events[1..waiting_event_count]);
    waiting_event_count -= 1;
    return oldest;
}

/// The clipboard's text: what the app last copied, or a run's paste last delivered.
pub fn clipboardText() []const u8 {
    return clipboard_bytes[0..clipboard_len];
}

/// Whether text input is on, as the app last asked (`startTextInput`, `stopTextInput`).
pub fn isTextInputOn() bool {
    return is_text_input_on;
}

/// The cursor the app last asked for (`setCursor`).
pub fn cursor() Cursor {
    return current_cursor;
}

/// The title the app last set (`setTitle`).
pub fn title() []const u8 {
    return title_bytes[0..title_len];
}

/// A title set, kept, cut at a character boundary when longer than `title_room`.
pub fn setTitle(text: []const u8) void {
    title_len = keptLength(text, title_room);
    @memcpy(title_bytes[0..title_len], text[0..title_len]);
}

/// Fullscreen, granted - as a browser grants it after a click - and its outcome reported when it changes.
pub fn requestFullscreen(on: bool) void {
    if (on != is_fullscreen) {
        is_fullscreen = on;
        addWaitingEvent(.{ .fullscreen_changed = on });
    }
}

/// The cursor asked for, kept (`cursor`).
pub fn setCursor(wanted: Cursor) void {
    current_cursor = wanted;
}

/// A pointer lock, granted - as a browser grants one after a click - and the grant reported.
pub fn requestPointerLock() void {
    if (!is_pointer_locked) {
        is_pointer_locked = true;
        addWaitingEvent(.{ .pointer_lock_changed = true });
    }
}

/// The lock released, and its end reported.
pub fn releasePointerLock() void {
    if (is_pointer_locked) {
        is_pointer_locked = false;
        addWaitingEvent(.{ .pointer_lock_changed = false });
    }
}

/// There is no screen to keep on: nothing to do.
pub fn keepAwake(on: bool) void {
    _ = on;
}

/// Text input on, as a text field asks: kept (`isTextInputOn`). A run types its text through its script; there is no
/// input method to compose with.
pub fn startTextInput(options: TextInputOptions) void {
    _ = options;
    is_text_input_on = true;
}

/// Where a field's text and caret are, for an input method's window: there is none to place.
pub fn setTextInputArea(area: TextInputArea) void {
    _ = area;
}

pub fn stopTextInput() void {
    is_text_input_on = false;
}

/// Text copied: kept on the clipboard the run's script shares, cut at a character boundary when longer than
/// `clipboard_capacity`.
pub fn setClipboardText(text: []const u8) void {
    clipboard_len = keptLength(text, clipboard_capacity);
    @memcpy(clipboard_bytes[0..clipboard_len], text[0..clipboard_len]);
}

/// The clipboard's text, delivered as a paste before the next frame - as a window reads its clipboard and delivers it.
/// An empty clipboard pastes nothing.
pub fn requestPaste() void {
    if (clipboard_len > 0) {
        addWaitingEvent(.{ .paste = .{ .bytes = clipboard_bytes[0..clipboard_len] } });
    }
}

/// No browser opens an address: it is logged, so a run's output shows the app asked.
pub fn openUrl(url: []const u8) void {
    var line_bytes: [600]u8 = undefined;
    const line: []const u8 = bufPrint(&line_bytes, "open {s}", .{url}) catch "open (an address too long to show)";
    log(.info, line);
}

// lint:off module-var: the folder a run keeps its saved values in, set once as the run starts
var values_folder_buffer: [512]u8 = undefined;
// lint:off module-var: its length; 0 while values are kept in memory
var values_folder_length: usize = 0;

/// Keeps the run's saved values as files in `folder` instead of in memory (the run's `ZIMR_VALUES_DIR`): each value
/// one file, as a native program keeps them (`native_os.saveValue`), so a run can carry on from what an earlier run
/// saved, and a value may be of any size. A folder too long to hold is ignored.
pub fn keepValuesIn(folder: []const u8) void {
    if (folder.len > values_folder_buffer.len) {
        return;
    }
    @memcpy(values_folder_buffer[0..folder.len], folder);
    values_folder_length = folder.len;
}

/// The folder the run keeps its saved values in, or null when they are kept in memory.
fn valuesFolder() ?[]const u8 {
    return if (values_folder_length > 0) values_folder_buffer[0..values_folder_length] else null;
}

/// The saved value of `key`, copied into `buffer`; null when none is saved, or `buffer` is too small. Values are kept
/// for the run, in memory, so every run starts with none - and repeats exactly - unless the run names a folder to
/// keep them in (`keepValuesIn`).
pub fn loadValue(key: []const u8, buffer: []u8) ?[]u8 {
    if (valuesFolder()) |folder| {
        return native_os.loadValueIn(native_os.servicesIo(), folder, key, buffer);
    }
    const saved: *SavedValue = findSavedValue(key) orelse return null;
    if (saved.value_len > buffer.len) {
        return null;
    }
    @memcpy(buffer[0..saved.value_len], saved.value_bytes[0..saved.value_len]);
    return buffer[0..saved.value_len];
}

/// Saves `bytes` under `key`, for the run; dropped when the key or the value is too long, or every slot is taken.
/// In a run's folder (`keepValuesIn`), saved as a file, of any size.
pub fn saveValue(key: []const u8, bytes: []const u8) void {
    if (valuesFolder()) |folder| {
        native_os.saveValueIn(native_os.servicesIo(), folder, key, bytes);
        return;
    }
    const fits: bool = key.len <= saved_key_room and bytes.len <= saved_value_room;
    if (!fits) {
        return;
    }
    const saved: *SavedValue = findSavedValue(key) orelse slot: {
        if (saved_value_count == saved_value_capacity) {
            return;
        }
        const added: *SavedValue = &saved_values[saved_value_count];
        saved_value_count += 1;
        added.* = .{};
        @memcpy(added.key_bytes[0..key.len], key);
        added.key_len = key.len;
        break :slot added;
    };
    @memcpy(saved.value_bytes[0..bytes.len], bytes);
    saved.value_len = bytes.len;
}

/// Removes the value saved under `key`, if any.
pub fn removeValue(key: []const u8) void {
    if (valuesFolder()) |folder| {
        native_os.removeValueIn(native_os.servicesIo(), folder, key);
        return;
    }
    const saved: *SavedValue = findSavedValue(key) orelse return;
    const index: usize = (@intFromPtr(saved) - @intFromPtr(&saved_values[0])) / @sizeOf(SavedValue);
    saved_values[index] = saved_values[saved_value_count - 1];
    saved_value_count -= 1;
}

// ---- Sound, played on the run's clock ----
//
// A headless run's output plays exactly as the run's clock moves - the frames' times, which the script gives - not as
// a device's clock would. So the same script plays the same sound, sample for sample, on every run, and a capture of
// it (`writeAudioCapture`) can be compared, or measured, as a captured frame can. The run's frame driver calls
// `playAudioUntil` with each frame's time, before the engine's update: the output asks the mixer's renderer for the
// frames that came due since the last frame, as a device asks for each block it needs, and keeps them.

/// The most played frames kept for a capture: the last two minutes, about 46 MB at 48 kHz stereo. A run playing longer
/// keeps the newest; the oldest are dropped in batches, once ten seconds more have gathered, so that dropping them -
/// moving the rest to the front - happens once in ten seconds, not every frame.
const audio_kept_most_frames: usize = 48_000 * 120;
const audio_kept_slack_frames: usize = 48_000 * 10;

/// The output's state: the format granted, when it started on the run's clock, the renderer it asks for frames, and
/// the samples played (the last two minutes of them).
const HeadlessAudio = struct {
    /// The format granted by `startAudioPull`; null while the output is stopped.
    format: ?AudioFormat = null,
    /// The run's clock, in milliseconds, when the output started playing: playing counts its frames from there. An
    /// output started between frames - in an app's `init`, say, before the first frame - starts playing on the next
    /// frame's time, as a device starts when it first runs: until then this is null, and nothing is due.
    started_at_ms: ?f64 = null,
    /// The samples played, interleaved, the last two minutes of them (`trimPlayedSamples`).
    played_samples: ArrayList(f32) = .empty,
    /// Whether older samples were dropped: the run said so once, and a capture holds the newest only.
    has_dropped_played_samples: bool = false,
    /// How many frames have played since the start.
    played_frame_count: u64 = 0,
    /// The renderer asked for the frames (`startAudioPull`); null while the output is stopped.
    render_callback: ?AudioRenderCallback = null,
    /// The run's clock as the last frame set it (`playAudioUntil`): the time sound is stamped with
    /// (`audioClockMilliseconds`).
    clock_ms: f64 = 0,
};

// lint:off module-var: the headless output and what it has played, for the run only
var audio_output: HeadlessAudio = .{};

/// The clock sound is timed by: the run's own, as its frames move it - a run's sound is timed as its frames are.
pub fn audioClockMilliseconds() f64 {
    return audio_output.clock_ms;
}

/// Nothing lies past a headless run's output: a frame played is a frame captured.
pub fn audioOutputLatencyMilliseconds() f64 {
    return 0;
}

pub fn audioOutputName() []const u8 {
    return "headless, the run's clock";
}

/// Opens the output at exactly the format asked for - a run can play any - with nothing played yet; it starts playing
/// on the next frame's time (`started_at_ms`). At each frame it asks `render_callback` for the frames its clock has
/// played since the last (`playAudioUntil`), as a device asks for each block it needs. Rendering at a frame's time
/// the frames up to it, a sound started by that frame's update is rendered from that time on, at the next frame: the
/// capture shows each sound at its frame's own time.
pub fn startAudioPull(wanted: AudioFormat, render_callback: AudioRenderCallback) AudioFormat {
    audio_output.played_samples.clearRetainingCapacity();
    audio_output.has_dropped_played_samples = false;
    audio_output.played_frame_count = 0;
    audio_output.started_at_ms = null;
    audio_output.render_callback = render_callback;
    audio_output.format = wanted;
    return wanted;
}

/// Closes the output: no frame plays, and the renderer is not called, until it starts again.
pub fn stopAudio() void {
    audio_output.format = null;
    audio_output.render_callback = null;
}

/// Keeps at most `most_frames` played frames, the newest: once the samples kept exceed that by `slack_frames`, the
/// oldest are dropped and the rest moved to the front - in one move per `slack_frames`, rather than one per frame.
fn trimPlayedSamples(
    most_frames: usize,
    slack_frames: usize,
    channel_count: usize,
) void {
    const kept_sample_count: usize = audio_output.played_samples.items.len;
    const most_samples: usize = most_frames * channel_count;
    const trim_threshold_samples: usize = most_samples + slack_frames * channel_count;
    if (kept_sample_count <= trim_threshold_samples) {
        return;
    }
    const dropped_sample_count: usize = kept_sample_count - most_samples;
    const newest_samples: []const f32 = audio_output.played_samples.items[dropped_sample_count..];
    copyForwards(f32, audio_output.played_samples.items[0..most_samples], newest_samples);
    audio_output.played_samples.shrinkRetainingCapacity(most_samples);
    if (!audio_output.has_dropped_played_samples) {
        audio_output.has_dropped_played_samples = true;
        console.log(.info, "headless audio: a capture keeps the last two minutes played");
    }
}

/// Plays the output up to `frame_ms` on the run's clock. The frames due since the start are
/// `floor(elapsed ms x frames a second / 1000)` - counted from the start each time, not added up frame by frame, so
/// that no fraction of a frame is lost between frames: 60 frames of 1000/60 ms each play exactly 48 000 frames at
/// 48 kHz. Those not yet played are rendered now, in place where they are kept, by the renderer the output was
/// started with. Called by the run's frame driver, once a frame.
pub fn playAudioUntil(frame_ms: f64) void {
    audio_output.clock_ms = frame_ms;
    const output_format: AudioFormat = audio_output.format orelse return;
    const render_callback: AudioRenderCallback = audio_output.render_callback orelse return;
    const started_at_ms: f64 = audio_output.started_at_ms orelse {
        // The first frame since the output started: it starts playing now, so nothing is due yet.
        audio_output.started_at_ms = frame_ms;
        return;
    };
    const elapsed_since_start_ms: f64 = @max(frame_ms - started_at_ms, 0);
    const frames_per_second: f64 = @floatFromInt(output_format.sample_rate);
    const frames_due_since_start: u64 = @floor(elapsed_since_start_ms * frames_per_second / 1000.0);
    if (frames_due_since_start <= audio_output.played_frame_count) {
        return;
    }
    const channel_count: usize = output_format.channels;
    const frames_to_play_now: usize = @intCast(frames_due_since_start - audio_output.played_frame_count);
    const sample_count_now: usize = frames_to_play_now * channel_count;
    const first_new_sample: usize = audio_output.played_samples.items.len;
    audio_output.played_samples.appendNTimes(host.heap, 0, sample_count_now) catch {
        console.log(.err, "headless audio: out of memory keeping what played");
        return;
    };
    // The frames rendered are those that came due since the last frame: the first of them was out when the run's
    // clock passed it, a little before now.
    const played_until_now_ms: f64 = float64(audio_output.played_frame_count) * 1000.0 / frames_per_second;
    const timing: AudioRenderTiming = .{
        .asked_at_ms = frame_ms,
        .first_frame_out_ms = started_at_ms + played_until_now_ms,
    };
    const new_samples: []f32 = audio_output.played_samples.items[first_new_sample..];
    render_callback.render(render_callback.context, new_samples, timing);
    audio_output.played_frame_count = frames_due_since_start;
    trimPlayedSamples(audio_kept_most_frames, audio_kept_slack_frames, channel_count);
}

/// Every sample played since the output started, interleaved.
pub fn playedAudio() []const f32 {
    return audio_output.played_samples.items;
}

/// A RIFF/WAVE header for `frame_count` frames of 32-bit float samples at `format`: the RIFF chunk holding the WAVE
/// form; its `fmt ` chunk - format 3 (IEEE float), the channels, the frames a second, the bytes a second, the bytes a
/// frame, the bits a sample; then the `data` chunk's header, its samples following it. Every number is little-endian.
/// Written here rather than by `codecs`: the codecs import the platform layer, so the platform cannot import them.
fn floatWaveHeader(format: AudioFormat, frame_count: usize) [44]u8 {
    const bytes_per_sample: u32 = 4;
    const bytes_per_frame: u32 = bytes_per_sample * format.channels;
    const bytes_per_second: u32 = format.sample_rate * bytes_per_frame;
    const data_byte_count: u32 = @intCast(frame_count * bytes_per_frame);
    // The RIFF chunk's size counts what follows its own 8-byte header: "WAVE", the 24-byte `fmt ` chunk and the 8-byte
    // `data` header - 36 bytes - and the samples.
    const riff_chunk_size: u32 = 36 + data_byte_count;
    const fmt_chunk_size: u32 = 16;
    const ieee_float_format: u16 = 3;
    const bits_per_sample: u16 = 32;
    var header: [44]u8 = undefined;
    @memcpy(header[0..4], "RIFF");
    writeInt(u32, header[4..8], riff_chunk_size, .little);
    @memcpy(header[8..12], "WAVE");
    @memcpy(header[12..16], "fmt ");
    writeInt(u32, header[16..20], fmt_chunk_size, .little);
    writeInt(u16, header[20..22], ieee_float_format, .little);
    writeInt(u16, header[22..24], format.channels, .little);
    writeInt(u32, header[24..28], format.sample_rate, .little);
    writeInt(u32, header[28..32], bytes_per_second, .little);
    writeInt(u16, header[32..34], @intCast(bytes_per_frame), .little);
    writeInt(u16, header[34..36], bits_per_sample, .little);
    @memcpy(header[36..40], "data");
    writeInt(u32, header[40..44], data_byte_count, .little);
    return header;
}

/// Writes everything played since the output started as a 32-bit float WAV file at `path`. With no output started, a
/// WAV of no frames at 48 000 Hz stereo, so that a capture always makes a file.
pub fn writeAudioCapture(io: Io, path: []const u8) !void {
    const no_output_format: AudioFormat = .{ .sample_rate = 48_000, .channels = 2 };
    const capture_format: AudioFormat = audio_output.format orelse no_output_format;
    const played_frame_count: usize = audio_output.played_samples.items.len / capture_format.channels;
    const header: [44]u8 = floatWaveHeader(capture_format, played_frame_count);
    const capture_file: Io.File = try Io.Dir.cwd().createFile(io, path, .{});
    defer capture_file.close(io);
    try capture_file.writeStreamingAll(io, &header);
    try capture_file.writeStreamingAll(io, sliceAsBytes(audio_output.played_samples.items));
}

/// The gamepads a run's script holds: none until it connects one (`setScriptedGamepad`).
const scripted_slot_count: usize = 4;
// lint:off module-var: the gamepads the run's script holds, by slot
var scripted_gamepads: [scripted_slot_count]?Gamepad = @splat(null);
// lint:off module-var: the last rumble each slot was asked for, kept for a run to read back
var scripted_rumbles: [scripted_slot_count]?Rumble = @splat(null);

/// Connects, changes or - with null - disconnects the gamepad in a slot, as a run's script says.
pub fn setScriptedGamepad(slot: GamepadSlot, pad: ?Gamepad) void {
    if (slot < scripted_slot_count) {
        scripted_gamepads[slot] = pad;
    }
}

/// The gamepad a run's script holds in a slot; null for none.
pub fn gamepad(slot: GamepadSlot) ?Gamepad {
    if (slot >= scripted_slot_count) {
        return null;
    }
    return scripted_gamepads[slot];
}

/// Nothing to shake: the rumble asked for is kept (`lastRumble`) and said in the log, for a run to see.
pub fn setGamepadRumble(slot: GamepadSlot, rumble: Rumble) void {
    if (slot < scripted_slot_count) {
        scripted_rumbles[slot] = rumble;
    }
    var line_bytes: [96]u8 = undefined;
    const line: []const u8 = bufPrint(&line_bytes, "gamepad {d} rumbles: heavy {d:.2}, light {d:.2}, {d} ms", .{
        slot,
        rumble.low,
        rumble.high,
        rumble.milliseconds,
    }) catch "gamepad rumbles";
    console.log(.info, line);
}

/// The last rumble a slot was asked for.
pub fn lastRumble(slot: GamepadSlot) ?Rumble {
    if (slot >= scripted_slot_count) {
        return null;
    }
    return scripted_rumbles[slot];
}

// The requests written here, compiled in every build that runs on this platform - so a mistake in one fails the build
// before the engine calls it. A refusal cannot be named: compiling it is the refusal.
comptime {
    _ = &log;
    _ = &now;
    _ = &size;
}

/// A headless build has no person to hand it files, nor to choose where one is saved: the queue stays empty.
pub fn pendingFileCount() u32 {
    return 0;
}

pub fn nextFileSize() u32 {
    return 0;
}

pub fn nextFileName(out: []u8) u32 {
    _ = out;
    return 0;
}

pub fn readNextFile(out: []u8) u32 {
    _ = out;
    return 0;
}

pub fn discardNextFile() void {}

pub fn setFilePickerArea(area: contract.ButtonArea, accept: []const u8) void {
    _ = area;
    _ = accept;
}

pub fn hideFilePicker() void {}

pub fn offerFile(bytes: []const u8, name: []const u8) void {
    _ = bytes;
    _ = name;
}

pub fn setSaveArea(area: contract.ButtonArea) void {
    _ = area;
}

pub fn hideSave() void {}

/// A headless build has no network, so that its runs repeat exactly: no socket opens, and every handle reads closed.
pub fn openSocket(url: []const u8) u32 {
    _ = url;
    return 0;
}

pub fn socketState(handle: u32) contract.SocketState {
    _ = handle;
    return .closed;
}

pub fn sendSocket(handle: u32, bytes: []const u8) void {
    _ = handle;
    _ = bytes;
}

pub fn pollSocket(handle: u32, out: []u8) ?[]const u8 {
    _ = handle;
    _ = out;
    return null;
}

pub fn closeSocket(handle: u32) void {
    _ = handle;
}

pub fn socketOriginUrl(out: []u8) []const u8 {
    return out[0..0];
}

/// A headless build's wall clock stands at the epoch, for the same reason.
pub fn epochMillis() f64 {
    return 0;
}

/// One monitor: the drawing area itself - the headless screen in a run - at scale 1 and 60 hertz, the rate a run's
/// frames are given at.
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
        .width = drawing_size.width,
        .height = drawing_size.height,
        .scale = 1,
        .refresh_hz = 60,
        .is_primary = true,
    };
    described.setName("headless screen");
    return described;
}

pub fn currentMonitor() u32 {
    return 0;
}

// A headless run's window is its screen, which nothing shows: its placement is kept as asked, for a run to read back
// (`windowShow`, `windowPlacement`, `windowSizeLimits`), and changes nothing drawn.

/// Where a headless window was last placed (`setWindowPosition`).
pub const WindowPlacement = struct {
    monitor_index: u32 = 0,
    x: f32 = 0,
    y: f32 = 0,
};

// lint:off module-var: how the window is shown, as last asked
var window_show: contract.WindowShow = .normal;
// lint:off module-var: the window's placement, as last asked: a monitor, and a position on it
var window_placement: WindowPlacement = .{};
// lint:off module-var: the drawing area's size limits, as last asked
var window_size_limits: contract.SizeLimits = .{};

pub fn showWindow(show: contract.WindowShow) void {
    window_show = show;
}

/// Nothing to bring to the front: a headless window has the keyboard's focus from the start.
pub fn focusWindow() void {}

pub fn setWindowPosition(monitor_index: u32, x: f32, y: f32) void {
    window_placement = .{ .monitor_index = monitor_index, .x = x, .y = y };
}

pub fn setWindowSizeLimits(limits: contract.SizeLimits) void {
    window_size_limits = limits;
}

pub fn windowShow() contract.WindowShow {
    return window_show;
}

pub fn windowPlacement() WindowPlacement {
    return window_placement;
}

pub fn windowSizeLimits() contract.SizeLimits {
    return window_size_limits;
}

/// A key's label: the US layout's, since a headless run's keyboard is its script, whose keys are named by position.
pub fn keyName(key: contract.KeyboardKey, buffer: []u8) ?[]const u8 {
    return contract.usKeyName(key, buffer);
}

/// A test renderer: fills each block with its call's number over 8 - the first block 0.125, the second 0.25 - and
/// keeps the frames it rendered and the timing it was last given.
const TestRenderer = struct {
    call_count: u32 = 0,
    frames_rendered: usize = 0,
    last_timing: ?AudioRenderTiming = null,

    fn render(context: *anyopaque, samples: []f32, timing: AudioRenderTiming) void {
        const test_renderer: *TestRenderer = @ptrCast(@alignCast(context));
        test_renderer.call_count += 1;
        test_renderer.frames_rendered += samples.len / 2;
        test_renderer.last_timing = timing;
        const call_number: f32 = @floatFromInt(test_renderer.call_count);
        @memset(samples, call_number / 8);
    }
};

test "headless audio is pulled on the run's clock: each frame renders the frames due since the last" {
    var test_renderer: TestRenderer = .{};
    const render_callback: AudioRenderCallback = .{ .context = &test_renderer, .render = &TestRenderer.render };
    const granted: AudioFormat = startAudioPull(.{ .sample_rate = 48_000, .channels = 2 }, render_callback);
    try expectEqual(@as(u32, 48_000), granted.sample_rate);
    // The first frame after the start: the output starts playing at its time, 0 ms, with nothing due yet.
    playAudioUntil(0);
    try expectEqual(@as(u32, 0), test_renderer.call_count);
    // 10 ms at 48 kHz: 480 frames, in one block asked for at 10 ms, its first frame out at 0 ms.
    playAudioUntil(10);
    try expectEqual(@as(usize, 480), test_renderer.frames_rendered);
    try expectEqual(@as(f64, 10), test_renderer.last_timing.?.asked_at_ms);
    try expectEqual(@as(f64, 0), test_renderer.last_timing.?.first_frame_out_ms);
    // 30 ms in all: 960 frames more, their first out at 10 ms.
    playAudioUntil(30);
    try expectEqual(@as(usize, 1440), test_renderer.frames_rendered);
    try expectEqual(@as(f64, 10), test_renderer.last_timing.?.first_frame_out_ms);
    const played: []const f32 = playedAudio();
    try expectEqual(@as(usize, 1440 * 2), played.len);
    try expectEqual(@as(f32, 0.125), played[0]);
    try expectEqual(@as(f32, 0.25), played[1439 * 2]);
    // Stopped: the renderer is not asked again.
    stopAudio();
    playAudioUntil(60);
    try expectEqual(@as(u32, 2), test_renderer.call_count);
}

test "a float WAV header says its format and length" {
    const header: [44]u8 = floatWaveHeader(.{ .sample_rate = 48_000, .channels = 2 }, 100);
    try expectEqualStrings("RIFF", header[0..4]);
    try expectEqual(@as(u16, 3), readInt(u16, header[20..22], .little));
    try expectEqual(@as(u32, 48_000), readInt(u32, header[24..28], .little));
    try expectEqual(@as(u32, 800), readInt(u32, header[40..44], .little));
}

test "the headless output keeps the newest played frames, dropping the oldest in batches" {
    var test_renderer: TestRenderer = .{};
    const render_callback: AudioRenderCallback = .{ .context = &test_renderer, .render = &TestRenderer.render };
    _ = startAudioPull(.{ .sample_rate = 48_000, .channels = 2 }, render_callback);
    playAudioUntil(0);
    // Frames whose samples count up, frame n holding n and -n.
    var frame_number: usize = 0;
    while (frame_number < 30) : (frame_number += 1) {
        const value: f32 = @floatFromInt(frame_number);
        try audio_output.played_samples.appendSlice(host.heap, &.{ value, -value });
    }
    // At most 10 frames, with a slack of 5: 30 frames exceed 15, so they are cut to the newest 10.
    trimPlayedSamples(10, 5, 2);
    try expectEqual(@as(usize, 20), audio_output.played_samples.items.len);
    try expectEqual(@as(f32, 20), audio_output.played_samples.items[0]);
    try expectEqual(@as(f32, -29), audio_output.played_samples.items[19]);
    // Within the slack, nothing moves.
    try audio_output.played_samples.appendSlice(host.heap, &.{ 30, -30, 31, -31 });
    trimPlayedSamples(10, 5, 2);
    try expectEqual(@as(usize, 24), audio_output.played_samples.items.len);
    stopAudio();
}
