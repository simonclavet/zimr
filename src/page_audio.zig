//! src/page_audio.zig - the page's sound output: the browser's side of the mixer's output, between the app's module
//! and the Web Audio API.
//!
//! A page plays its sound one of two ways, chosen when the page boots:
//!
//!     the renderer worklet   the app's own module, a second instance of it, runs the mixer's renderer in an audio
//!                            worklet (`audio_worklet.zig`); the mixer forwards each frame's commands, samples and
//!                            notes to it as messages, and reads the notices it sends back
//!     the script processor   where no worklet can load - a page whose origin is opaque, as in an app's file viewer -
//!                            a script processor on the main thread asks the app's module for each block it plays
//!                            (`zimr_audio_pull_block`, the mixer's own renderer)
//!
//! Which one is known only once the worklet's module has loaded or failed to, and loading is asynchronous
//! (`audioWorklet.addModule`), while the mixer must know at its start which path it takes. So the page starts loading
//! while the app's module instantiates, and the boot waits, before the app's `init`, until the loading has settled
//! (`isRendererSettled`): first from a Blob URL, then, if that fails, from a `data:` URL; a page that loads neither
//! plays through the script processor.
//!
//! This file is the bridge's (`bridge.zig` imports it, and its `dom` import answers call these functions), kept apart
//! from the bridge's one file, as `dom_input.zig` is, so that it can be tested: written against the c2js runtime's
//! handle functions rather than the bridge's `Value`, it transpiles on its own, and
//! `tools/c2js_cases/audio_page_test.cjs` runs it in Node against stand-ins for the browser's audio as strict as
//! Chrome.
//!
//! Handles. Each JavaScript value this file touches is a handle into the c2js runtime's table. A callback the browser
//! calls - a port's message, a script processor's block, a gesture - opens a scope (`js_mark`) and closes it
//! (`js_reset`) before returning, so that the handles it made are reclaimed; what must outlive the callback is kept by
//! a JavaScript object - the held notices are an array, which keeps the arrays put into it, though their handles go.
//! The state's own handles are made outside every scope - at boot, or in a call the app's module makes during a frame,
//! which the page's frame loop does not reclaim - and live as long as the page.

const std = @import("std");
const expectEqualStrings = std.testing.expectEqualStrings;

/// A handle into the c2js runtime's table of JavaScript values; 0 is none.
const Handle = u32;

// ---- The c2js runtime's functions this file calls (`tools/c2js.zig`, its kernel) ----
extern fn js_global() Handle;
extern fn js_get(object: Handle, name_pointer: [*]const u8, name_length: u32) Handle;
extern fn js_get_num(object: Handle, name_pointer: [*]const u8, name_length: u32) f64;
extern fn js_set(
    object: Handle,
    name_pointer: [*]const u8,
    name_length: u32,
    value: Handle,
) void;
extern fn js_get_index(object: Handle, index: u32) Handle;
extern fn js_len(value: Handle) u32;
extern fn js_set_num(
    object: Handle,
    name_pointer: [*]const u8,
    name_length: u32,
    number: f64,
) void;
extern fn js_set_index(object: Handle, index: u32, value: Handle) void;
extern fn js_call0(object: Handle, name_pointer: [*]const u8, name_length: u32) Handle;
extern fn js_call1(
    object: Handle,
    name_pointer: [*]const u8,
    name_length: u32,
    first_argument: Handle,
) Handle;
extern fn js_call3(
    object: Handle,
    name_pointer: [*]const u8,
    name_length: u32,
    first_argument: Handle,
    second_argument: Handle,
    third_argument: Handle,
) Handle;
/// Writes `value` as UTF-8 at `destination`, at most `capacity` bytes; returns the bytes written.
extern fn js_string_into(value: Handle, destination: [*]u8, capacity: u32) u32;
extern fn js_call2(
    object: Handle,
    name_pointer: [*]const u8,
    name_length: u32,
    first_argument: Handle,
    second_argument: Handle,
) Handle;
/// The same calls with their result dropped, so that no handle is made for it - a call returning `undefined` would
/// otherwise make a handle `js_free` never frees.
extern fn js_call0v(object: Handle, name_pointer: [*]const u8, name_length: u32) void;
extern fn js_call1v(
    object: Handle,
    name_pointer: [*]const u8,
    name_length: u32,
    first_argument: Handle,
) void;
extern fn js_call2v(
    object: Handle,
    name_pointer: [*]const u8,
    name_length: u32,
    first_argument: Handle,
    second_argument: Handle,
) void;
extern fn js_call3v(
    object: Handle,
    name_pointer: [*]const u8,
    name_length: u32,
    first_argument: Handle,
    second_argument: Handle,
    third_argument: Handle,
) void;
extern fn js_new1(constructor: Handle, first_argument: Handle) Handle;
extern fn js_new2(
    constructor: Handle,
    first_argument: Handle,
    second_argument: Handle,
) Handle;
extern fn js_new3(
    constructor: Handle,
    first_argument: Handle,
    second_argument: Handle,
    third_argument: Handle,
) Handle;
/// `new constructor(argument)`, or 0 when it throws.
extern fn js_try_new1(constructor: Handle, first_argument: Handle) Handle;
extern fn js_obj() Handle;
extern fn js_array() Handle;
/// Appends `value` to `array`, and returns `array`'s own handle - not a new one, never to be freed apart from it.
extern fn js_push(array: Handle, value: Handle) Handle;
extern fn js_str(text_pointer: [*]const u8, text_length: u32) Handle;
extern fn js_num(number: f64) Handle;
extern fn js_to_num(value: Handle) f64;
extern fn js_truthy(value: Handle) u32;
extern fn js_strict_eq(first: Handle, second: Handle) u32;
extern fn js_undefined() Handle;
/// A JavaScript function calling the Zig function `function`: its arguments arrive as handles, freed after the call.
extern fn js_func(function: *const anyopaque) Handle;
extern fn js_free(value: Handle) void;
extern fn js_mark() Handle;
/// The handle table's length, for the panel: `js_mark` would open a scope.
extern fn js_table_length() u32;
/// Turns the runtime's debugging of handles on (1) or off (0), in this realm (`setHandleDebugging`).
extern fn js_set_handle_debugging(is_on: u32) void;
/// The live handles counted by where they were made, the `limit` most first, as text.
extern fn js_handle_census(limit: u32) Handle;
extern fn js_reset(mark: Handle) void;
/// Pins a handle: a scope's reset - the frame's - leaves it, until `js_free` releases it.
extern fn js_pin(handle: Handle) void;

// ---- Helpers over the handles ----

/// `object[name]`.
fn property(object: Handle, comptime name: []const u8) Handle {
    return js_get(object, name.ptr, name.len);
}

/// `value`, or 0 for NaN - what a missing number property reads as (`baseLatency` in an older browser).
fn finiteOrZero(value: f64) f64 {
    const is_nan: bool = value != value;
    return if (is_nan) 0 else value;
}

/// `+object[name]`.
fn numberProperty(object: Handle, comptime name: []const u8) f64 {
    return js_get_num(object, name.ptr, name.len);
}

/// `object[name] = value`.
fn setProperty(object: Handle, comptime name: []const u8, value: Handle) void {
    js_set(object, name.ptr, name.len, value);
}

/// `object[name] = number`, with no handle for the number.
fn setNumberProperty(object: Handle, comptime name: []const u8, number: f64) void {
    js_set_num(object, name.ptr, name.len, number);
}

/// A JavaScript string of `text`.
fn string(text: []const u8) Handle {
    return js_str(text.ptr, @intCast(text.len));
}

/// `object.name()`: the result as a handle.
fn call0(object: Handle, comptime name: []const u8) Handle {
    return js_call0(object, name.ptr, name.len);
}

/// `object.name(argument)`, `object.name(first, second)`: the result as a handle.
fn call1(object: Handle, comptime name: []const u8, argument: Handle) Handle {
    return js_call1(object, name.ptr, name.len, argument);
}

fn call2(
    object: Handle,
    comptime name: []const u8,
    first: Handle,
    second: Handle,
) Handle {
    return js_call2(object, name.ptr, name.len, first, second);
}

/// The same calls, for a result that is not wanted.
fn callVoid0(object: Handle, comptime name: []const u8) void {
    js_call0v(object, name.ptr, name.len);
}

fn callVoid1(object: Handle, comptime name: []const u8, argument: Handle) void {
    js_call1v(object, name.ptr, name.len, argument);
}

fn callVoid2(
    object: Handle,
    comptime name: []const u8,
    first: Handle,
    second: Handle,
) void {
    js_call2v(object, name.ptr, name.len, first, second);
}

fn callVoid3(
    object: Handle,
    comptime name: []const u8,
    first: Handle,
    second: Handle,
    third: Handle,
) void {
    js_call3v(object, name.ptr, name.len, first, second, third);
}

/// `handle`, pinned (`js_pin`): page audio's handles are kept for the page's life, and some are made inside a frame -
/// the output started by the app's first frame, the panel shown at a tap - whose handle scope would otherwise reclaim
/// them as it ends.
fn kept(handle: Handle) Handle {
    js_pin(handle);
    return handle;
}

/// A global by its name: `AudioContext`, `Blob`, `URL`.
fn globalNamed(comptime name: []const u8) Handle {
    return property(js_global(), name);
}

/// Whether `value` is the string `text`.
fn isString(value: Handle, comptime text: []const u8) bool {
    const text_value: Handle = string(text);
    defer js_free(text_value);
    return js_strict_eq(value, text_value) == 1;
}

/// The page's clock, `performance.now()`, in milliseconds.
fn pageClockMilliseconds() f64 {
    const performance: Handle = globalNamed("performance");
    defer js_free(performance);
    const now: Handle = call0(performance, "now");
    defer js_free(now);
    return js_to_num(now);
}

// ---- The state ----

