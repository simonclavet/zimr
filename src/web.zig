//! lint:alias web
//! lint:off arch-check: the browser's own module - its checks let it compile into host tests
// src/web.zig - browser bindings (DOM, Audio, fetch).
// Aggregates the four browser-binding modules into a single file with
// namespaced sub-structs:
//     web.dom    - canvas, time, frame loop, input  (extern "dom")
//     web.fetch  - async fetch handle protocol     (uses dom internally)
// Each section's contents are unchanged from before the merge - the
// only structural change is the `pub const X = struct { ... };` wrapper.
// Callers that did `const dom = @import("web.zig").dom` now use
// `const dom = @import("web.zig").dom`.

const std = @import("std");
const expectEqual = std.testing.expectEqual;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const zm = @import("zm");
/// Which path plays a page's sound and how far it has come, as page audio reports it (`page_audio.OutputStatus`) - the
/// bridge's file, imported for the type alone: its exports are made only where it is the program's root.
const AudioOutputStatus = @import("page_audio.zig").OutputStatus;
const float64 = zm.float64;

// ============================================================================
// SECTION - dom (was: src/dom.zig)
// ============================================================================

pub const dom = struct {
    pub const LogLevel = enum(u32) {
        debug = 0,
        info = 1,
        warn = 2,
        err = 3,
    };

    extern "dom" fn js_log(
        level: u32,
        ptr: [*]const u8,
        len: usize,
    ) void;

    /// Browser-side log line.  On host (non-wasm) builds, prints to
    /// stderr instead of routing through the JS bridge - the
    /// `extern "dom"` symbol resolves only under the wasm32 link
    /// environment, and any caller reachable from a `*.zig` test
    /// aggregator would otherwise drag the undefined symbol into
    /// the host test executable.
    pub fn log(level: LogLevel, msg: []const u8) void {
        if (comptime !builtin.target.cpu.arch.isWasm()) {
            const prefix: []const u8 = switch (level) {
                .debug, .info => "[zimr]",
                .warn => "[zimr WARN]",
                .err => "[zimr ERR]",
            };
            // Host-only stderr fallback (the wasm path below routes through
            // js_log). std.debug.print is the right call on the host - there
            // is no JS bridge - and the !isWasm gate keeps it off the wasm
            // path where the raw-stderr writer traps under ReleaseSmall.
            // lint:off debug-print: host-only stderr fallback, gated !isWasm
            std.debug.print("{s} {s}\n", .{ prefix, msg });
            return;
        }
        js_log(@backingInt(level), msg.ptr, msg.len);
    }

    extern "dom" fn js_panic(ptr: [*]const u8, len: usize) noreturn;

    pub fn panic(msg: []const u8) noreturn {
        if (comptime !builtin.target.cpu.arch.isWasm()) {
            @panic(msg);
        }
        js_panic(msg.ptr, msg.len);
    }

    // ----- Time
    // The page's clock is registered once, in the "wgpu" import object, where the engine's own clock reads it
    // (`wgpu.nowMs`); declared here under that module, it is the same import. A browser binds an import by its module
    // and its name together: declared under "dom", the page would be refused at load.
    extern "wgpu" fn js_now_ms() f64;
    extern "dom" fn js_epoch_ms() f64;
    extern "dom" fn js_tz_offset_min() f64;

    /// `performance.now()` - milliseconds since page load, sub-ms precision.
    pub fn now_ms() f64 {
        return js_now_ms();
    }

    /// `Date.now()` - milliseconds since the Unix epoch (UTC), wall-clock.
    pub fn epoch_ms() f64 {
        if (comptime !builtin.target.cpu.arch.isWasm()) {
            // Native host has no browser wall-clock, and Zig 0.16+ dropped the
            // free `std.time.*Timestamp` helpers (a wall clock now needs an `io`
            // handle threaded through juicy-main, which this browser-only path
            // has no access to). Mirror `runtime.hostNow`: return 0 on host -
            // this path is only reached in host analysis/tests, never in the
            // wasm build, which takes `js_epoch_ms()` below.
            return 0;
        }
        return js_epoch_ms();
    }

    /// Minutes to ADD to local time to reach UTC (JS `getTimezoneOffset()`),
    /// i.e. `local = UTC - offset`. East-of-UTC zones are negative.
    pub fn tz_offset_min() f64 {
        if (comptime !builtin.target.cpu.arch.isWasm()) {
            return 0; // native host has no browser tz; treat as UTC
        }
        return js_tz_offset_min();
    }

    /// A broken-down local date/time. `weekday` is 0=Sunday .. 6=Saturday.
    pub const DateTime = struct {
        year: i32,
        month: u8, // 1-12
        day: u8, // 1-31
        hour: u8, // 0-23
        minute: u8, // 0-59
        second: u8, // 0-59
        millis: u16, // 0-999
        weekday: u8, // 0=Sunday .. 6=Saturday
    };

    /// Decompose a UTC epoch-millisecond value into a local `DateTime`, given the
    /// timezone offset in minutes (UTC - local). Pure + deterministic: this is the
    /// host-testable core, with no dependency on the browser clock. Uses Howard
    /// Hinnant's civil-from-days algorithm for the calendar fields.
    pub fn fromEpochMillis(epoch_ms_utc: f64, offset_min: i32) DateTime {
        const local_ms_f: f64 = epoch_ms_utc - float64(offset_min) * 60_000.0;
        const local_ms: i64 = @floor(local_ms_f);
        const ms_per_day: i64 = 86_400_000;
        const days: i64 = @divFloor(local_ms, ms_per_day);
        var rem: i64 = local_ms - days * ms_per_day; // [0, ms_per_day)
        const millis: i64 = @mod(rem, 1000);
        rem = @divFloor(rem, 1000); // seconds of day
        const second: i64 = @mod(rem, 60);
        const minute: i64 = @mod(@divFloor(rem, 60), 60);
        const hour: i64 = @divFloor(rem, 3600);
        const weekday: i64 = @mod(days + 4, 7); // 1970-01-01 was a Thursday (=4)

        // civil_from_days (Hinnant): days since epoch -> Gregorian y/m/d
        const z: i64 = days + 719_468;
        const era: i64 = @divFloor(if (z >= 0) z else z - 146_096, 146_097);
        const doe: i64 = z - era * 146_097; // [0, 146096]
        const yoe: i64 = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36_524) - @divFloor(doe, 146_096), 365);
        const y: i64 = yoe + era * 400;
        const doy: i64 = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
        const mp: i64 = @divFloor(5 * doy + 2, 153); // [0, 11]
        const d: i64 = doy - @divFloor(153 * mp + 2, 5) + 1; // [1, 31]
        const m: i64 = if (mp < 10) mp + 3 else mp - 9; // [1, 12]
        const year: i64 = y + @as(i64, if (m <= 2) 1 else 0);

        return .{
            .year = @intCast(year),
            .month = @intCast(m),
            .day = @intCast(d),
            .hour = @intCast(hour),
            .minute = @intCast(minute),
            .second = @intCast(second),
            .millis = @intCast(millis),
            .weekday = @intCast(weekday),
        };
    }

    /// The current local wall-clock date/time (real time of day, DST-correct).
    pub fn localNow() DateTime {
        const off: i32 = @round(tz_offset_min());
        return fromEpochMillis(epoch_ms(), off);
    }

    /// Milliseconds since the Unix epoch (UTC). Alias of `epoch_ms()` for the
    /// public name surfaced on `z`.
    pub fn epochMillis() f64 {
        return epoch_ms();
    }

    // ----- Canvas
    extern "dom" fn js_canvas_set_size(css_w: u32, css_h: u32) u32;
    extern "dom" fn js_canvas_drawing_width() u32;
    extern "dom" fn js_canvas_drawing_height() u32;
    extern "dom" fn js_canvas_css_width() u32;
    extern "dom" fn js_canvas_css_height() u32;
    extern "dom" fn js_set_title(ptr: [*]const u8, len: usize) void;

    /// Set the canvas CSS size.  Returns the chosen backing-store width
    /// (which is dpr * css px and may have been clamped).
    pub fn canvas_set_size(css_w: u32, css_h: u32) u32 {
        return js_canvas_set_size(css_w, css_h);
    }

    /// Backing-store width in physical pixels.
    pub fn canvas_drawing_width() u32 {
        return js_canvas_drawing_width();
    }

    /// Backing-store height in physical pixels.
    pub fn canvas_drawing_height() u32 {
        return js_canvas_drawing_height();
    }

    /// Canvas display size in CSS pixels (not buffer pixels).  Use
    /// this for "what's my window size right now?" - it tracks the
    /// host page's CSS sizing of the canvas, including any
    /// responsive rules like `width: 100vw`.  Always equals
    /// `drawing_width / devicePixelRatio` up to rounding.
    pub fn canvas_css_width() u32 {
        return js_canvas_css_width();
    }

    /// Canvas display size in CSS pixels.  See `canvas_css_width`.
    pub fn canvas_css_height() u32 {
        return js_canvas_css_height();
    }

    /// Update document.title.
    pub fn set_title(s: []const u8) void {
        js_set_title(s.ptr, s.len);
    }

    // ----- Fullscreen / DPI / URL / screenshot
    extern "dom" fn js_get_dpi_scale() f32;
    extern "dom" fn js_screen_width() f32;
    extern "dom" fn js_gamepad_state(slot: u32, out: [*]f32) u32;
    extern "dom" fn js_audio_output_stop() void;
    extern "dom" fn js_audio_output_show_diagnostics() void;
    extern "dom" fn js_audio_output_set_handle_debugging(is_on: u32) void;
    extern "dom" fn js_audio_output_latency_ms() f64;
    extern "dom" fn js_audio_output_status() u32;
    extern "dom" fn js_audio_forward_start(sample_rate: u32, channel_count: u32) u32;
    extern "dom" fn js_audio_output_start_pulled(sample_rate: u32, channel_count: u32) u32;
    extern "dom" fn js_audio_forward_command(bytes: [*]const u8, byte_count: u32) void;
    extern "dom" fn js_audio_forward_samples(
        samples_id: u32,
        samples: [*]const f32,
        sample_count: u32,
    ) void;
    extern "dom" fn js_audio_forward_note(
        key: u32,
        is_down: u32,
        velocity: f32,
        requested_at_ms: f64,
        pressed_at_ms: f64,
    ) void;
    extern "dom" fn js_audio_forward_stream_frames(
        stream_id: u32,
        channels: u32,
        sample_rate: u32,
        frames: [*]const f32,
        sample_count: u32,
    ) void;
    extern "dom" fn js_audio_take_notice_bytes(
        target: [*]u8,
        capacity: u32,
        notice_byte_count: u32,
    ) u32;
    extern "dom" fn js_audio_output_note_mixer(voice_count: u32) void;
    extern "dom" fn js_audio_ask_analysis() void;
    extern "dom" fn js_audio_take_analysis_frames(target: [*]f32, frame_count: u32) u32;

    /// Shows the sound's diagnostics panel at the top of the page.
    pub fn audio_output_show_diagnostics() void {
        js_audio_output_show_diagnostics();
    }

    /// Turns the debugging of JavaScript handles on (1) or off (0), in the page and its audio worklet.
    pub fn audio_output_set_handle_debugging(is_on: u32) void {
        js_audio_output_set_handle_debugging(is_on);
    }

    /// How long a frame the output counted as played still takes to be heard, in milliseconds: the script processor's
    /// buffer when it plays, and the context's `baseLatency + outputLatency` (`page_audio.outputLatencyMilliseconds`).
    pub fn audio_output_latency_ms() f64 {
        return js_audio_output_latency_ms();
    }

    /// Which path plays the sound, and how far it has come (`page_audio.OutputStatus`), from the integer the bridge
    /// reports - an integer the enum does not name stops a safe build at once.
    pub fn audio_output_status() AudioOutputStatus {
        return @fromBackingInt(@intCast(js_audio_output_status()));
    }

    /// Starts the output pulled on the main thread (`page_audio.startPulled`): a script processor whose
    /// callback asks the app's renderer for each block through the module's export `zimr_audio_pull_block`. Returns
    /// the rate granted, or 0 when the browser has no script processor either.
    pub fn audio_output_start_pulled(sample_rate: u32, channel_count: u32) u32 {
        return js_audio_output_start_pulled(sample_rate, channel_count);
    }

    /// Starts the renderer worklet loaded at boot (`page_audio.prepareRenderer`): the rate granted, or 0 when it did
    /// not load and the mixer must pull through the script processor instead.
    pub fn audio_forward_start(sample_rate: u32, channel_count: u32) u32 {
        return js_audio_forward_start(sample_rate, channel_count);
    }

    /// Posts a command's bytes, samples to register, or a key's event to the renderer worklet.
    pub fn audio_forward_command(command_bytes: []const u8) void {
        js_audio_forward_command(command_bytes.ptr, @intCast(command_bytes.len));
    }

    pub fn audio_forward_samples(samples_id: u32, samples: []const f32) void {
        js_audio_forward_samples(samples_id, samples.ptr, @intCast(samples.len));
    }

    pub fn audio_forward_stream_frames(
        stream_id: u32,
        channels: u32,
        sample_rate: u32,
        frames: []const f32,
    ) void {
        js_audio_forward_stream_frames(stream_id, channels, sample_rate, frames.ptr, @intCast(frames.len));
    }

    pub fn audio_forward_note(
        key: u32,
        is_down: bool,
        velocity: f32,
        requested_at_ms: f64,
        pressed_at_ms: f64,
    ) void {
        js_audio_forward_note(key, @intFromBool(is_down), velocity, requested_at_ms, pressed_at_ms);
    }

    /// Copies the notices the renderer worklet sent back into `target`, whole notices of `notice_byte_count` bytes
    /// only, and returns the bytes copied.
    pub fn audio_take_notice_bytes(target: []u8, notice_byte_count: u32) usize {
        return js_audio_take_notice_bytes(target.ptr, @intCast(target.len), notice_byte_count);
    }

    /// Asks the renderer worklet for its last frames mixed, for an analyser; a request already waiting is not repeated.
    pub fn audio_ask_analysis() void {
        js_audio_ask_analysis();
    }

    /// Copies the last `target.len` frames of the renderer worklet's last answer into `target`, oldest first, and
    /// returns how many it copied: `target.len`, or 0 before the first answer.
    pub fn audio_take_analysis_frames(target: []f32) usize {
        return js_audio_take_analysis_frames(target.ptr, @intCast(target.len));
    }

    /// Hands the diagnostics panel the mixer's count of playing voices.
    pub fn audio_output_note_mixer(voice_count: u32) void {
        js_audio_output_note_mixer(voice_count);
    }

    /// Closes the sound output.
    pub fn audio_output_stop() void {
        js_audio_output_stop();
    }

    /// The gamepad in a slot (`navigator.getGamepads()`): its 17 buttons in the standard gamepad's order, then its 4
    /// axes, written into `out`; 1 when there is one, 0 when the slot is empty.
    pub fn gamepad_state(slot: u32, out: *[21]f32) u32 {
        return js_gamepad_state(slot, out);
    }
    extern "dom" fn js_screen_height() f32;

    /// The screen's width and height, in CSS pixels (`screen.width`, `screen.height`): the monitor a page sees.
    pub fn screen_width() f32 {
        return js_screen_width();
    }

    pub fn screen_height() f32 {
        return js_screen_height();
    }
    extern "dom" fn js_toggle_fullscreen() void;
    extern "dom" fn js_is_fullscreen() u32;
    extern "dom" fn js_open_url(ptr: [*]const u8, len: usize) void;
    extern "dom" fn js_take_screenshot(name_ptr: [*]const u8, name_len: usize) void;

    /// `window.devicePixelRatio` (1.0 if not available).
    pub fn get_dpi_scale() f32 {
        return js_get_dpi_scale();
    }

    /// Toggle browser-fullscreen on the canvas.  Most browsers require
    /// this be called from a user-gesture handler.
    pub fn toggle_fullscreen() void {
        js_toggle_fullscreen();
    }

    /// True if `document.fullscreenElement` is non-null.
    pub fn is_fullscreen() bool {
        return js_is_fullscreen() != 0;
    }

    /// `window.open(url, '_blank', 'noopener,noreferrer')`.
    pub fn open_url(url: []const u8) void {
        js_open_url(url.ptr, url.len);
    }

    /// Trigger a `<a download>` of the canvas contents as PNG.
    pub fn take_screenshot(filename: []const u8) void {
        js_take_screenshot(filename.ptr, filename.len);
    }

    // ----- Soft keyboard / text-input overlay (mobile + desktop)
    // We use the "visible DOM overlay" approach pioneered by
    // zhobo63/imgui-ts (the most successful imgui-web binding for
    // mobile).  Instead of forwarding keystrokes from a hidden
    // input into wasm, we render a REAL visible `<input type="text">`
    // positioned exactly over the imgui-drawn widget rect, styled
    // to match (font, color, bg).  While focused, the DOM input IS
    // the text editor - native browser handles backspace, IME,
    // selection, cursor, copy/paste, scroll-into-view-above-keyboard.
    // Each frame, wasm polls `get_overlay_input_text` to sync the
    // DOM input's value back into the imgui-side buffer.
    // This avoids the entire class of bugs that plagued the older
    // hidden-input approach (see plan v3 for the history):
    //   - Backspace doesn't fire `keydown` reliably on Android
    //     soft keyboards (it goes through `inputType:
    //     deleteContentBackward` instead).
    //   - First-tap-doesn't-pop-keyboard from gesture-context races.
    //   - Manual scroll-into-view fights iOS native auto-scroll.
    // `screen_x, screen_y, w, h` are CSS pixels in the canvas's
    // coordinate space (which is the viewport's coord space for
    // fullscreen demos).  `font_px` is the widget's font size in
    // CSS pixels.  `fg/bg` are RGBA u32 colors (matches zimr's
    // internal color packing).

    extern "dom" fn js_show_overlay_input(
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        text_ptr: [*]const u8,
        text_len: usize,
        font_px: f32,
        fg_rgba: u32,
        bg_rgba: u32,
    ) void;

    extern "dom" fn js_hide_overlay_input() void;

    // Reposition the overlay input to a new rect without changing
    // focus, value, or selection.  Called every frame while a text
    // widget is active so the overlay tracks window drags / scrolls /
    // viewport resizes.  Cheap (style write only); JS bails early if
    // the overlay element isn't shown.
    extern "dom" fn js_update_overlay_input_rect(
        x: f32,
        y: f32,
        w: f32,
        h: f32,
    ) void;

    // Returns 1 if the overlay input is currently visible (and
    // therefore expected to have focus); 0 if hidden.  Wasm polls
    // this each frame to detect user-initiated blur (tap outside
    // the input on the page, Enter on a single-line input - both
    // trigger blur on the JS side; we mirror to `active_id = 0`
    // wasm-side so the widget's edit state matches reality).
    extern "dom" fn js_overlay_input_is_visible() u32;

    // Returns the byte length written into `out_ptr`.  Caller must
    // size `max_len` large enough for the widget's buffer; bytes
    // past max_len are silently dropped.  On host builds, returns 0.
    extern "dom" fn js_get_overlay_input_text(
        out_ptr: [*]u8,
        max_len: usize,
    ) usize;

    pub fn show_overlay_input(
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        text: []const u8,
        font_px: f32,
        fg_rgba: u32,
        bg_rgba: u32,
    ) void {
        js_show_overlay_input(x, y, w, h, text.ptr, text.len, font_px, fg_rgba, bg_rgba);
    }

    pub fn hide_overlay_input() void {
        js_hide_overlay_input();
    }

    pub fn update_overlay_input_rect(x: f32, y: f32, w: f32, h: f32) void {
        js_update_overlay_input_rect(x, y, w, h);
    }

    pub fn overlay_input_is_visible() bool {
        return js_overlay_input_is_visible() != 0;
    }

    pub fn get_overlay_input_text(out: []u8) usize {
        return js_get_overlay_input_text(out.ptr, out.len);
    }

    extern "dom" fn js_set_overlay_input_text(
        text_ptr: [*]const u8,
        text_len: usize,
        caret: usize,
    ) void;
    /// Replaces the overlay input's text - after zimr's filters changed what the browser's editor let in - and puts
    /// its caret at byte `caret` of the text, a character boundary.
    pub fn setOverlayInputText(text: []const u8, caret: usize) void {
        js_set_overlay_input_text(text.ptr, text.len, caret);
    }

    // ----- Clipboard
    // Write is sync (best-effort); read is async via the same
    // fetch-handle protocol as `js_fetch_*` (status: 0 pending,
    // 1 ready, 2 not-found / no-image, 3 failed).

    extern "dom" fn js_set_clipboard_text(ptr: [*]const u8, len: usize) void;
    extern "dom" fn js_get_clipboard_text_start() u32;
    extern "dom" fn js_get_clipboard_image_start() u32;

    pub fn set_clipboard_text(text: []const u8) void {
        js_set_clipboard_text(text.ptr, text.len);
    }

    pub fn get_clipboard_text_start() u32 {
        return js_get_clipboard_text_start();
    }

    pub fn get_clipboard_image_start() u32 {
        return js_get_clipboard_image_start();
    }

    // (Reads use the existing `js_fetch_poll` / `js_fetch_data_ptr` /
    // `js_fetch_data_len` / `js_fetch_release` protocol - no need to
    // duplicate those externs here; runtime.zig's `core.clipboard*`
    // wrappers grab them from the loader-side imports.)

    // ----- Persistence
    // Sync localStorage-backed key/value store.  Used by the UI
    // persistence layer (`src/ui_persistence.zig`) to round-trip
    // per-window state across page reloads.
    // localStorage is synchronous on the JS side - no Promise / fetch-
    // handle dance.  Three externs:
    //   - `js_persistence_save(key, val) -> i32`
    //       0  = ok
    //       1  = quota exceeded
    //       2  = localStorage unavailable (private mode, disabled)
    //   - `js_persistence_size(key) -> i32`
    //       >= 0 = byte length of stored value
    //       -1   = key not present
    //       -2   = localStorage unavailable
    //   - `js_persistence_read(key, out_ptr, out_cap) -> i32`
    //       >= 0 = bytes copied (may be 0 for empty values)
    //       -1   = key not present
    //       -2   = localStorage unavailable
    //       -3   = buffer too small (caller must allocate `size` bytes
    //              based on the prior `js_persistence_size` call)
    // The two-call read protocol (size first, then read with a sized
    // buffer) avoids guess-and-grow.  Caller pattern in Zig:
    //     const sz = web.persistence_size("zimr_demo");
    //     if (sz < 0) return null;  // missing or unavailable
    //     const buf = try gpa.alloc(u8, @intCast(sz));
    //     const got = web.persistence_read("zimr_demo", buf);
    //     // got == sz on success
    // Keys are namespaced by the caller (zimr appends "zimr_" prefix
    // in the JS layer to avoid clashing with the host page's own
    // localStorage keys - see the TS side).

    extern "dom" fn js_persistence_save(
        key_ptr: [*]const u8,
        key_len: usize,
        val_ptr: [*]const u8,
        val_len: usize,
    ) i32;
    extern "dom" fn js_persistence_size(key_ptr: [*]const u8, key_len: usize) i32;
    extern "dom" fn js_persistence_read(
        key_ptr: [*]const u8,
        key_len: usize,
        out_ptr: [*]u8,
        out_cap: usize,
    ) i32;
    extern "dom" fn js_persistence_remove(key_ptr: [*]const u8, key_len: usize) i32;

    /// Save `bytes` under `key` in localStorage.  Returns one of
    /// the documented status codes; callers typically check for 0
    /// (success) and log on anything else.  The "zimr_" prefix is
    /// added by the JS layer - don't pre-namespace `key`.
    pub fn persistence_save(key: []const u8, bytes: []const u8) i32 {
        return js_persistence_save(key.ptr, key.len, bytes.ptr, bytes.len);
    }

    /// Size of the stored value under `key`, or -1 missing / -2
    /// unavailable.  Use in tandem with `persistence_read` to size
    /// a destination buffer.
    pub fn persistence_size(key: []const u8) i32 {
        return js_persistence_size(key.ptr, key.len);
    }

    /// Copy the stored value into `out`.  Returns bytes copied or
    /// one of the documented negative codes.  Caller MUST have
    /// allocated `out` to at least the value's full size (use
    /// `persistence_size` to query).
    pub fn persistence_read(key: []const u8, out: []u8) i32 {
        return js_persistence_read(key.ptr, key.len, out.ptr, out.len);
    }

    /// Remove a key from localStorage.  Returns 0 on success (whether
    /// the key existed or not) or 2 if storage is unavailable.  Used
    /// by demos that want to clear their persisted state.
    pub fn persistence_remove(key: []const u8) i32 {
        return js_persistence_remove(key.ptr, key.len);
    }

    /// Convenience: load a value into a fresh allocation.  Returns
    /// null if the key is missing or storage is unavailable; the
    /// caller owns the returned slice and frees with `gpa.free`.
    /// Used by the UI persistence auto-load path.
    pub fn persistence_load(gpa: Allocator, key: []const u8) Allocator.Error!?[]u8 {
        const sz: i32 = persistence_size(key);
        if (sz < 0) {
            return null;
        }
        const cap: usize = @intCast(sz);
        const buf: []u8 = try gpa.alloc(u8, cap);
        const got: i32 = persistence_read(key, buf);
        if (got < 0) {
            // Race or quota glitch - bail cleanly.  In practice
            // shouldn't happen between size + read; we keep the
            // check to avoid undefined behavior on the buffer.
            gpa.free(buf);
            return null;
        }
        // If we somehow got fewer bytes than expected, shrink.
        const got_usize: usize = @intCast(got);
        if (got_usize < cap) {
            const resized: []u8 = try gpa.realloc(buf, got_usize);
            return resized;
        }
        return buf;
    }

    /// Binary-safe save.  localStorage only holds UTF-8 text, so raw binary
    /// (anything that isn't valid UTF-8 - e.g. serialized structs, float
    /// bytes) gets mangled by the string round-trip that `persistence_save`
    /// does.  This base64-encodes `bytes` first - base64 is pure ASCII, so it
    /// survives the text round-trip losslessly - then stores that.  Use this
    /// (not `persistence_save`) for serialized structs / binary blobs.  Returns
    /// the same status codes as `persistence_save`.
    pub fn persistence_save_bytes(
        gpa: Allocator,
        key: []const u8,
        bytes: []const u8,
    ) Allocator.Error!i32 {
        const encoder = std.base64.standard.Encoder;
        const b64: []u8 = try gpa.alloc(u8, encoder.calcSize(bytes.len));
        defer gpa.free(b64);
        _ = encoder.encode(b64, bytes);
        return persistence_save(key, b64);
    }

    /// Binary-safe load - the counterpart to `persistence_save_bytes`.  Reads
    /// the stored base64 string and decodes it back to the exact original
    /// bytes.  Returns null if the key is missing, storage is unavailable, or
    /// the stored value isn't valid base64.  Caller owns the returned slice.
    pub fn persistence_load_bytes(gpa: Allocator, key: []const u8) Allocator.Error!?[]u8 {
        const b64: []u8 = (try persistence_load(gpa, key)) orelse return null;
        defer gpa.free(b64);
        const decoder = std.base64.standard.Decoder;
        const out_len: usize = decoder.calcSizeForSlice(b64) catch return null;
        const out: []u8 = try gpa.alloc(u8, out_len);
        decoder.decode(out, b64) catch {
            gpa.free(out);
            return null;
        };
        return out;
    }

    // ----- Cursor / pointer-lock
    extern "dom" fn js_set_cursor_style(style: u32) void;
    extern "dom" fn js_request_pointer_lock() void;
    extern "dom" fn js_exit_pointer_lock() void;
    extern "dom" fn js_keep_awake(on: u32) void;
    extern "dom" fn js_request_paste() void;
    extern "dom" fn js_pointer_lock_active() u32;

    /// 0 = default cursor, 1 = none (hidden).
    pub fn set_cursor_style(style: u32) void {
        js_set_cursor_style(style);
    }
    pub fn request_pointer_lock() void {
        js_request_pointer_lock();
    }
    pub fn keep_awake(on: bool) void {
        js_keep_awake(@intFromBool(on));
    }
    pub fn request_paste() void {
        js_request_paste();
    }
    pub fn exit_pointer_lock() void {
        js_exit_pointer_lock();
    }
    pub fn pointer_lock_active() bool {
        return js_pointer_lock_active() != 0;
    }

    // ----- Mobile soft-keyboard hint
    extern "dom" fn js_set_input_mode(ptr: [*]const u8, len: usize) void;

    /// Set the HTML `inputmode` attribute on the hidden DOM input
    /// that captures keyboard events on mobile.  Pass the lower-
    /// case mode string ("text", "numeric", "decimal", "email",
    /// "tel", "url", "search") - the JS bridge writes it through.
    /// An empty slice clears the attribute, restoring the
    /// platform default soft-keyboard.
    pub fn set_input_mode(mode: []const u8) void {
        js_set_input_mode(mode.ptr, mode.len);
    }

    // ----- P9.2 overlay-input behavior flags
    // Each flag flips a property on the live overlay `<input>`
    // element AFTER `show_overlay_input` has set up the element
    // (because the element must exist before the property write
    // takes effect).  The JS handlers are idempotent and tolerate
    // being called when the overlay isn't shown - they store the
    // value on `RuntimeState` and the next `show_overlay_input`
    // applies it.
    //
    // Boolean values cross the wasm/JS boundary as u32: 0 = false,
    // anything-else = true.  Idiomatic in Zig's wasm ABI (no
    // native bool packing across an extern).

    extern "dom" fn js_set_overlay_input_password(on: u32) void;
    extern "dom" fn js_set_overlay_input_read_only(on: u32) void;
    extern "dom" fn js_set_overlay_input_escape_clears(on: u32) void;
    extern "dom" fn js_set_overlay_input_allow_tab(on: u32) void;

    /// Flip `type="password"` on the overlay input.  Browser
    /// handles masking + no-autofill + secure-paste.  Default
    /// (off) restores `type="text"`.
    pub fn set_overlay_input_password(on: bool) void {
        js_set_overlay_input_password(if (on) 1 else 0);
    }

    /// Flip the `readOnly` property on the overlay input.  Caret
    /// + selection still work; insertions / deletions don't.
    /// Mobile soft keyboard typically doesn't pop on read-only
    /// fields (browser-defined; acceptable).
    pub fn set_overlay_input_read_only(on: bool) void {
        js_set_overlay_input_read_only(if (on) 1 else 0);
    }

    /// When set, the overlay's Esc-keydown handler clears the
    /// input value before blurring (so the wasm side polls an
    /// empty buffer next frame and observes the "cancel").
    /// Without this flag, Esc just blurs and the buffer keeps
    /// its last value.
    pub fn set_overlay_input_escape_clears(on: bool) void {
        js_set_overlay_input_escape_clears(if (on) 1 else 0);
    }

    /// When set, the overlay's Tab-keydown handler inserts a
    /// `\t` character at the caret instead of letting the browser
    /// advance focus.  Without this flag, Tab leaves the field
    /// (browser default).
    pub fn set_overlay_input_allow_tab(on: bool) void {
        js_set_overlay_input_allow_tab(if (on) 1 else 0);
    }

    // ----- P9.1 char filters on the web path
    // Bug found via turn 440b phone testing: the host-path
    // `applyCharsFlagFilters` doesn't run on web because the DOM
    // overlay input is the editor - wasm only polls the final
    // value, never sees individual keystrokes.  The fix layers a
    // JS-side 'input' event listener that applies the same filter
    // logic to the overlay's value on every keystroke.  Wasm
    // packs the active chars_* flags into a bitmask and pushes it
    // to JS at show time.

    extern "dom" fn js_set_overlay_input_char_filters(flags: u32) void;

    pub const char_filter_decimal: u32 = 0x01;
    pub const char_filter_hexadecimal: u32 = 0x02;
    pub const char_filter_scientific: u32 = 0x04;
    pub const char_filter_uppercase: u32 = 0x08;
    pub const char_filter_no_blank: u32 = 0x10;

    /// Push the active char-filter bitmask to the overlay input's
    /// 'input' event listener.  Pass 0 to disable filtering (every
    /// keystroke passes through).
    pub fn set_overlay_input_char_filters(flags: u32) void {
        js_set_overlay_input_char_filters(flags);
    }

    // ----- Multiline `<textarea>` overlay (turn 441b)
    // Sibling of the single-line overlay above.  Lifts mobile
    // multiline from "no soft keyboard, broken" to "works."
    // Today: duplicated structure.  After both paths are
    // exercised in real demos, we'll likely unify the show/hide/
    // poll/attribute machinery behind a "current overlay
    // element" abstraction - but the right factoring isn't
    // obvious until the second overlay exists.

    extern "dom" fn js_show_overlay_textarea(
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        text_ptr: [*]const u8,
        text_len: usize,
        font_px: f32,
        fg_rgba: u32,
        bg_rgba: u32,
    ) void;
    extern "dom" fn js_hide_overlay_textarea() void;
    extern "dom" fn js_update_overlay_textarea_rect(
        x: f32,
        y: f32,
        w: f32,
        h: f32,
    ) void;
    extern "dom" fn js_overlay_textarea_is_visible() u32;
    extern "dom" fn js_get_overlay_textarea_text(
        out_ptr: [*]u8,
        max_len: usize,
    ) usize;

    pub fn show_overlay_textarea(
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        text: []const u8,
        font_px: f32,
        fg_rgba: u32,
        bg_rgba: u32,
    ) void {
        js_show_overlay_textarea(x, y, w, h, text.ptr, text.len, font_px, fg_rgba, bg_rgba);
    }
    pub fn hide_overlay_textarea() void {
        js_hide_overlay_textarea();
    }
    pub fn update_overlay_textarea_rect(x: f32, y: f32, w: f32, h: f32) void {
        js_update_overlay_textarea_rect(x, y, w, h);
    }
    pub fn overlay_textarea_is_visible() bool {
        return js_overlay_textarea_is_visible() != 0;
    }
    extern "dom" fn js_set_overlay_textarea_text(
        text_ptr: [*]const u8,
        text_len: usize,
        caret: usize,
    ) void;
    /// Replaces the overlay text area's text, as `setOverlayInputText` does the input's.
    pub fn setOverlayTextareaText(text: []const u8, caret: usize) void {
        js_set_overlay_textarea_text(text.ptr, text.len, caret);
    }

    pub fn get_overlay_textarea_text(out: []u8) usize {
        return js_get_overlay_textarea_text(out.ptr, out.len);
    }

    // ----- Textarea attribute setters
    // Same semantics + bit assignments as the `<input>` setters
    // above.  No `password` variant (textareas can't be
    // `type=password`).  Each setter is idempotent and tolerates
    // the textarea not yet existing.

    extern "dom" fn js_set_overlay_textarea_read_only(on: u32) void;
    extern "dom" fn js_set_overlay_textarea_escape_clears(on: u32) void;
    extern "dom" fn js_set_overlay_textarea_allow_tab(on: u32) void;
    extern "dom" fn js_set_overlay_textarea_char_filters(flags: u32) void;
    extern "dom" fn js_set_overlay_textarea_ctrl_enter_for_newline(on: u32) void;

    pub fn set_overlay_textarea_read_only(on: bool) void {
        js_set_overlay_textarea_read_only(if (on) 1 else 0);
    }
    pub fn set_overlay_textarea_escape_clears(on: bool) void {
        js_set_overlay_textarea_escape_clears(if (on) 1 else 0);
    }
    pub fn set_overlay_textarea_allow_tab(on: bool) void {
        js_set_overlay_textarea_allow_tab(if (on) 1 else 0);
    }
    pub fn set_overlay_textarea_char_filters(flags: u32) void {
        js_set_overlay_textarea_char_filters(flags);
    }

    /// Multiline-only.  When set, plain Enter blurs (commits)
    /// instead of inserting `\n`; Ctrl+Enter inserts the newline.
    /// Default off: Enter inserts as the browser would, no
    /// special handling.  Consulted in the textarea's keydown
    /// listener.
    pub fn set_overlay_textarea_ctrl_enter_for_newline(on: bool) void {
        js_set_overlay_textarea_ctrl_enter_for_newline(if (on) 1 else 0);
    }

    // ----- Window UX (Phase-1A bridge-the-gap)
    extern "dom" fn js_set_mouse_cursor(cursor: u32) void;
    extern "dom" fn js_set_window_opacity(opacity: f32) void;
    extern "dom" fn js_set_window_focused() void;
    extern "dom" fn js_window_resized_take() u32;
    extern "dom" fn js_set_window_icon_png(ptr: [*]const u8, len: usize) void;
    extern "dom" fn js_dropped_files_count() u32;
    extern "dom" fn js_dropped_file_byte_len(idx: u32) u32;
    extern "dom" fn js_dropped_file_bytes(
        idx: u32,
        dst: [*]u8,
        len: u32,
    ) void;
    extern "dom" fn js_dropped_file_name_len(idx: u32) u32;
    extern "dom" fn js_dropped_file_name(
        idx: u32,
        dst: [*]u8,
        len: u32,
    ) void;
    extern "dom" fn js_dropped_files_clear() void;

    /// Set the canvas cursor style.  `cursor` is a `MouseCursor` enum
    /// value (raylib parity); JS maps it to a CSS keyword.
    pub fn set_mouse_cursor(cursor: u32) void {
        js_set_mouse_cursor(cursor);
    }

    /// Set the canvas CSS opacity in [0, 1].
    pub fn set_window_opacity(opacity: f32) void {
        js_set_window_opacity(opacity);
    }

    /// Programmatically focus the canvas.
    pub fn set_window_focused() void {
        js_set_window_focused();
    }

    /// Read-and-clear the "canvas resized" flag.  JS sets the flag from
    /// a `ResizeObserver` callback; the first read after a resize
    /// returns true and clears the flag.  Idempotent on subsequent
    /// reads until the next resize.
    pub fn window_resized_take() bool {
        return js_window_resized_take() != 0;
    }

    /// Set the favicon to the given PNG bytes.  JS wraps as a Blob and
    /// swaps the `<link rel="icon">`.  Caller's bytes are copied into
    /// JS heap; the caller can free immediately after the call returns.
    pub fn set_window_icon_png(bytes: []const u8) void {
        js_set_window_icon_png(bytes.ptr, bytes.len);
    }

    // ---- Dropped-file table
    // JS captures `drop` events on the canvas, reads each file via
    // `FileReader.readAsArrayBuffer`, and stores `{name, bytes}` in a
    // table.  Zig pulls items via the `dropped_*` accessors.  Caller is
    // expected to call `dropped_files_clear` after consuming.

    pub fn dropped_files_count() u32 {
        return js_dropped_files_count();
    }
    pub fn dropped_file_byte_len(idx: u32) u32 {
        return js_dropped_file_byte_len(idx);
    }
    pub fn dropped_file_bytes(
        idx: u32,
        dst: [*]u8,
        len: u32,
    ) void {
        js_dropped_file_bytes(idx, dst, len);
    }
    pub fn dropped_file_name_len(idx: u32) u32 {
        return js_dropped_file_name_len(idx);
    }
    pub fn dropped_file_name(
        idx: u32,
        dst: [*]u8,
        len: u32,
    ) void {
        js_dropped_file_name(idx, dst, len);
    }
    pub fn dropped_files_clear() void {
        js_dropped_files_clear();
    }

    // ----- Gamepad haptics (Web Gamepad API)
    extern "dom" fn js_gamepad_vibrate(
        idx: i32,
        left: f32,
        right: f32,
        ms: u32,
    ) void;

    /// Trigger a dual-rumble effect on gamepad `idx`.  `left` / `right`
    /// are normalized magnitudes in [0, 1].  `ms` is the duration in
    /// milliseconds.  Silent no-op if the gamepad doesn't support haptics.
    pub fn gamepad_vibrate(
        idx: i32,
        left: f32,
        right: f32,
        ms: u32,
    ) void {
        js_gamepad_vibrate(idx, left, right, ms);
    }

    // ----- Frame loop
    extern "dom" fn js_start_loop() void;
    extern "dom" fn js_stop_loop() void;

    /// Ask the host to start calling our exported `zimr_frame` on every rAF.
    /// Idempotent - calling twice is safe; a second call replaces the
    /// pending rAF id with a new one.
    pub fn start_loop() void {
        js_start_loop();
    }

    /// Cancel the pending rAF tick.  After this `zimr_frame` will not be
    /// called again until `start_loop` is called.
    pub fn stop_loop() void {
        js_stop_loop();
    }

    // ----- Crypto / RNG
    extern "dom" fn js_crypto_random_fill(ptr: [*]u8, len: usize) void;

    /// Fill the given buffer with cryptographically-strong random bytes
    /// from the host's `crypto.getRandomValues`.  Used as the backing
    /// for `std.Io.random` / `randomSecure` on wasm.
    pub fn crypto_random_fill(ptr: [*]u8, len: usize) void {
        js_crypto_random_fill(ptr, len);
    }
};