/// Which path plays the sound now.
pub const OutputPath = enum {
    /// No output started.
    none,
    /// The renderer worklet: the mixer forwards to it.
    renderer_worklet,
    /// The script processor: it pulls from the app's own renderer.
    script_processor,
};

/// Where the renderer worklet's module stands.
pub const RendererLoading = enum {
    /// Not asked for: before the boot asks, or for an app that plays no sound.
    not_asked,
    /// Loading from a Blob URL.
    loading_from_blob,
    /// The Blob URL failed; loading from a `data:` URL.
    loading_from_data_url,
    /// Loaded: the mixer can forward to it.
    loaded,
    /// Neither URL loaded, or the browser has no audio worklet: the script processor plays.
    unavailable,
};

/// The renderer worklet's processor, once its node exists: what it reported of its start (`{ kind: "ready" }`,
/// `{ kind: "failed" }`), or what the node reported of it (`processorerror`).
pub const ProcessorState = enum { none, starting, running, failed };

/// The renderer's last report (`{ kind: "stats", blocks, peak, frame }`), and when it came, on the page's clock.
const RendererReport = struct {
    block_count: f64,
    loudest_sample: f64,
    /// The clicks the renderer's watch has counted since the page started (`Renderer.watchForClicks`), and the largest
    /// jump in the sound's slope it has seen: a jump over 0.02 is a click.
    click_count: f64,
    largest_jump: f64,
    /// The samples the mix clipped since the page started: past full scale, held at it - distortion.
    clipped_count: f64,
    worklet_frame: f64,
    received_at_ms: f64,
    /// What the second's blocks took, on the worklet's clock: the longest call, their mean - the renderer's usual cost,
    /// against the 2.67 ms a block of 128 frames lasts - and the longest gap from one block's start to the next's.
    longest_block_ms: f64,
    mean_block_ms: f64,
    longest_gap_ms: f64,
    /// The worklet's handle table's length, read as it sent the report: steady while nothing in the audio thread's
    /// realm leaks.
    worklet_handle_count: f64,
    /// Whether the worklet's clock counts whole milliseconds - `Date`, where the browser gives a worklet no
    /// `performance` - so that a block's time reads 0 or 1 whatever it took, and only says it was under 2 ms.
    is_worklet_clock_coarse: bool,
};

/// Whether the output plays without a break, read from the browser's own map of what it plays when
/// (`AudioContext.getOutputTimestamp`): a pair of times, `contextTime` - a point of the context's timeline, the frames
/// the renderer made - and `performanceTime` - when the speaker plays it, on the page's clock. While the output plays
/// the rendered frames back to back, the two move together, and their difference stays put. When the renderer is late
/// - its block not ready when the device asks - the browser plays silence in its place: the speaker's time moves on
/// and the timeline's does not, and the difference grows by exactly the silence played. A browser that buffers more
/// after such a gap does not move it: playing from a deeper buffer is still playing frame after frame.
///
///     the offset, performanceTime - 1000 x contextTime, read every 250 ms:
///         4012.3   4012.3   4012.4   4021.6   4021.6     a step of 9.2 ms: 9.2 ms of silence, one dropout
///
/// So a rise is a dropout, its height the silence heard. But the speaker's time is the browser's estimate of when a
/// frame is played, and an output that reports its position in chunks - a Bluetooth link does - makes it jitter, up and
/// down by more than a block. A rise from jitter falls back; a rise from silence stays, since silence played cannot be
/// taken back. So a dropout is counted only when the offset rises above the highest it has been, by the threshold: a
/// jitter that falls and comes back to the same top is not counted again. The top sinks slowly - 0.1 ms a second -
/// so that the drift between two clocks, the device's and the page's, tens of parts per million, never adds up to a
/// rise. Two numbers tell the rest: the offset's net shift since the first reading - every dropout's silence adds to
/// it, every jitter cancels out of it - and its largest fall between two readings, which no silence can make: jitter,
/// measured. Dropouts closer together than the readings count as one.
const OutputContinuity = struct {
    /// Whether a reading was taken while the context ran; cleared when it stops, so that a pause is no dropout.
    has_reading: bool = false,
    /// The offset last read, and the speaker's time of the first and the last readings, in milliseconds.
    last_offset_ms: f64 = 0,
    first_reading_ms: f64 = 0,
    last_reading_ms: f64 = 0,
    dropout_count: u32 = 0,
    /// The silence played in all the dropouts, and the speaker's time of the last one.
    silence_ms: f64 = 0,
    last_dropout_ms: f64 = 0,
    /// The offset of the first reading; the highest the offset has been, sinking slowly (`offset_top_sink_ms_per_s`);
    /// and the largest fall between two readings.
    first_offset_ms: f64 = 0,
    offset_top_ms: f64 = 0,
    largest_fall_ms: f64 = 0,
};

/// How fast the offset's top sinks, in milliseconds a second (`OutputContinuity`): ten times the drift two clocks
/// show, and a hundredth of a block in a second.
const offset_top_sink_ms_per_s: f64 = 0.1;

/// The smallest step of the output's offset counted as a dropout (`OutputContinuity`): 2 ms, below one block of the
/// renderer (128 frames, 2.7 ms at 48 000 Hz) - the least a late renderer leaves out - and above the jitter of the
/// browser's estimate of when a frame is played.
const dropout_threshold_ms: f64 = 2;

/// The most bytes of a report the panel shows.
const last_report_capacity: usize = 200;

/// Everything the page's sound output holds. Its handles are made outside every handle scope (see this file's head)
/// and kept for the page's life; 0 where there is none yet.
const PageAudio = struct {
    /// The audio context: made at boot for the renderer worklet, or by the script processor's start.
    context: Handle = 0,
    /// The app's compiled module, handed to the worklet's processor (`processorOptions.module`).
    app_module: Handle = 0,
    /// The app's instance's exports: its memory, which the forwarded commands and samples are copied from and the
    /// notices into, and the script processor's `zimr_audio_pull_block` (`setAppExports`).
    app_exports: Handle = 0,
    /// The worklet's program, as the page embeds it (`ZIMR_AUDIO_WORKLET_JS`), with its `start()` call appended.
    module_source: Handle = 0,
    /// The Blob URL the module loads from first, revoked once the loading settles.
    blob_url: Handle = 0,
    loading: RendererLoading = .not_asked,
    /// The node playing now - the renderer worklet's, or the script processor - and the path it is.
    node: Handle = 0,
    path: OutputPath = .none,
    processor_state: ProcessorState = .none,
    /// The notices the renderer sent back, one `Uint8Array` each, until the app takes them (`takeNoticeBytes`).
    held_notices: Handle = 0,
    /// The renderer's last frames mixed, as its last analysis answer brought them (`acceptAnalysis`): a
    /// `Float32Array`, the oldest first; 0 before the first answer. And whether a request waits for its answer
    /// (`askAnalysis`).
    analysis_frames: Handle = 0,
    is_analysis_asked: bool = false,
    /// The renderer's last report, valid once `has_report`. A flag beside a plain struct, not an optional struct:
    /// c2js drops the store of an optional's null flag when a struct literal is assigned to an optional struct field
    /// (it mistranslates `(&x)->is_null = false`), so such an optional would read as empty after being set.
    report: RendererReport = .{
        .block_count = 0,
        .loudest_sample = 0,
        .click_count = 0,
        .largest_jump = 0,
        .clipped_count = 0,
        .worklet_frame = 0,
        .received_at_ms = 0,
        .longest_block_ms = 0,
        .mean_block_ms = 0,
        .worklet_handle_count = 0,
        .longest_gap_ms = 0,
        .is_worklet_clock_coarse = false,
    },
    has_report: bool = false,
    /// The output's dropouts, read with the panel (`readOutputContinuity`).
    output_continuity: OutputContinuity = .{},
    /// What the page posted to the renderer, for the diagnostics.
    posted_command_count: u32 = 0,
    posted_samples_count: u32 = 0,
    /// The forwarded streams' messages of frames posted (`forwardStreamFrames`).
    posted_stream_message_count: u32 = 0,
    posted_note_count: u32 = 0,
    /// The context's rate, once an output started.
    sample_rate: f64 = 0,
    /// Whether the page listens for the gestures that let it start its audio (`listenForGesture`).
    is_listening_for_gesture: bool = false,
    /// The diagnostics panel at the top of the page, once shown (`showDiagnostics`); the mixer's count of voices, as
    /// it reports it each frame (`noteMixer`); and page audio's last warning, for the panel's last line.
    diagnostics_panel: Handle = 0,
    mixer_voice_count: ?u32 = null,
    /// Whether handles are being debugged (`setHandleDebugging`), and the panel's refreshes since the census of the
    /// page's handles was last written to the page's log - every `census_refreshes` while debugging.
    is_debugging_handles: bool = false,
    refreshes_since_census: u32 = 0,
    /// The page's frames on the main thread, timed where the mixer reports each (`noteMixer`): when the last was, and
    /// the gaps between them since the worklet's last report - the longest, their sum and their count; and the last
    /// whole second's, which the panel shows (`takeFrameGaps`). A long frame on the main thread beside a long gap on
    /// the audio thread says the two are starved together: the device's processors are busy.
    last_frame_ms: f64 = 0,
    frame_gap_longest_ms: f64 = 0,
    frame_gap_sum_ms: f64 = 0,
    frame_gap_count: f64 = 0,
    shown_longest_frame_gap_ms: f64 = 0,
    shown_mean_frame_gap_ms: f64 = 0,
    last_report: [last_report_capacity]u8 = undefined,
    last_report_length: usize = 0,
    /// `undefined`, made once: the value a handler is cleared with. Its handle is never freed (c2js's `js_free` does
    /// not free a handle of `undefined`), so it is made once rather than at each use.
    undefined_value: Handle = 0,
};
// lint:off module-var: the page's one sound output - the browser's callbacks reach it, and they take no context
var page_audio: PageAudio = .{};