/// Off-main-thread jobs. The transport for `src/jobs.zig`: a job is submitted, polled until it is done, and its
/// result taken.
///
/// Host (and any browser where `new Worker()` throws - a sandboxed iframe does):
/// `available()` is false, and `jobs.zig` runs the kernel INLINE instead. Nothing
/// here ever fails; the caller cannot tell the difference.
pub const jobs = struct {
    const is_wasm: bool = builtin.target.cpu.arch.isWasm();

    /// `poll` returns this while the kernel is still running.
    pub const pending: i32 = -1;

    extern "jobs" fn js_jobs_available() u32;
    extern "jobs" fn js_jobs_submit(
        name_ptr: [*]const u8,
        name_len: u32,
        header_ptr: [*]const u8,
        header_len: u32,
        payload_ptr: [*]const u8,
        payload_len: u32,
    ) u32;
    extern "jobs" fn js_jobs_poll(handle: u32) i32;
    extern "jobs" fn js_jobs_error_name(handle: u32, dst: [*]u8, cap: u32) u32;
    extern "jobs" fn js_jobs_take(handle: u32, dst: [*]u8, cap: u32) u32;
    extern "jobs" fn js_jobs_cancel(handle: u32) void;

    /// Is a real worker pool available? False on the host, and false in a browser
    /// context where Worker construction was refused.
    pub fn available() bool {
        if (comptime !is_wasm) {
            return false;
        }
        return js_jobs_available() != 0;
    }

    /// Hand `data` (header ++ payload) to the pool, to be run by the kernel called
    /// `name`. Returns a handle, or 0 if the queue is full.
    ///
    /// The kernel is named, not numbered: the worker calls the wasm export
    /// `zimr_job_<name>` directly, so there is no id to get out of step with the table
    /// and no dispatch to mis-route. Host: 0 (and `jobs.zig` never calls this, having
    /// checked `available()` first).
    /// Header and payload cross SEPARATELY, and the host joins them into the one buffer it
    /// was going to allocate anyway. The caller used to have to join them itself, which meant
    /// a multi-megabyte allocation and memcpy on every dispatch - in the frame path - for a
    /// buffer that was immediately copied again on the other side.
    /// The failed kernel's error NAME, copied into `dst`. Returns how many bytes it wrote.
    ///
    /// The worker always sent this; the host used to print it and drop it. So `KernelFailed`
    /// was every failure's only description - on a device with no console to read.
    pub fn errorName(handle: u32, dst: []u8) usize {
        if (comptime !is_wasm) {
            return 0;
        }
        return js_jobs_error_name(handle, dst.ptr, @intCast(dst.len));
    }

    pub fn submit(name: []const u8, header: []const u8, payload: []const u8) u32 {
        if (comptime !is_wasm) {
            return 0;
        }
        return js_jobs_submit(
            name.ptr,
            @intCast(name.len),
            header.ptr,
            @intCast(header.len),
            payload.ptr,
            @intCast(payload.len),
        );
    }

    /// `pending` while it runs, a byte length when done, < -1 on kernel failure.
    pub fn poll(handle: u32) i32 {
        if (comptime !is_wasm) {
            return pending;
        }
        return js_jobs_poll(handle);
    }

    /// Copy the finished result into `dst` and retire the handle.
    pub fn take(handle: u32, dst: []u8) usize {
        if (comptime !is_wasm) {
            return 0;
        }
        return js_jobs_take(handle, dst.ptr, @intCast(dst.len));
    }

    /// Give up on a job: drop any result being held for it, and discard a reply that is
    /// still in flight when it lands. Without this, abandoning an in-flight job strands
    /// its entire result buffer in the host for the life of the page.
    pub fn cancel(handle: u32) void {
        if (comptime !is_wasm) {
            return;
        }
        js_jobs_cancel(handle);
    }
};