/// How a report of page audio's is said in the console. A fault - no Web Audio, a renderer that failed - is a
/// warning. That the sound plays through the script processor is a notice: it is a way the sound plays, a little
/// later, not a fault, and it is the normal case in a viewer whose page has an opaque origin, where no worklet can
/// load. A notice goes to `console.info`, which the single-file page does not copy onto the page.
const ReportLevel = enum {
    notice,
    warning,

    /// The console method the level is said with.
    fn consoleMethod(level: ReportLevel) []const u8 {
        switch (level) {
            .notice => {
                return "info";
            },
            .warning => {
                return "warn";
            },
        }
    }
};

/// Keeps `prefix` and the text of `detail` - a string, or anything `String()` makes one of - as page audio's last
/// report, for the diagnostics panel, and says it in the page's console at its level.
fn logReport(
    comptime level: ReportLevel,
    comptime prefix: []const u8,
    detail: Handle,
) void {
    const prefix_length: usize = @min(prefix.len, last_report_capacity);
    @memcpy(page_audio.last_report[0..prefix_length], prefix[0..prefix_length]);
    const detail_room: []u8 = page_audio.last_report[prefix_length..];
    const detail_length: u32 = js_string_into(detail, detail_room.ptr, @intCast(detail_room.len));
    page_audio.last_report_length = prefix_length + detail_length;
    const prefix_value: Handle = string(prefix);
    defer js_free(prefix_value);
    const console: Handle = globalNamed("console");
    defer js_free(console);
    callVoid2(console, comptime level.consoleMethod(), prefix_value, detail);
}

/// The handle of `undefined`, made the first time it is asked for.
fn undefinedValue() Handle {
    if (page_audio.undefined_value == 0) {
        page_audio.undefined_value = kept(js_undefined());
    }
    return page_audio.undefined_value;
}

// ---- The renderer worklet's module, loaded at boot ----

/// The export a module has when it can run the renderer (`worklet_abi.start`, in `sound.zig`): a module without it
/// plays no sound, and its page makes no audio context.
const renderer_entry_point_name: []const u8 = "zimr_audio_worklet_start";

/// Whether `app_module` exports the renderer's entry points.
fn moduleExportsRenderer(app_module: Handle) bool {
    const webassembly_module: Handle = property(globalNamed("WebAssembly"), "Module");
    const export_list: Handle = call1(webassembly_module, "exports", app_module);
    defer js_free(export_list);
    const wanted_name: Handle = string(renderer_entry_point_name);
    defer js_free(wanted_name);
    const export_count: u32 = js_len(export_list);
    for (0..export_count) |export_index| {
        const export_entry: Handle = js_get_index(export_list, @intCast(export_index));
        defer js_free(export_entry);
        const export_name: Handle = property(export_entry, "name");
        defer js_free(export_name);
        if (js_strict_eq(export_name, wanted_name) == 1) {
            return true;
        }
    }
    return false;
}

/// Asks for the audio session of media playback: `navigator.audioSession.type = "playback"` (the Audio Session API,
/// Safari since 16.4, on iOS too; no other browser has it). Safari on iOS otherwise plays Web Audio in the ambient
/// session, which the iPhone's Silent mode - its switch, its Action button, Control Center - mutes: the page runs, its
/// notes light, and nothing is heard. In the playback session the page is heard as music or a video is, through Silent
/// mode; starting it pauses other apps' audio rather than mixing with it. Asked before the context is made, as the
/// session a context starts in is the one it keeps.
fn askForPlaybackSession() void {
    const navigator: Handle = globalNamed("navigator");
    defer js_free(navigator);
    if (js_truthy(navigator) == 0) {
        return;
    }
    const audio_session: Handle = property(navigator, "audioSession");
    defer js_free(audio_session);
    if (js_truthy(audio_session) == 0) {
        return;
    }
    const playback: Handle = string("playback");
    defer js_free(playback);
    setProperty(audio_session, "type", playback);
}

/// An audio context at `sample_rate`; at the browser's own rate when it refuses the one asked for (an older Safari);
/// 0 when the browser has no Web Audio at all. Asks first for the audio session of media playback
/// (`askForPlaybackSession`), where the browser has one.
fn makeAudioContext(sample_rate: f64) Handle {
    const context_class: Handle = globalNamed("AudioContext");
    if (js_truthy(context_class) == 0) {
        return 0;
    }
    askForPlaybackSession();
    const options: Handle = js_obj();
    defer js_free(options);
    const rate_value: Handle = js_num(sample_rate);
    defer js_free(rate_value);
    setProperty(options, "sampleRate", rate_value);
    const context_at_rate: Handle = js_try_new1(context_class, options);
    if (context_at_rate != 0) {
        return context_at_rate;
    }
    return js_new1(context_class, undefinedValue());
}

/// `context.audioWorklet.addModule(url).then(on_loaded, on_failed)`.
fn loadModuleFrom(
    url: Handle,
    on_loaded: *const anyopaque,
    on_failed: *const anyopaque,
) void {
    const worklet: Handle = property(page_audio.context, "audioWorklet");
    const loading_promise: Handle = call1(worklet, "addModule", url);
    _ = call2(loading_promise, "then", js_func(on_loaded), js_func(on_failed));
}

/// The module loaded from the `data:` URL: the renderer worklet can be used.
fn onLoadedFromDataUrl(result: Handle) void {
    _ = result;
    page_audio.loading = .loaded;
}

/// Neither URL loaded: the script processor will play. Said once in the page's console, with the browser's reason, as
/// a notice (`ReportLevel`): in a viewer whose page has an opaque origin this is how every page's sound plays.
fn onDataUrlLoadFailed(failure: Handle) void {
    const scope: Handle = js_mark();
    defer js_reset(scope);
    page_audio.loading = .unavailable;
    const reason: Handle = property(failure, "message");
    logReport(.notice, "zimr: the renderer worklet could not load, so the main thread renders: ", reason);
}

/// The module loaded from the Blob URL: the renderer worklet can be used.
fn onLoadedFromBlob(result: Handle) void {
    _ = result;
    const scope: Handle = js_mark();
    defer js_reset(scope);
    callVoid1(globalNamed("URL"), "revokeObjectURL", page_audio.blob_url);
    page_audio.loading = .loaded;
}

/// The Blob URL did not load - a page whose origin is opaque, as in some viewers, cannot load one: the same source
/// from a `data:` URL.
fn onBlobLoadFailed(failure: Handle) void {
    _ = failure;
    const scope: Handle = js_mark();
    defer js_reset(scope);
    callVoid1(globalNamed("URL"), "revokeObjectURL", page_audio.blob_url);
    const encoded_source: Handle = call1(js_global(), "encodeURIComponent", page_audio.module_source);
    const data_url: Handle = call1(string("data:application/javascript,"), "concat", encoded_source);
    page_audio.loading = .loading_from_data_url;
    loadModuleFrom(data_url, &onLoadedFromDataUrl, &onDataUrlLoadFailed);
}

/// Whether the renderer's loading has settled - loaded, or known not to - so that the boot may start the app.
pub fn isRendererSettled() bool {
    return switch (page_audio.loading) {
        .loading_from_blob, .loading_from_data_url => false,
        .not_asked, .loaded, .unavailable => true,
    };
}

/// Starts loading the renderer worklet's module, as the page boots, for an app whose module exports the renderer's
/// entry points: makes the audio context - suspended until the person's first gesture, as a browser requires - and
/// asks its worklet to load `program_text` from a Blob URL. The loading settles asynchronously
/// (`isRendererSettled`); the boot waits for it before the app's `init`, so that the mixer, at its start, knows
/// whether it can forward (`startForwarding`).
pub fn prepareRenderer(program_text: Handle, app_module: Handle) void {
    const can_run_renderer: bool = moduleExportsRenderer(app_module) and js_truthy(program_text) == 1;
    const has_worklet: bool = js_truthy(globalNamed("AudioWorkletNode")) == 1;
    if (!can_run_renderer or !has_worklet) {
        page_audio.loading = .unavailable;
        return;
    }
    const mixer_sample_rate: f64 = 48_000;
    const context: Handle = makeAudioContext(mixer_sample_rate);
    if (context == 0) {
        page_audio.loading = .unavailable;
        return;
    }
    page_audio.context = kept(context);
    page_audio.app_module = kept(app_module);
    // The worklet's module is the program with its entry point called: `registerProcessor` runs as it loads.
    const entry_point_call: Handle = string("\nstart();\n");
    defer js_free(entry_point_call);
    page_audio.module_source = kept(call1(program_text, "concat", entry_point_call));
    const source_parts: Handle = js_array();
    defer js_free(source_parts);
    _ = js_push(source_parts, page_audio.module_source);
    const blob_options: Handle = js_obj();
    defer js_free(blob_options);
    const javascript_type: Handle = string("application/javascript");
    defer js_free(javascript_type);
    setProperty(blob_options, "type", javascript_type);
    const blob: Handle = js_new2(globalNamed("Blob"), source_parts, blob_options);
    defer js_free(blob);
    page_audio.blob_url = kept(call1(globalNamed("URL"), "createObjectURL", blob));
    page_audio.loading = .loading_from_blob;
    loadModuleFrom(page_audio.blob_url, &onLoadedFromBlob, &onBlobLoadFailed);
}

// ---- The person's first gesture ----

/// Does nothing with a promise's rejection: a resume or a suspend the browser refuses changes nothing here.
fn ignoreRejection(reason: Handle) void {
    _ = reason;
}

/// A gesture resumes the context: a browser runs an audio context only once the person has clicked, tapped or pressed
/// a key on the page, and the context made at boot starts suspended.
fn onGesture(event: Handle) void {
    _ = event;
    const scope: Handle = js_mark();
    defer js_reset(scope);
    if (page_audio.context == 0) {
        return;
    }
    const context_state: Handle = property(page_audio.context, "state");
    if (isString(context_state, "running")) {
        return;
    }
    const resuming: Handle = call0(page_audio.context, "resume");
    callVoid1(resuming, "catch", js_func(&ignoreRejection));
}

/// The events that grant a page the person's activation, which resuming audio needs: a key, a mouse button going down
/// - and for touch and pen, the press ending (`pointerup`, `touchend`), not starting.
const activation_event_names = [_][]const u8{ "keydown", "pointerdown", "pointerup", "touchend", "click" };

/// Listens, once for the page, for the gestures that resume the context (`onGesture`), on the document and before
/// any of the page's own handlers (in the capture phase).
fn listenForGesture() void {
    if (page_audio.is_listening_for_gesture) {
        return;
    }
    const document: Handle = globalNamed("document");
    defer js_free(document);
    if (js_truthy(document) == 0) {
        return;
    }
    page_audio.is_listening_for_gesture = true;
    const gesture_handler: Handle = js_func(&onGesture);
    defer js_free(gesture_handler);
    const in_capture_phase: Handle = js_num(1);
    defer js_free(in_capture_phase);
    for (activation_event_names) |event_name| {
        const event_name_value: Handle = string(event_name);
        defer js_free(event_name_value);
        callVoid3(document, "addEventListener", event_name_value, gesture_handler, in_capture_phase);
    }
}

// ---- The renderer worklet: its node, and what crosses its port ----

/// A view of the app's memory - `new view_class(memory.buffer, address, length)` - taken afresh at each use, since the
/// memory may have grown since the last.
fn appMemoryView(comptime view_class: []const u8, address: u32, length: u32) Handle {
    const memory: Handle = property(page_audio.app_exports, "memory");
    defer js_free(memory);
    const memory_buffer: Handle = property(memory, "buffer");
    defer js_free(memory_buffer);
    const view_constructor: Handle = globalNamed(view_class);
    defer js_free(view_constructor);
    const address_value: Handle = js_num(@floatFromInt(address));
    defer js_free(address_value);
    const length_value: Handle = js_num(@floatFromInt(length));
    defer js_free(length_value);
    return js_new3(view_constructor, memory_buffer, address_value, length_value);
}

/// Posts `message` to the renderer's processor, its `transfer_list` handed over rather than copied.
fn postToRenderer(message: Handle, transfer_list: Handle) void {
    const port: Handle = property(page_audio.node, "port");
    defer js_free(port);
    callVoid2(port, "postMessage", message, transfer_list);
}

/// Keeps the frames' gaps since the last call as the second the panel shows, and starts counting again: called at each
/// report from the worklet, about once a second.
fn takeFrameGaps() void {
    const has_frames: bool = page_audio.frame_gap_count > 0;
    page_audio.shown_longest_frame_gap_ms = page_audio.frame_gap_longest_ms;
    const mean_frame_gap_ms: f64 = if (has_frames) page_audio.frame_gap_sum_ms / page_audio.frame_gap_count else 0;
    page_audio.shown_mean_frame_gap_ms = mean_frame_gap_ms;
    page_audio.frame_gap_longest_ms = 0;
    page_audio.frame_gap_sum_ms = 0;
    page_audio.frame_gap_count = 0;
}

/// `{ kind: "analysis", bytes }`: the renderer's last frames mixed, kept in place of the last answer's until an
/// analyser takes them (`takeAnalysisFrames`); the next request may go.
fn acceptAnalysis(message: Handle) void {
    const frame_bytes: Handle = property(message, "bytes");
    const frames: Handle = js_new1(globalNamed("Float32Array"), frame_bytes);
    if (page_audio.analysis_frames != 0) {
        js_free(page_audio.analysis_frames);
    }
    page_audio.analysis_frames = kept(frames);
    page_audio.is_analysis_asked = false;
}

/// Asks the renderer worklet for its last frames mixed (`{ kind: "analysis" }`), for an analyser: one request at a
/// time, another only once the answer came (`acceptAnalysis`). Nothing while the worklet does not play.
pub fn askAnalysis() void {
    const is_worklet_playing: bool = page_audio.path == .renderer_worklet and page_audio.node != 0;
    if (!is_worklet_playing or page_audio.is_analysis_asked) {
        return;
    }
    const scope: Handle = js_mark();
    defer js_reset(scope);
    const request: Handle = js_obj();
    setProperty(request, "kind", string("analysis"));
    postToRenderer(request, js_array());
    page_audio.is_analysis_asked = true;
}

/// Copies the last `frame_count` frames of the renderer's last answer into the app's memory at `target_address`,
/// oldest first; returns `frame_count` - or 0 before the first answer, and for more frames than an answer holds.
pub fn takeAnalysisFrames(target_address: u32, frame_count: u32) u32 {
    if (page_audio.analysis_frames == 0) {
        return 0;
    }
    const held_frame_count: u32 = js_len(page_audio.analysis_frames);
    if (frame_count > held_frame_count) {
        return 0;
    }
    const scope: Handle = js_mark();
    defer js_reset(scope);
    const target: Handle = appMemoryView("Float32Array", target_address, frame_count);
    const first_kept: Handle = js_num(@floatFromInt(held_frame_count - frame_count));
    const newest_frames: Handle = call1(page_audio.analysis_frames, "subarray", first_kept);
    callVoid1(target, "set", newest_frames);
    return frame_count;
}

/// A message from the renderer's processor (`worklet_abi.message`, in `sound.zig`): notices kept until the app takes
/// them; its report kept for the diagnostics; its start, ready or failed.
fn onRendererMessage(event: Handle) void {
    const scope: Handle = js_mark();
    defer js_reset(scope);
    const message: Handle = property(event, "data");
    const kind: Handle = property(message, "kind");
    if (isString(kind, "notices")) {
        const notice_buffer: Handle = property(message, "bytes");
        const notice_bytes: Handle = js_new1(globalNamed("Uint8Array"), notice_buffer);
        _ = js_push(page_audio.held_notices, notice_bytes);
    } else if (isString(kind, "stats")) {
        // The click watch's totals since the page started: computed before the report is replaced - the new report's
        // fields are written straight into the old one's place, so a field read from it while it is written could
        // already be the new one.
        const click_total: f64 = page_audio.report.click_count + numberProperty(message, "clicks");
        const largest_jump_ever: f64 = @max(page_audio.report.largest_jump, numberProperty(message, "largestJump"));
        const clipped_total: f64 = page_audio.report.clipped_count + numberProperty(message, "clipped");
        page_audio.report = .{
            .block_count = numberProperty(message, "blocks"),
            .loudest_sample = numberProperty(message, "peak"),
            .click_count = click_total,
            .largest_jump = largest_jump_ever,
            .clipped_count = clipped_total,
            .worklet_frame = numberProperty(message, "frame"),
            .received_at_ms = pageClockMilliseconds(),
            .longest_block_ms = numberProperty(message, "longestBlockMs"),
            .mean_block_ms = numberProperty(message, "meanBlockMs"),
            .worklet_handle_count = numberProperty(message, "handles"),
            .longest_gap_ms = numberProperty(message, "longestGapMs"),
            .is_worklet_clock_coarse = numberProperty(message, "isClockWholeMs") == 1,
        };
        page_audio.has_report = true;
        takeFrameGaps();
    } else if (isString(kind, "analysis")) {
        acceptAnalysis(message);
    } else if (isString(kind, "ready")) {
        page_audio.processor_state = .running;
    } else if (isString(kind, "failed")) {
        page_audio.processor_state = .failed;
        logReport(.warning, "zimr: the renderer in the audio worklet failed: ", property(message, "message"));
    }
}

/// The node's report that its processor threw - in its constructor or a call of `process`: the processor is dead.
fn onProcessorError(event: Handle) void {
    const scope: Handle = js_mark();
    defer js_reset(scope);
    page_audio.processor_state = .failed;
    logReport(.warning, "zimr: the renderer in the audio worklet failed: ", property(event, "message"));
}

/// Hands page audio the app's instance's exports, once it is instantiated: what the forwarded bytes are copied from,
/// and the script processor's pull.
pub fn setAppExports(app_exports: Handle) void {
    page_audio.app_exports = kept(app_exports);
}

/// Stops the output playing, whichever path: its node disconnected and its handler cleared. The renderer worklet's
/// context stays, suspended - the module loaded into it at boot serves the next start; the script processor's is
/// closed.
pub fn stop() void {
    if (page_audio.node != 0) {
        switch (page_audio.path) {
            .renderer_worklet => {
                const port: Handle = property(page_audio.node, "port");
                defer js_free(port);
                setProperty(port, "onmessage", undefinedValue());
                setProperty(page_audio.node, "onprocessorerror", undefinedValue());
            },
            .script_processor => setProperty(page_audio.node, "onaudioprocess", undefinedValue()),
            .none => {},
        }
        callVoid0(page_audio.node, "disconnect");
        js_free(page_audio.node);
        page_audio.node = 0;
    }
    if (page_audio.context != 0) {
        const ignore_handler: Handle = js_func(&ignoreRejection);
        defer js_free(ignore_handler);
        switch (page_audio.path) {
            .renderer_worklet => {
                const suspending: Handle = call0(page_audio.context, "suspend");
                defer js_free(suspending);
                callVoid1(suspending, "catch", ignore_handler);
            },
            .script_processor => {
                const closing: Handle = call0(page_audio.context, "close");
                defer js_free(closing);
                callVoid1(closing, "catch", ignore_handler);
                js_free(page_audio.context);
                page_audio.context = 0;
            },
            .none => {},
        }
    }
    if (page_audio.held_notices != 0) {
        js_free(page_audio.held_notices);
        page_audio.held_notices = 0;
    }
    if (page_audio.analysis_frames != 0) {
        js_free(page_audio.analysis_frames);
        page_audio.analysis_frames = 0;
    }
    page_audio.is_analysis_asked = false;
    page_audio.path = .none;
    page_audio.processor_state = .none;
    page_audio.has_report = false;
}