// ============================================================================
// SECTION - fetch (was: src/fetch.zig)
// ============================================================================

pub const fetch = struct {
    const is_wasm = builtin.target.cpu.arch.isWasm();

    /// Opaque handle.  0 means "invalid".
    pub const Handle = u32;

    pub const Status = union(enum) {
        pending,
        ok: []const u8,
        failed: Error,
    };

    pub const Error = error{
        NotFound,
        NetworkFailed,
        InvalidHandle,
        NotReady,
    };

    // ---- JS-side imports
    extern "dom" fn js_fetch_start(url_ptr: [*]const u8, url_len: usize) Handle;
    extern "dom" fn js_fetch_poll(handle: Handle) i32;
    extern "dom" fn js_fetch_data_ptr(handle: Handle) [*]const u8;
    extern "dom" fn js_fetch_data_len(handle: Handle) usize;
    extern "dom" fn js_fetch_release(handle: Handle) void;

    // js_fetch_poll status codes match the Zig-side enum values:
    //   0 = pending
    //   1 = ok
    //   2 = NotFound (404 or missing)
    //   3 = NetworkFailed
    const poll_pending: i32 = 0;
    const poll_ok: i32 = 1;
    const poll_not_found: i32 = 2;
    const poll_network_failed: i32 = 3;

    // ---- Public API
    /// Begin fetching `url`.  Returns a handle to use with `poll`/`release`.
    /// `url` is a path relative to the served root (e.g. "assets/foo.png")
    /// or an absolute URL.  No bytes are read yet.
    pub fn start(url: []const u8) Handle {
        if (comptime !is_wasm) {
            return 0;
        }
        return js_fetch_start(url.ptr, url.len);
    }

    /// Check on the status of a previously-started fetch.  Returns
    /// `.pending` while the network is in flight, `.ok` once the bytes are
    /// in wasm memory, or `.failed` if the request errored.  The slice
    /// returned in `.ok` is valid until `release(handle)` is called.
    pub fn poll(handle: Handle) Status {
        if (comptime !is_wasm) {
            return .{ .failed = Error.NotReady };
        }
        if (handle == 0) {
            return .{ .failed = Error.InvalidHandle };
        }
        const code: i32 = js_fetch_poll(handle);
        return switch (code) {
            poll_pending => .pending,
            poll_ok => blk: {
                const ptr: [*]const u8 = js_fetch_data_ptr(handle);
                const len: usize = js_fetch_data_len(handle);
                break :blk .{ .ok = ptr[0..len] };
            },
            poll_not_found => .{ .failed = Error.NotFound },
            poll_network_failed => .{ .failed = Error.NetworkFailed },
            else => .{ .failed = Error.NetworkFailed },
        };
    }

    /// Release a handle.  Frees the JS-side buffer if any.  Calling
    /// `poll` after `release` is undefined.  Safe to call multiple times.
    pub fn release(handle: Handle) void {
        if (comptime !is_wasm) {
            return;
        }
        if (handle == 0) {
            return;
        }
        js_fetch_release(handle);
    }

    // NOTE: there is no synchronous "wait" function.  Single-threaded wasm
    // can't yield back to the browser event loop from inside an exported
    // function - once Zig is running, the event loop is blocked until
    // Zig returns.  Loaders must be structured as polling state machines
    // across frames.  See `examples/load_image_demo.zig` for the canonical
    // pattern.
    // For Io-aware fetch (time tracking, mockable handles), use
    // `z.io.Browser` / `z.io.Mock`'s `fetchStart` / `fetchPoll` /
    // `fetchRelease` / `fetchElapsedMs` slots instead - they wrap these
    // primitives and add per-handle elapsed-time tracking through a
    // vtable.

};

/// WebSocket client - the browser-side transport for zimr's P2P signaling. It
/// talks to the L0 signaling server (tools/signal_server.zig) so peers can find
/// each other and trade WebRTC handshake blobs. Mirrors `fetch`'s handle+poll
/// shape: nothing blocks; you open a socket, then each frame you poll for
/// inbound messages and send outbound ones. The JS host (bridge.zig) does the
/// actual async work and queues inbound frames; wasm drains the queue by polling.
///
/// Typical use (a polling state machine across frames):
///     const h = z.web.ws.open("ws://localhost:7777");
///     // ... later, every frame:
///     switch (z.web.ws.state(h)) {
///         .connecting => {},                       // wait
///         .open => {
///             var buf: [4096]u8 = undefined;
///             while (z.web.ws.poll(h, &buf)) |msg| { handle(msg); }
///             z.web.ws.send(h, "JOIN my-room");
///         },
///         .closed => { z.web.ws.close(h); },       // reconnect or give up
///     }
pub const ws = struct {
    const is_wasm = builtin.target.cpu.arch.isWasm();

    /// Opaque socket handle. 0 means "invalid / not on wasm".
    pub const Handle = u32;

    /// Connection state, matching the JS host's `st` cell.
    pub const State = enum(i32) {
        connecting = 0,
        open = 1,
        closed = 2, // closed OR errored - either way you can't use it anymore
    };

    // ---- JS-side imports (implemented in bridge.zig's "dom" namespace) ----
    extern "dom" fn js_ws_open(url_ptr: [*]const u8, url_len: usize) Handle;
    extern "dom" fn js_ws_state(handle: Handle) i32;
    extern "dom" fn js_ws_send(handle: Handle, ptr: [*]const u8, len: usize) void;
    extern "dom" fn js_ws_poll(handle: Handle, out_ptr: [*]u8, out_cap: usize) i32;
    extern "dom" fn js_ws_close(handle: Handle) void;
    extern "dom" fn js_ws_origin_url(out_ptr: [*]u8, out_cap: usize) usize;

    /// Open a WebSocket to `url` (e.g. "ws://localhost:7777" or a "wss://" URL).
    /// Returns immediately with a handle; the socket connects in the background.
    /// Poll `state()` until it reports `.open` before sending.
    pub fn open(url: []const u8) Handle {
        if (comptime !is_wasm) {
            return 0;
        }
        return js_ws_open(url.ptr, url.len);
    }

    /// Current connection state. A stale/closed/freed handle reports `.closed`.
    pub fn state(handle: Handle) State {
        if (comptime !is_wasm) {
            return .closed;
        }
        if (handle == 0) {
            return .closed;
        }
        return switch (js_ws_state(handle)) {
            0 => .connecting,
            1 => .open,
            else => .closed,
        };
    }

    /// Send `bytes` as a WebSocket text frame (the L0 server speaks text). Safe
    /// to call before the socket is open - it's dropped rather than throwing.
    pub fn send(handle: Handle, bytes: []const u8) void {
        if (comptime !is_wasm) {
            return;
        }
        if (handle == 0) {
            return;
        }
        js_ws_send(handle, bytes.ptr, bytes.len);
    }

    /// Drain the next queued inbound message into `out`. Returns the message as
    /// a slice of `out` (never longer than `out`), or null if the queue is empty
    /// right now. A message too big for `out` is dropped and null is returned, so
    /// size `out` for your largest expected message (SDP offers are a few KB).
    /// Call in a loop each frame to drain everything that arrived.
    pub fn poll(handle: Handle, out: []u8) ?[]const u8 {
        if (comptime !is_wasm) {
            return null;
        }
        if (handle == 0) {
            return null;
        }
        const n: i32 = js_ws_poll(handle, out.ptr, out.len);
        if (n < 0) {
            return null;
        }
        return out[0..@intCast(n)];
    }

    /// Close the socket and free its handle. Safe to call more than once.
    pub fn close(handle: Handle) void {
        if (comptime !is_wasm) {
            return;
        }
        if (handle == 0) {
            return;
        }
        js_ws_close(handle);
    }

    /// The same-origin WebSocket URL for the page this wasm is running in -
    /// "wss://host" on an https page, "ws://host" otherwise. Writes it into
    /// `out` and returns the slice. Handy when the signaling server also serves
    /// the page: connect to `originUrl(&buf)` and there's nothing to hard-code
    /// and no mixed-content issue. Returns "" on native builds.
    pub fn originUrl(out: []u8) []const u8 {
        if (comptime !is_wasm) {
            return "";
        }
        const n: usize = js_ws_origin_url(out.ptr, out.len);
        return out[0..n];
    }
};