/// Starts the renderer worklet's node, when its module loaded at boot: the processor runs a second instance of the
/// app's module (`processorOptions.module`), with `channel_count` channels out and no input. Returns the context's
/// rate, or 0 when the module did not load and the mixer must pull through the script processor instead
/// (`startPulled`).
pub fn startForwarding(channel_count: u32) f64 {
    if (page_audio.loading != .loaded) {
        return 0;
    }
    stop();
    const node_options: Handle = js_obj();
    defer js_free(node_options);
    setNumberProperty(node_options, "numberOfInputs", 0);
    const output_channel_counts: Handle = js_array();
    defer js_free(output_channel_counts);
    const channel_count_value: Handle = js_num(@floatFromInt(channel_count));
    defer js_free(channel_count_value);
    _ = js_push(output_channel_counts, channel_count_value);
    setProperty(node_options, "outputChannelCount", output_channel_counts);
    const processor_options: Handle = js_obj();
    defer js_free(processor_options);
    setProperty(processor_options, "module", page_audio.app_module);
    setProperty(node_options, "processorOptions", processor_options);
    const node_class: Handle = globalNamed("AudioWorkletNode");
    defer js_free(node_class);
    const processor_name: Handle = string("zimr-renderer");
    defer js_free(processor_name);
    const node: Handle = js_new3(node_class, page_audio.context, processor_name, node_options);
    // The state first, then the handlers: a message the processor posted while it was made - its `ready` - may be
    // delivered as soon as the handler is set, and must find the state it changes already in place.
    page_audio.node = kept(node);
    page_audio.path = .renderer_worklet;
    page_audio.processor_state = .starting;
    page_audio.held_notices = kept(js_array());
    page_audio.posted_command_count = 0;
    page_audio.posted_samples_count = 0;
    page_audio.posted_stream_message_count = 0;
    page_audio.posted_note_count = 0;
    page_audio.sample_rate = numberProperty(page_audio.context, "sampleRate");
    const port: Handle = property(node, "port");
    defer js_free(port);
    const message_handler: Handle = js_func(&onRendererMessage);
    defer js_free(message_handler);
    setProperty(port, "onmessage", message_handler);
    const error_handler: Handle = js_func(&onProcessorError);
    defer js_free(error_handler);
    setProperty(node, "onprocessorerror", error_handler);
    const destination: Handle = property(page_audio.context, "destination");
    defer js_free(destination);
    callVoid1(node, "connect", destination);
    listenForGesture();
    return page_audio.sample_rate;
}

/// Posts a command's `byte_count` bytes at `bytes_address` in the app's memory to the renderer, copied out and the
/// copy handed over: `{ kind: "commands", bytes }`.
pub fn forwardCommandBytes(bytes_address: u32, byte_count: u32) void {
    if (page_audio.path != .renderer_worklet) {
        return;
    }
    const command_view: Handle = appMemoryView("Uint8Array", bytes_address, byte_count);
    defer js_free(command_view);
    const command_copy: Handle = call0(command_view, "slice");
    defer js_free(command_copy);
    const copy_buffer: Handle = property(command_copy, "buffer");
    defer js_free(copy_buffer);
    const message: Handle = js_obj();
    defer js_free(message);
    const kind: Handle = string("commands");
    defer js_free(kind);
    setProperty(message, "kind", kind);
    setProperty(message, "bytes", copy_buffer);
    const transfer_list: Handle = js_array();
    defer js_free(transfer_list);
    _ = js_push(transfer_list, copy_buffer);
    postToRenderer(message, transfer_list);
    page_audio.posted_command_count += 1;
}

/// Posts a forwarded stream's frames - `sample_count` samples at `frames_address` in the app's memory, of `channels`
/// channels made at `sample_rate` - to the renderer, for the stream's ring there:
/// `{ kind: "stream", streamId, channels, sampleRate, frames }`, the copy handed over.
pub fn forwardStreamFrames(
    stream_id: u32,
    channels: u32,
    sample_rate: u32,
    frames_address: u32,
    sample_count: u32,
) void {
    if (page_audio.path != .renderer_worklet) {
        return;
    }
    const frames_view: Handle = appMemoryView("Float32Array", frames_address, sample_count);
    defer js_free(frames_view);
    const frames_copy: Handle = call0(frames_view, "slice");
    defer js_free(frames_copy);
    const copy_buffer: Handle = property(frames_copy, "buffer");
    defer js_free(copy_buffer);
    const stream_message: Handle = js_obj();
    defer js_free(stream_message);
    const kind: Handle = string("stream");
    defer js_free(kind);
    setProperty(stream_message, "kind", kind);
    setNumberProperty(stream_message, "streamId", @floatFromInt(stream_id));
    setNumberProperty(stream_message, "channels", @floatFromInt(channels));
    setNumberProperty(stream_message, "sampleRate", @floatFromInt(sample_rate));
    setProperty(stream_message, "frames", frames_copy);
    const transfer_list: Handle = js_array();
    defer js_free(transfer_list);
    _ = js_push(transfer_list, copy_buffer);
    postToRenderer(stream_message, transfer_list);
    page_audio.posted_stream_message_count += 1;
}

/// Posts `sample_count` samples at `samples_address` in the app's memory to the renderer, to register under
/// `samples_id`: `{ kind: "samples", samplesId, samples }`, the copy handed over.
pub fn forwardSamples(samples_id: u32, samples_address: u32, sample_count: u32) void {
    if (page_audio.path != .renderer_worklet) {
        return;
    }
    const samples_view: Handle = appMemoryView("Float32Array", samples_address, sample_count);
    defer js_free(samples_view);
    const samples_copy: Handle = call0(samples_view, "slice");
    defer js_free(samples_copy);
    const copy_buffer: Handle = property(samples_copy, "buffer");
    defer js_free(copy_buffer);
    const message: Handle = js_obj();
    defer js_free(message);
    const kind: Handle = string("samples");
    defer js_free(kind);
    setProperty(message, "kind", kind);
    setNumberProperty(message, "samplesId", @floatFromInt(samples_id));
    setProperty(message, "samples", samples_copy);
    const transfer_list: Handle = js_array();
    defer js_free(transfer_list);
    _ = js_push(transfer_list, copy_buffer);
    postToRenderer(message, transfer_list);
    page_audio.posted_samples_count += 1;
}

/// Posts a key's event to the renderer: `{ kind: "note", key, isDown, velocity, requestedAt, pressedAt }` - the last
/// two the times its start is measured from, on the page's clock (`mixer.NoteEvent`).
pub fn forwardNote(
    key: u32,
    is_down: u32,
    velocity: f64,
    requested_at_ms: f64,
    pressed_at_ms: f64,
) void {
    if (page_audio.path != .renderer_worklet) {
        return;
    }
    const message: Handle = js_obj();
    defer js_free(message);
    const kind: Handle = string("note");
    defer js_free(kind);
    setProperty(message, "kind", kind);
    setNumberProperty(message, "key", @floatFromInt(key));
    setNumberProperty(message, "isDown", @floatFromInt(is_down));
    setNumberProperty(message, "velocity", velocity);
    setNumberProperty(message, "requestedAt", finiteOrZero(requested_at_ms));
    setNumberProperty(message, "pressedAt", finiteOrZero(pressed_at_ms));
    const port: Handle = property(page_audio.node, "port");
    defer js_free(port);
    callVoid1(port, "postMessage", message);
    page_audio.posted_note_count += 1;
}

/// Copies the notices the renderer sent back into the app's memory at `target_address`: whole notices only, of
/// `notice_byte_count` bytes each, as many as `capacity` bytes hold. A message's notices not all taken stay, the rest
/// of them first in line. Returns the bytes copied.
pub fn takeNoticeBytes(target_address: u32, capacity: u32, notice_byte_count: u32) u32 {
    // Called every frame, and most frames bring no notice: nothing is made - not even the view - until one is held.
    const is_any_notice_held: bool = page_audio.held_notices != 0 and js_len(page_audio.held_notices) > 0;
    if (!is_any_notice_held or notice_byte_count == 0) {
        return 0;
    }
    const target: Handle = appMemoryView("Uint8Array", target_address, capacity);
    defer js_free(target);
    var copied_byte_count: u32 = 0;
    while (js_len(page_audio.held_notices) > 0) {
        const room_bytes: u32 = (capacity - copied_byte_count) / notice_byte_count * notice_byte_count;
        if (room_bytes == 0) {
            break;
        }
        const first_message: Handle = js_get_index(page_audio.held_notices, 0);
        defer js_free(first_message);
        const message_byte_count: u32 = js_len(first_message);
        const taken_byte_count: u32 = @min(room_bytes, message_byte_count);
        const start_value: Handle = js_num(0);
        defer js_free(start_value);
        const end_value: Handle = js_num(@floatFromInt(taken_byte_count));
        defer js_free(end_value);
        const taken_part: Handle = call2(first_message, "subarray", start_value, end_value);
        defer js_free(taken_part);
        const offset_value: Handle = js_num(@floatFromInt(copied_byte_count));
        defer js_free(offset_value);
        callVoid2(target, "set", taken_part, offset_value);
        copied_byte_count += taken_byte_count;
        if (taken_byte_count == message_byte_count) {
            const removed_message: Handle = call0(page_audio.held_notices, "shift");
            js_free(removed_message);
        } else {
            const rest: Handle = call1(first_message, "subarray", end_value);
            defer js_free(rest);
            js_set_index(page_audio.held_notices, 0, rest);
        }
    }
    return copied_byte_count;
}

// ---- The pulled path: the script processor ----

/// The frames of one script processor's buffer: 2 048, 42.7 ms at 48 kHz. The callback renders each buffer when the
/// browser asks for it, on the main thread, between the app's frames, so the buffer must outlast the longest of them.
/// A float, as the browser takes it.
const processor_block_frames: f64 = 2_048;

/// The script processor asks for its next buffer: the app's own renderer renders it - `zimr_audio_pull_block`, an
/// export of the app's module, returns its address, the left channel's samples then the right's - and each channel is
/// copied out of the app's memory into the processor's.
fn onAudioProcess(event: Handle) void {
    const scope: Handle = js_mark();
    defer js_reset(scope);
    const output_buffer: Handle = property(event, "outputBuffer");
    const frame_count: f64 = numberProperty(output_buffer, "length");
    const frame_count_value: Handle = js_num(frame_count);
    const block_address_value: Handle = call1(page_audio.app_exports, "zimr_audio_pull_block", frame_count_value);
    const block_address: f64 = js_to_num(block_address_value);
    if (block_address == 0) {
        return;
    }
    const channel_count: f64 = numberProperty(output_buffer, "numberOfChannels");
    const bytes_per_sample: f64 = 4;
    var channel_index: f64 = 0;
    while (channel_index < channel_count) : (channel_index += 1) {
        const channel_address: f64 = block_address + channel_index * frame_count * bytes_per_sample;
        const rendered_channel: Handle = appMemoryView("Float32Array", @trunc(channel_address), @trunc(frame_count));
        const channel_index_value: Handle = js_num(channel_index);
        const processor_channel: Handle = call1(output_buffer, "getChannelData", channel_index_value);
        callVoid1(processor_channel, "set", rendered_channel);
    }
}

/// Starts the output pulled on the main thread, where no renderer worklet could load: a script processor whose
/// callback asks the app's renderer for each buffer (`onAudioProcess`) - nothing waits in a queue between the renderer
/// and the speaker. It plays on the context made at boot when there is one, else on a new one at `sample_rate`.
/// Returns the context's rate, or 0 when the browser has neither Web Audio nor a script processor.
pub fn startPulled(sample_rate: f64, channel_count: u32) f64 {
    stop();
    if (page_audio.context == 0) {
        page_audio.context = kept(makeAudioContext(sample_rate));
    }
    if (page_audio.context == 0) {
        const no_audio: Handle = string("the sound is not played");
        defer js_free(no_audio);
        logReport(.warning, "zimr: this browser has no Web Audio: ", no_audio);
        return 0;
    }
    const make_processor: Handle = property(page_audio.context, "createScriptProcessor");
    defer js_free(make_processor);
    if (js_truthy(make_processor) == 0) {
        const no_processor: Handle = string("the sound is not played");
        defer js_free(no_processor);
        const prefix: []const u8 = "zimr: this browser has neither an AudioWorklet nor a script processor here: ";
        logReport(.warning, prefix, no_processor);
        return 0;
    }
    const block_frames_value: Handle = js_num(processor_block_frames);
    defer js_free(block_frames_value);
    const no_inputs: Handle = js_num(0);
    defer js_free(no_inputs);
    const channel_count_value: Handle = js_num(@floatFromInt(channel_count));
    defer js_free(channel_count_value);
    const node: Handle = js_call3(
        page_audio.context,
        "createScriptProcessor".ptr,
        "createScriptProcessor".len,
        block_frames_value,
        no_inputs,
        channel_count_value,
    );
    const process_handler: Handle = js_func(&onAudioProcess);
    defer js_free(process_handler);
    setProperty(node, "onaudioprocess", process_handler);
    const destination: Handle = property(page_audio.context, "destination");
    defer js_free(destination);
    callVoid1(node, "connect", destination);
    page_audio.node = kept(node);
    page_audio.path = .script_processor;
    page_audio.sample_rate = numberProperty(page_audio.context, "sampleRate");
    listenForGesture();
    return page_audio.sample_rate;
}

// ---- What the readout and the panel show ----

/// Whether the context is running - started by a gesture, and not suspended since.
fn isContextRunning() bool {
    if (page_audio.context == 0) {
        return false;
    }
    const context_state: Handle = property(page_audio.context, "state");
    defer js_free(context_state);
    return isString(context_state, "running");
}

/// What lies past the output, in milliseconds, for the latency readout: the script processor's whole buffer when it
/// plays (a block rendered now is heard after it), and the latency the context reports past itself
/// (`baseLatency + outputLatency`).
pub fn outputLatencyMilliseconds() f64 {
    if (page_audio.context == 0) {
        return 0;
    }
    const base_latency_seconds: f64 = finiteOrZero(numberProperty(page_audio.context, "baseLatency"));
    const output_latency_seconds: f64 = finiteOrZero(numberProperty(page_audio.context, "outputLatency"));
    const processor_buffer_ms: f64 = if (page_audio.path == .script_processor)
        processor_block_frames * 1000 / page_audio.sample_rate
    else
        0;
    return processor_buffer_ms + 1000 * (base_latency_seconds + output_latency_seconds);
}

/// Which path plays the page's sound, and how far it has come: what page audio reports to the app's module across
/// the bridge (`outputStatus`, as its integer) - the web platform names it (`audioOutputName`) and the audio start
/// screen waits on it (`isAudioOutputSettled`).
pub const OutputStatus = enum(u32) {
    /// The script processor on the main thread - the path where no worklet can load - or no output yet.
    script_processor = 0,
    /// The renderer in the audio worklet, its processor starting: the module instantiated again in the worklet, the
    /// renderer warming up.
    worklet_starting = 1,
    /// The renderer in the audio worklet, playing.
    worklet_running = 2,
    /// The renderer in the audio worklet, failed - its error in the page's log.
    worklet_failed = 3,
    /// The renderer in the audio worklet, ready, its audio context not running yet: no click, tap or key yet.
    worklet_waiting_for_gesture = 4,
};

/// The output's status now (`OutputStatus`).
pub fn outputStatus() OutputStatus {
    return switch (page_audio.path) {
        .none, .script_processor => .script_processor,
        .renderer_worklet => path: {
            if (page_audio.processor_state == .failed) {
                break :path .worklet_failed;
            }
            if (!isContextRunning()) {
                break :path .worklet_waiting_for_gesture;
            }
            break :path if (page_audio.processor_state == .running) .worklet_running else .worklet_starting;
        },
    };
}

/// The mixer's count of playing voices, for the panel, as it reports it each frame.
pub fn noteMixer(voice_count: u32) void {
    page_audio.mixer_voice_count = voice_count;
    const now_ms: f64 = pageClockMilliseconds();
    const has_last_frame: bool = page_audio.last_frame_ms != 0;
    if (has_last_frame) {
        const frame_gap_ms: f64 = now_ms - page_audio.last_frame_ms;
        page_audio.frame_gap_longest_ms = @max(page_audio.frame_gap_longest_ms, frame_gap_ms);
        page_audio.frame_gap_sum_ms += frame_gap_ms;
        page_audio.frame_gap_count += 1;
    }
    page_audio.last_frame_ms = now_ms;
}

// ---- The diagnostics panel ----

/// A line of text built in a fixed buffer - the panel's lines. std's formatting is not used: it brings in a writer's
/// table of functions, which the transpile from C to JavaScript cannot take. Text past the buffer's end is dropped.
const TextBuilder = struct {
    bytes: [1024]u8 = undefined,
    length: usize = 0,

    fn appendText(builder: *TextBuilder, text: []const u8) void {
        const room: usize = builder.bytes.len - builder.length;
        const copied_length: usize = @min(room, text.len);
        @memcpy(builder.bytes[builder.length..][0..copied_length], text[0..copied_length]);
        builder.length += copied_length;
    }

    /// `value` in decimal digits.
    fn appendWholeNumber(builder: *TextBuilder, value: u64) void {
        var digits: [20]u8 = undefined;
        var digit_count: usize = 0;
        var remaining: u64 = value;
        while (true) {
            digits[digits.len - 1 - digit_count] = '0' + @as(u8, @intCast(remaining % 10));
            digit_count += 1;
            remaining /= 10;
            if (remaining == 0) {
                break;
            }
        }
        builder.appendText(digits[digits.len - digit_count ..]);
    }

    /// `value` with `fraction_digits` digits after the point, rounded to the nearest: 0.3504 with 3 is "0.350".
    /// Negative values get a minus sign; NaN and values past 10^15 print as "-".
    fn appendDecimal(builder: *TextBuilder, value: f64, fraction_digits: u32) void {
        const largest_printed: f64 = 1e15;
        const is_printable: bool = value == value and @abs(value) < largest_printed;
        if (!is_printable) {
            builder.appendText("-");
            return;
        }
        if (value < 0) {
            builder.appendText("-");
        }
        var scale: u64 = 1;
        for (0..fraction_digits) |_| {
            scale *= 10;
        }
        const scale_float: f64 = @floatFromInt(scale);
        const scaled_value: u64 = @round(@abs(value) * scale_float);
        builder.appendWholeNumber(scaled_value / scale);
        if (fraction_digits == 0) {
            return;
        }
        builder.appendText(".");
        // The fraction's digits, with its leading zeros: 0.05 with 3 digits is 050 thousandths.
        const fraction: u64 = scaled_value % scale;
        var place: u64 = scale / 10;
        while (place > 0) : (place /= 10) {
            const digit: u8 = @intCast(fraction / place % 10);
            builder.appendText(&.{'0' + digit});
        }
    }

    fn writtenText(builder: *const TextBuilder) []const u8 {
        return builder.bytes[0..builder.length];
    }
};

test "the panel's numbers: whole, and with digits after the point, rounded" {
    var builder: TextBuilder = .{};
    builder.appendWholeNumber(0);
    builder.appendText(" ");
    builder.appendWholeNumber(48_000);
    builder.appendText(" ");
    builder.appendDecimal(0.3504, 3);
    builder.appendText(" ");
    builder.appendDecimal(0.05, 3);
    builder.appendText(" ");
    builder.appendDecimal(28.4, 0);
    builder.appendText(" ");
    builder.appendDecimal(-1.25, 1);
    try expectEqualStrings("0 48000 0.350 0.050 28 -1.3", builder.writtenText());
}