/// WebRTC peer-to-peer data channels. Each `create()` makes one connection to
/// one remote peer (build a full mesh by making one per peer). The SDP/ICE
/// payloads are opaque here - you ferry them to the remote peer over whatever
/// signaling channel you have (the `ws` above, relayed by the signaling
/// server), and feed the peer's payloads back in via `setRemote` / `addIce`.
/// The whole offer/answer/ICE dance is driven by draining `poll()` each frame.
/// Two channels: 0 = "cursor" (unreliable, unordered), 1 = "clicks" (reliable).
/// All of this is a no-op on native builds (the externs are wasm-only).
pub const rtc = struct {
    pub const Handle = u32;
    const is_wasm: bool = builtin.target.cpu.arch.isWasm();

    pub const EventKind = enum(u8) {
        none = 0,
        local_offer = 1, // our SDP offer is ready - send it to the peer
        local_answer = 2, // our SDP answer is ready - send it to the peer
        local_ice = 3, // one of our ICE candidates - send it to the peer
        channel_open = 4, // a data channel opened (see event.channel)
        data = 5, // bytes arrived on a channel (see event.channel/payload)
        state = 6, // connection state changed (payload is the state text)
    };

    /// One drained event. `payload` points into the `out` buffer you passed to
    /// `poll`, so copy it out before the next `poll` call if you need to keep it.
    pub const Event = struct {
        kind: EventKind,
        channel: u8,
        payload: []const u8,
    };

    extern "dom" fn js_rtc_create() Handle;
    extern "dom" fn js_rtc_create_offer(handle: Handle) void;
    extern "dom" fn js_rtc_set_remote(
        handle: Handle,
        is_offer: u32,
        sdp_ptr: [*]const u8,
        sdp_len: usize,
    ) void;
    extern "dom" fn js_rtc_add_ice(
        handle: Handle,
        cand_ptr: [*]const u8,
        cand_len: usize,
    ) void;
    extern "dom" fn js_rtc_send(
        handle: Handle,
        channel: u32,
        ptr: [*]const u8,
        len: usize,
    ) void;
    extern "dom" fn js_rtc_poll(
        handle: Handle,
        out_ptr: [*]u8,
        out_cap: usize,
    ) i32;
    extern "dom" fn js_rtc_close(handle: Handle) void;

    /// Make a new peer connection. Returns a handle (0 on native).
    pub fn create() Handle {
        if (comptime !is_wasm) {
            return 0;
        }
        return js_rtc_create();
    }

    /// Offerer side: create the two data channels and an SDP offer. The offer
    /// arrives as a `local_offer` event from `poll`.
    pub fn createOffer(handle: Handle) void {
        if (comptime !is_wasm) {
            return;
        }
        js_rtc_create_offer(handle);
    }

    /// Feed in the remote peer's SDP. `is_offer` true means they offered and we
    /// are answering (an answer will come back as a `local_answer` event);
    /// false means this is their answer to our offer.
    pub fn setRemote(handle: Handle, is_offer: bool, sdp: []const u8) void {
        if (comptime !is_wasm) {
            return;
        }
        js_rtc_set_remote(handle, if (is_offer) 1 else 0, sdp.ptr, sdp.len);
    }

    /// Feed in one of the remote peer's ICE candidates (the JSON string that came
    /// out of their `local_ice` event).
    pub fn addIce(handle: Handle, candidate: []const u8) void {
        if (comptime !is_wasm) {
            return;
        }
        js_rtc_add_ice(handle, candidate.ptr, candidate.len);
    }

    /// Send bytes on channel 0 (cursor) or 1 (clicks). No-op if the channel
    /// isn't open yet.
    pub fn send(handle: Handle, channel: u8, bytes: []const u8) void {
        if (comptime !is_wasm) {
            return;
        }
        js_rtc_send(handle, channel, bytes.ptr, bytes.len);
    }

    /// Drain the next event, or null if none. `event.payload` is a slice of
    /// `out`, valid only until the next `poll`.
    pub fn poll(handle: Handle, out: []u8) ?Event {
        if (comptime !is_wasm) {
            return null;
        }
        const n: i32 = js_rtc_poll(handle, out.ptr, out.len);
        if (n < 2) {
            return null; // -1 empty, -2 too big, or malformed
        }
        const total: usize = @intCast(n);
        const raw: u8 = out[0];
        if (raw < 1 or raw > 6) {
            return null;
        }
        return .{ .kind = @fromBackingInt(@intCast(raw)), .channel = out[1], .payload = out[2..total] };
    }

    /// Close the connection and free its handle. Safe to call more than once.
    pub fn close(handle: Handle) void {
        if (comptime !is_wasm) {
            return;
        }
        if (handle == 0) {
            return;
        }
        js_rtc_close(handle);
    }
};