/// The browser's own account of its playing, where it gives one (`AudioContext.playoutStats`, in Chrome): how often
/// it had to fill frames itself because the audio was not ready in time - each a glitch heard - and for how long, and
/// the latency it measured. A browser enlarges its buffer after such glitches, so the glitches and the latency are
/// read together.
///
///     playout: 3 glitches, 21 ms filled in | latency 31 ms (24 to 88)
fn describePlayout(builder: *TextBuilder) void {
    const playout_stats: Handle = property(page_audio.context, "playoutStats");
    defer js_free(playout_stats);
    if (js_truthy(playout_stats) == 0) {
        return;
    }
    builder.appendText("\nplayout: ");
    builder.appendDecimal(numberProperty(playout_stats, "fallbackFramesEvents"), 0);
    builder.appendText(" glitches, ");
    builder.appendDecimal(numberProperty(playout_stats, "fallbackFramesDuration"), 0);
    builder.appendText(" ms filled in | latency ");
    builder.appendDecimal(numberProperty(playout_stats, "averageLatency"), 0);
    builder.appendText(" ms (");
    builder.appendDecimal(numberProperty(playout_stats, "minimumLatency"), 0);
    builder.appendText(" to ");
    builder.appendDecimal(numberProperty(playout_stats, "maximumLatency"), 0);
    builder.appendText(")");
}

/// Takes a reading of the output's continuity (`OutputContinuity`): the offset between the speaker's time and the
/// context's timeline, and a step up since the last reading counted as a dropout. Nothing is read while the context
/// does not run - suspended, or not yet started by a gesture - nor before its output has played a frame; the first
/// reading after either starts the count afresh, so that the panel's count is since the context last started.
/// Ties the worklet's timeline to the page's clock (`{ kind: "clock" }`) from one reading of `getOutputTimestamp`:
/// the frame at `context_time_ms` is heard at `speaker_time_ms`, so it is rendered that much earlier as the audio
/// still passes the browser's buffer and the device's (`outputLatencyMilliseconds`). The worklet times its blocks by
/// it, and measures the sounds they start on the clock the page stamps requests on (`mixer.LatencySample`).
fn tieWorkletClock(context_time_ms: f64, speaker_time_ms: f64) void {
    const is_worklet_playing: bool = page_audio.path == .renderer_worklet and page_audio.node != 0;
    if (!is_worklet_playing) {
        return;
    }
    const rendered_at_ms: f64 = speaker_time_ms - outputLatencyMilliseconds();
    const scope: Handle = js_mark();
    defer js_reset(scope);
    const tie: Handle = js_obj();
    setProperty(tie, "kind", string("clock"));
    setProperty(tie, "contextMs", js_num(context_time_ms));
    setProperty(tie, "pageMs", js_num(rendered_at_ms));
    postToRenderer(tie, js_array());
}

fn readOutputContinuity() void {
    const continuity: *OutputContinuity = &page_audio.output_continuity;
    if (!isContextRunning()) {
        continuity.has_reading = false;
        return;
    }
    const read_timestamp: Handle = property(page_audio.context, "getOutputTimestamp");
    defer js_free(read_timestamp);
    if (js_truthy(read_timestamp) == 0) {
        return;
    }
    const output_timestamp: Handle = call0(page_audio.context, "getOutputTimestamp");
    defer js_free(output_timestamp);
    const context_time_ms: f64 = 1000 * finiteOrZero(numberProperty(output_timestamp, "contextTime"));
    const speaker_time_ms: f64 = finiteOrZero(numberProperty(output_timestamp, "performanceTime"));
    const has_output_played: bool = context_time_ms > 0 and speaker_time_ms > 0;
    if (!has_output_played) {
        return;
    }
    const offset_ms: f64 = speaker_time_ms - context_time_ms;
    tieWorkletClock(context_time_ms, speaker_time_ms);
    if (continuity.has_reading) {
        // The top, sunk for the time since the last reading; a rise above it by the threshold is silence played.
        const seconds_since_last_reading: f64 = (speaker_time_ms - continuity.last_reading_ms) / 1000;
        const top_sinking_ms: f64 = offset_top_sink_ms_per_s * seconds_since_last_reading;
        const sunk_top_ms: f64 = continuity.offset_top_ms - top_sinking_ms;
        const rise_above_top_ms: f64 = offset_ms - sunk_top_ms;
        if (rise_above_top_ms >= dropout_threshold_ms) {
            continuity.dropout_count += 1;
            continuity.silence_ms += rise_above_top_ms;
            continuity.last_dropout_ms = speaker_time_ms;
        }
        continuity.offset_top_ms = @max(sunk_top_ms, offset_ms);
        const fall_ms: f64 = continuity.last_offset_ms - offset_ms;
        continuity.largest_fall_ms = @max(continuity.largest_fall_ms, fall_ms);
    } else {
        // The first reading since the context started to run: the counting starts afresh.
        continuity.* = .{
            .first_reading_ms = speaker_time_ms,
            .first_offset_ms = offset_ms,
            .offset_top_ms = offset_ms,
        };
    }
    continuity.has_reading = true;
    continuity.last_offset_ms = offset_ms;
    continuity.last_reading_ms = speaker_time_ms;
}

/// The output's dropouts since the context last started to run (`readOutputContinuity`), on a line of their own, and
/// beside them the offset's net shift since then - the silence truly played, jitter cancelled - and its largest fall,
/// the jitter:
///
///     dropouts: none in 63 s | offset: net +0.1 ms, falls up to 0.3 ms
///     dropouts: 3 in 63 s, 21 ms of silence, the last 2.4 s ago | offset: net +21.4 ms, falls up to 0.4 ms
fn describeDropouts(builder: *TextBuilder) void {
    const continuity: *const OutputContinuity = &page_audio.output_continuity;
    if (!continuity.has_reading) {
        return;
    }
    const measured_seconds: f64 = (continuity.last_reading_ms - continuity.first_reading_ms) / 1000;
    builder.appendText("\ndropouts: ");
    if (continuity.dropout_count == 0) {
        builder.appendText("none in ");
        builder.appendDecimal(measured_seconds, 0);
        builder.appendText(" s");
    } else {
        builder.appendWholeNumber(continuity.dropout_count);
        builder.appendText(" in ");
        builder.appendDecimal(measured_seconds, 0);
        builder.appendText(" s, ");
        builder.appendDecimal(continuity.silence_ms, 0);
        builder.appendText(" ms of silence, the last ");
        const seconds_since_last: f64 = (continuity.last_reading_ms - continuity.last_dropout_ms) / 1000;
        builder.appendDecimal(seconds_since_last, 1);
        builder.appendText(" s ago");
    }
    const net_shift_ms: f64 = continuity.last_offset_ms - continuity.first_offset_ms;
    builder.appendText(" | offset: net ");
    if (net_shift_ms >= 0) {
        builder.appendText("+");
    }
    builder.appendDecimal(net_shift_ms, 1);
    builder.appendText(" ms, falls up to ");
    builder.appendDecimal(continuity.largest_fall_ms, 1);
    builder.appendText(" ms");
}

/// The panel's text: the output, the renderer, the mixer, and page audio's last warning.
///
///     audio: renderer worklet | 48000 Hz | latency 4 ms + 24 ms
///     dropouts: none in 63 s
///     renderer: running | 1500 blocks (frame 191872, 0.4 s ago), loudest 0.354, clicks 0 (largest jump 0.004) | ...
///     worklet: longest block 1.00 ms, mean 0.120 ms, longest gap 5.0 ms (its clock counts whole ms)
///     mixer: voices 2
fn describeOutput(builder: *TextBuilder) void {
    builder.appendText("audio: ");
    builder.appendText(switch (page_audio.path) {
        .none => "no output",
        .renderer_worklet => "renderer worklet",
        .script_processor => "script processor",
    });
    if (page_audio.context != 0) {
        builder.appendText(" | ");
        builder.appendWholeNumber(@trunc(page_audio.sample_rate));
        builder.appendText(" Hz | latency ");
        builder.appendDecimal(1000 * finiteOrZero(numberProperty(page_audio.context, "baseLatency")), 0);
        builder.appendText(" ms + ");
        builder.appendDecimal(1000 * finiteOrZero(numberProperty(page_audio.context, "outputLatency")), 0);
        builder.appendText(" ms");
        if (!isContextRunning()) {
            builder.appendText(" | the context waits for a tap or a key");
        }
        describePlayout(builder);
        describeDropouts(builder);
    }
    if (page_audio.path == .renderer_worklet) {
        builder.appendText("\nrenderer: ");
        builder.appendText(switch (page_audio.processor_state) {
            .none => "none",
            .starting => "starting",
            .running => "running",
            .failed => "failed",
        });
        builder.appendText(" | ");
        if (page_audio.has_report) {
            const report: RendererReport = page_audio.report;
            const seconds_ago: f64 = (pageClockMilliseconds() - report.received_at_ms) / 1000;
            builder.appendWholeNumber(@trunc(report.block_count));
            builder.appendText(" blocks (frame ");
            builder.appendWholeNumber(@trunc(report.worklet_frame));
            builder.appendText(", ");
            builder.appendDecimal(seconds_ago, 1);
            builder.appendText(" s ago), loudest ");
            builder.appendDecimal(report.loudest_sample, 3);
            // The click watch: the clicks counted since the page started, and the largest jump in the sound's slope -
            // over 0.02 is a click (`Renderer.watchForClicks`).
            builder.appendText(", clicks ");
            builder.appendWholeNumber(@trunc(report.click_count));
            builder.appendText(" (largest jump ");
            builder.appendDecimal(report.largest_jump, 3);
            builder.appendText("), clipped ");
            builder.appendWholeNumber(@trunc(report.clipped_count));
        } else {
            builder.appendText("no block yet");
        }
        builder.appendText(" | posted ");
        builder.appendWholeNumber(page_audio.posted_command_count);
        builder.appendText(" commands, ");
        builder.appendWholeNumber(page_audio.posted_note_count);
        builder.appendText(" notes, ");
        builder.appendWholeNumber(page_audio.posted_samples_count);
        builder.appendText(" samples");
        if (page_audio.has_report) {
            builder.appendText("\nworklet: longest block ");
            builder.appendDecimal(page_audio.report.longest_block_ms, 2);
            builder.appendText(" ms, mean ");
            builder.appendDecimal(page_audio.report.mean_block_ms, 3);
            builder.appendText(" ms, longest gap ");
            builder.appendDecimal(page_audio.report.longest_gap_ms, 1);
            builder.appendText(" ms, handles ");
            builder.appendWholeNumber(@trunc(page_audio.report.worklet_handle_count));
            if (page_audio.report.is_worklet_clock_coarse) {
                builder.appendText(" (its clock counts whole ms)");
            }
        }
    }
    if (page_audio.mixer_voice_count) |voice_count| {
        builder.appendText("\nmixer: voices ");
        builder.appendWholeNumber(voice_count);
        // The page's own frames in the last second, on the main thread, beside the worklet's blocks above.
        builder.appendText(" | page frames: longest gap ");
        builder.appendDecimal(page_audio.shown_longest_frame_gap_ms, 1);
        builder.appendText(" ms, mean ");
        builder.appendDecimal(page_audio.shown_mean_frame_gap_ms, 1);
        // The page's handle table, read as this text is written - its own few handles in it: steady from refresh to
        // refresh while nothing leaks.
        builder.appendText(" ms, handles ");
        builder.appendWholeNumber(js_table_length());
    }
    if (page_audio.last_report_length > 0) {
        builder.appendText("\n");
        builder.appendText(page_audio.last_report[0..page_audio.last_report_length]);
    }
}