// Force discovery of nested-namespace inline tests.  Without this,
// `_ = @import("web.zig")` in tests.zig only sees file-scope tests
// (of which there are none) and skips the `audio.*` tests.

/// User-supplied files - drag-and-drop on desktop, the OS file picker on mobile.
///
/// -- WHY THIS EXISTS --
///
/// Until now nothing in zimr could read bytes the USER chose at runtime: every example gets its
/// assets through `@embedFile` at comptime. A viewer that only ever shows the one clip compiled
/// into it is not a viewer.
///
/// -- * THE WEB DROP MODEL IS ASYNC AND raylib's IS NOT --
///
/// raylib's `LoadDroppedFiles()` hands back PATHS, synchronously, and the app reads them with
/// ordinary file I/O. BVHView gets that on the web for free from
/// `-s USE_GLFW=3 -s FORCE_FILESYSTEM=1`: GLFW's emscripten port reads the dropped files into
/// MEMFS and only then fires its callback, so the C code still sees paths. The asynchrony is
/// hidden behind a virtual filesystem.
///
/// zimr has no virtual filesystem, and adding one to manufacture that illusion would be a large
/// detour for no gain. In a browser a `drop` yields `DataTransfer.files`, and each `File` must
/// be read through `arrayBuffer()`, which resolves LATER. So the asynchrony is exposed rather
/// than hidden, using the same four-step polling protocol `audio`'s OGG decode already uses:
///
///   1. bytes arrive JS-side (a drop, or the picker closing) and are queued
///   2. `pendingCount()` - poll each frame
///   3. `nextSize()` / `readNext(buf)` - take the oldest, copy it into wasm memory
///   4. `discardNext()` if the caller does not want it after all
///
/// A file lands a frame or two after the user acts, which for someone dragging a file is
/// invisible.
///
/// -- * THE PICKER NEEDS A REAL DOM ELEMENT, NOT A WASM-DRAWN BUTTON --
///
/// `input.click()` only opens the picker inside a genuine user-gesture handler. zimr's UI is
/// immediate-mode and drawn INTO the canvas, so a "Load file" button is pixels: the press is
/// detected while walking the UI during `requestAnimationFrame`, long after the `pointerdown`
/// that delivered the tap, and the browser's transient activation has expired. Desktop often
/// forgives this; mobile Safari does not.
///
/// `requestPicker` therefore positions a real, transparent `<input type="file">` over the
/// rectangle where the wasm draws its button, so the tap lands on a DOM element and the gesture
/// is real. This is the same technique `bridge.zig`'s text-input overlay already uses to pop the
/// mobile soft keyboard over a wasm-drawn text field.
///
/// The externs live in the `dom` import namespace rather than one of their own: `bridge.zig`
/// already routes persistence, clipboard, WebSocket and WebRTC through `dom`, and a new
/// namespace would have to be registered in the smoke runner's import spec as well.
pub const userfile = struct {
    const is_wasm: bool = builtin.target.cpu.arch.isWasm();

    extern "dom" fn js_userfile_pending_count() u32;
    extern "dom" fn js_userfile_next_size() u32;
    extern "dom" fn js_userfile_next_name(out_ptr: [*]u8, out_len: u32) u32;
    extern "dom" fn js_userfile_read_next(out_ptr: [*]u8, out_len: u32) u32;
    extern "dom" fn js_userfile_discard_next() void;
    extern "dom" fn js_userfile_set_picker_rect(
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        accept_ptr: [*]const u8,
        accept_len: u32,
    ) void;
    extern "dom" fn js_userfile_hide_picker() void;
    extern "dom" fn js_userfile_offer(
        ptr: [*]const u8,
        len: u32,
        name_ptr: [*]const u8,
        name_len: u32,
    ) void;
    extern "dom" fn js_userfile_set_save_rect(
        x: f32,
        y: f32,
        w: f32,
        h: f32,
    ) void;
    extern "dom" fn js_userfile_hide_save() void;

    /// How many completed files are waiting. Poll this each frame.
    pub fn pendingCount() u32 {
        if (comptime !is_wasm) {
            return 0;
        }
        return js_userfile_pending_count();
    }

    /// Byte length of the oldest waiting file, so the caller can size its buffer. 0 when the
    /// queue is empty.
    pub fn nextSize() u32 {
        if (comptime !is_wasm) {
            return 0;
        }
        return js_userfile_next_size();
    }

    /// Copy the oldest waiting file's NAME into `out`; returns the number of bytes written.
    /// The name is the basename the browser reports - there is no path on the web.
    pub fn nextName(out: []u8) u32 {
        if (comptime !is_wasm) {
            return 0;
        }
        return js_userfile_next_name(out.ptr, @intCast(out.len));
    }

    /// Copy the oldest waiting file's bytes into `out` and DROP it from the queue. Returns the
    /// number of bytes written, which is 0 when `out` is too small - in that case the file
    /// stays queued, so a caller that mis-sized its buffer can retry rather than lose the file.
    pub fn readNext(out: []u8) u32 {
        if (comptime !is_wasm) {
            return 0;
        }
        return js_userfile_read_next(out.ptr, @intCast(out.len));
    }

    /// Drop the oldest waiting file without reading it.
    pub fn discardNext() void {
        if (comptime !is_wasm) {
            return;
        }
        js_userfile_discard_next();
    }

    /// Place the invisible `<input type="file">` over `(x, y, w, h)` in CSS pixels - the
    /// rectangle where the caller draws its own Load button. `accept` is a filter such as
    /// ".bvh"; pass an empty string for any file.
    ///
    /// Call this every frame the button is visible: the canvas can be resized or scrolled, and
    /// an overlay left at a stale rectangle swallows taps meant for something else.
    pub fn setPickerRect(
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        accept: []const u8,
    ) void {
        if (comptime !is_wasm) {
            return;
        }
        js_userfile_set_picker_rect(x, y, w, h, accept.ptr, @intCast(accept.len));
    }

    // -- And the other direction: a file the page hands to the user. --
    //
    // The same gesture rule applies, the other way round: a mobile browser saves a file only from
    // inside a genuine user gesture, so a Save button drawn in wasm cannot trigger the download
    // itself - by the time the frame notices the tap, the gesture has expired. Instead the page
    // OFFERS the file ahead of time (`offerDownload`, as often as it likes; the previous file is
    // released each time), and a real, transparent `<a download>` sits over its Save button
    // (`setSaveRect`, every frame the button is shown). The tap lands on the anchor, and the file
    // it hands over is whatever was offered last.

    /// Make `bytes` the file a tap on the Save overlay downloads, named `name`. Copied at once:
    /// the caller may free or reuse `bytes` as soon as this returns.
    pub fn offerDownload(bytes: []const u8, name: []const u8) void {
        if (comptime !is_wasm) {
            return;
        }
        js_userfile_offer(bytes.ptr, @intCast(bytes.len), name.ptr, @intCast(name.len));
    }

    /// Park the Save overlay over the rectangle where the page draws its Save button.
    pub fn setSaveRect(
        x: f32,
        y: f32,
        w: f32,
        h: f32,
    ) void {
        if (comptime !is_wasm) {
            return;
        }
        js_userfile_set_save_rect(x, y, w, h);
    }

    /// Hide the Save overlay, so it stops intercepting taps once the button is gone.
    pub fn hideSave() void {
        if (comptime !is_wasm) {
            return;
        }
        js_userfile_hide_save();
    }

    /// Hide the overlay, so it stops intercepting taps once the button is gone.
    pub fn hidePicker() void {
        if (comptime !is_wasm) {
            return;
        }
        js_userfile_hide_picker();
    }

    // ---- Tests
    // Host-side coverage only: the wrappers are exercised against the `is_wasm = false` branch
    // to verify they return the documented safe defaults instead of trapping on a missing
    // import. Real browser behaviour belongs to the smoke harness.

    test "pendingCount on host reports an empty queue" {
        try expectEqual(@as(u32, 0), pendingCount());
    }

    test "nextSize and readNext on host return 0 without touching the buffer" {
        var buf: [8]u8 = @splat(0xAA);
        try expectEqual(@as(u32, 0), nextSize());
        try expectEqual(@as(u32, 0), readNext(&buf));
        try expectEqual(@as(u32, 0), nextName(&buf));
        // Untouched: a host build must not pretend it wrote anything.
        try expectEqual(@as(u8, 0xAA), buf[0]);
    }

    test "picker calls on host are silent" {
        setPickerRect(0, 0, 100, 32, ".bvh");
        hidePicker();
        discardNext();
    }
};

comptime {
    _ = fetch;
    _ = userfile;
}