/// The panel's refreshes between two censuses of the page's handles: 40, ten seconds.
const census_refreshes: u32 = 40;

/// While handles are debugged, writes to the page's log - which the page shows - the page's live handles counted by
/// where they were made, every ten seconds: a leak shows as the code that made it, its count rising from census to
/// census.
fn writeCensusWhenDue() void {
    if (!page_audio.is_debugging_handles) {
        return;
    }
    page_audio.refreshes_since_census += 1;
    if (page_audio.refreshes_since_census < census_refreshes) {
        return;
    }
    page_audio.refreshes_since_census = 0;
    const census: Handle = js_handle_census(5);
    defer js_free(census);
    const heading: Handle = string("zimr: the page's live handles, by where they were made:\n");
    defer js_free(heading);
    const console: Handle = globalNamed("console");
    defer js_free(console);
    callVoid2(console, "warn", heading, census);
}

/// Writes the panel's text afresh: every 250 ms, from the page's timer.
fn refreshDiagnostics() void {
    const scope: Handle = js_mark();
    defer js_reset(scope);
    writeCensusWhenDue();
    readOutputContinuity();
    var builder: TextBuilder = .{};
    describeOutput(&builder);
    setProperty(page_audio.diagnostics_panel, "textContent", string(builder.writtenText()));
}

/// Turns the debugging of JavaScript handles on or off in both realms: this page's, at once, and the audio worklet's,
/// by a message (`{ kind: "debugHandles", on }`). The worklet sends a failure's stack with its message, debugging or
/// not; debugging adds where the handle was made and freed.
pub fn setHandleDebugging(is_on: bool) void {
    const scope: Handle = js_mark();
    defer js_reset(scope);
    js_set_handle_debugging(@intFromBool(is_on));
    page_audio.is_debugging_handles = is_on;
    if (page_audio.path != .renderer_worklet) {
        return;
    }
    const message: Handle = js_obj();
    const kind: Handle = string("debugHandles");
    setProperty(message, "kind", kind);
    const on_value: Handle = js_num(if (is_on) 1 else 0);
    setProperty(message, "on", on_value);
    const transfer_list: Handle = js_array();
    postToRenderer(message, transfer_list);
}

/// Shows the sound's diagnostics panel at the top of the page, refreshed every 250 ms (`describeOutput`): over the
/// page, translucent, letting the person's input through.
pub fn showDiagnostics() void {
    if (page_audio.diagnostics_panel != 0) {
        return;
    }
    const document: Handle = globalNamed("document");
    defer js_free(document);
    if (js_truthy(document) == 0) {
        return;
    }
    const tag_name: Handle = string("pre");
    defer js_free(tag_name);
    const panel: Handle = call1(document, "createElement", tag_name);
    const panel_style: Handle = property(panel, "style");
    defer js_free(panel_style);
    const style_text: Handle = string("position:fixed;left:0;top:0;width:100%;box-sizing:border-box;margin:0;" ++
        "padding:4px 8px;background:rgba(0,0,0,0.78);color:#cfe;font:11px/1.35 monospace;" ++
        "white-space:pre-wrap;z-index:99998;pointer-events:none");
    defer js_free(style_text);
    setProperty(panel_style, "cssText", style_text);
    const body: Handle = property(document, "body");
    defer js_free(body);
    callVoid1(body, "appendChild", panel);
    page_audio.diagnostics_panel = kept(panel);
    refreshDiagnostics();
    const refresh_handler: Handle = js_func(&refreshDiagnostics);
    defer js_free(refresh_handler);
    const refresh_interval_ms: Handle = js_num(250);
    defer js_free(refresh_interval_ms);
    callVoid2(js_global(), "setInterval", refresh_handler, refresh_interval_ms);
}

// ---- The page test's entry points, published only when this file is the program's root ----
//
// The bridge imports this file and calls its functions directly; nothing of it is exported there. Built on its own -
// the root of its own program, transpiled for `audio_page_test.cjs` - it publishes these, so that Node can drive the
// same functions against its stand-ins for the browser. A handle crosses as its number in the c2js runtime's table,
// as it does between the bridge and this file.

fn exportPrepareRenderer(program_text: Handle, app_module: Handle) callconv(.c) void {
    prepareRenderer(program_text, app_module);
}

fn exportIsRendererSettled() callconv(.c) u32 {
    return @intFromBool(isRendererSettled());
}

fn exportSetAppExports(app_exports: Handle) callconv(.c) void {
    setAppExports(app_exports);
}

fn exportStartForwarding(channel_count: u32) callconv(.c) f64 {
    return startForwarding(channel_count);
}

fn exportForwardCommandBytes(bytes_address: u32, byte_count: u32) callconv(.c) void {
    forwardCommandBytes(bytes_address, byte_count);
}

fn exportForwardSamples(
    samples_id: u32,
    samples_address: u32,
    sample_count: u32,
) callconv(.c) void {
    forwardSamples(samples_id, samples_address, sample_count);
}

fn exportForwardStreamFrames(
    stream_id: u32,
    channels: u32,
    sample_rate: u32,
    frames_address: u32,
    sample_count: u32,
) callconv(.c) void {
    forwardStreamFrames(stream_id, channels, sample_rate, frames_address, sample_count);
}

fn exportForwardNote(
    key: u32,
    is_down: u32,
    velocity: f64,
    requested_at_ms: f64,
    pressed_at_ms: f64,
) callconv(.c) void {
    forwardNote(key, is_down, velocity, requested_at_ms, pressed_at_ms);
}

fn exportTakeNoticeBytes(
    target_address: u32,
    capacity: u32,
    notice_byte_count: u32,
) callconv(.c) u32 {
    return takeNoticeBytes(target_address, capacity, notice_byte_count);
}

fn exportAskAnalysis() callconv(.c) void {
    askAnalysis();
}

fn exportTakeAnalysisFrames(target_address: u32, frame_count: u32) callconv(.c) u32 {
    return takeAnalysisFrames(target_address, frame_count);
}

fn exportStartPulled(sample_rate: f64, channel_count: u32) callconv(.c) f64 {
    return startPulled(sample_rate, channel_count);
}

fn exportOutputLatencyMilliseconds() callconv(.c) f64 {
    return outputLatencyMilliseconds();
}

fn exportOutputStatus() callconv(.c) u32 {
    return @backingInt(outputStatus());
}

fn exportNoteMixer(voice_count: u32) callconv(.c) void {
    noteMixer(voice_count);
}

fn exportShowDiagnostics() callconv(.c) void {
    showDiagnostics();
}

fn exportStop() callconv(.c) void {
    stop();
}

comptime {
    const is_program_root: bool = @import("root") == @This();
    if (is_program_root) {
        @export(&exportPrepareRenderer, .{ .name = "page_audio_prepare_renderer" });
        @export(&exportIsRendererSettled, .{ .name = "page_audio_is_renderer_settled" });
        @export(&exportSetAppExports, .{ .name = "page_audio_set_app_exports" });
        @export(&exportStartForwarding, .{ .name = "page_audio_start_forwarding" });
        @export(&exportForwardCommandBytes, .{ .name = "page_audio_forward_command_bytes" });
        @export(&exportForwardSamples, .{ .name = "page_audio_forward_samples" });
        @export(&exportForwardStreamFrames, .{ .name = "page_audio_forward_stream_frames" });
        @export(&exportForwardNote, .{ .name = "page_audio_forward_note" });
        @export(&exportTakeNoticeBytes, .{ .name = "page_audio_take_notice_bytes" });
        @export(&exportAskAnalysis, .{ .name = "page_audio_ask_analysis" });
        @export(&exportTakeAnalysisFrames, .{ .name = "page_audio_take_analysis_frames" });
        @export(&exportStartPulled, .{ .name = "page_audio_start_pulled" });
        @export(&exportOutputLatencyMilliseconds, .{ .name = "page_audio_output_latency_ms" });
        @export(&exportOutputStatus, .{ .name = "page_audio_output_status" });
        @export(&exportNoteMixer, .{ .name = "page_audio_note_mixer" });
        @export(&exportShowDiagnostics, .{ .name = "page_audio_show_diagnostics" });
        @export(&exportStop, .{ .name = "page_audio_stop" });
    }
}
