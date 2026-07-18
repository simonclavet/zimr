// src/web.zig - browser bindings (DOM, Audio, fetch).
// Aggregates the four browser-binding modules into a single file with
// namespaced sub-structs:
//     web.dom    - canvas, time, frame loop, input  (extern "dom")
//     web.audio  - Web Audio sine-wave bindings    (extern "audio")
//     web.fetch  - async fetch handle protocol     (uses dom internally)
// Each section's contents are unchanged from before the merge - the
// only structural change is the `pub const X = struct { … };` wrapper.
// Callers that did `const dom = @import("web.zig").dom` now use
// `const dom = @import("web.zig").dom`.

const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const zm = @import("zm");
const float64 = zm.float64;
const clamp = zm.clamp;

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
    /// stderr instead of routing through the JS bridge — the
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
            // js_log). std.debug.print is the right call on the host — there
            // is no JS bridge — and the !isWasm gate keeps it off the wasm
            // path where the raw-stderr writer traps under ReleaseSmall.
            // lint:off debug-print: host-only stderr fallback, gated !isWasm
            std.debug.print("{s} {s}\n", .{ prefix, msg });
            return;
        }
        js_log(@intFromEnum(level), msg.ptr, msg.len);
    }

    extern "dom" fn js_panic(ptr: [*]const u8, len: usize) noreturn;

    pub fn panic(msg: []const u8) noreturn {
        if (comptime !builtin.target.cpu.arch.isWasm()) {
            @panic(msg);
        }
        js_panic(msg.ptr, msg.len);
    }

    // ----- Time
    extern "dom" fn js_now_ms() f64;
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
            // has no access to). Mirror `runtime.hostNow`: return 0 on host —
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

    // ----- Cursor / pointer-lock
    extern "dom" fn js_set_cursor_style(style: u32) void;
    extern "dom" fn js_request_pointer_lock() void;
    extern "dom" fn js_exit_pointer_lock() void;
    extern "dom" fn js_pointer_lock_active() u32;

    /// 0 = default cursor, 1 = none (hidden).
    pub fn set_cursor_style(style: u32) void {
        js_set_cursor_style(style);
    }
    pub fn request_pointer_lock() void {
        js_request_pointer_lock();
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
    /// "tel", "url", "search") — the JS bridge writes it through.
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
    // being called when the overlay isn't shown — they store the
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
    // overlay input is the editor — wasm only polls the final
    // value, never sees individual keystrokes.  The fix layers a
    // JS-side 'input' event listener that applies the same filter
    // logic to the overlay's value on every keystroke.  Wasm
    // packs the active chars_* flags into a bitmask and pushes it
    // to JS at show time.

    extern "dom" fn js_set_overlay_input_char_filters(flags: u32) void;

    pub const CHAR_FILTER_DECIMAL: u32 = 0x01;
    pub const CHAR_FILTER_HEXADECIMAL: u32 = 0x02;
    pub const CHAR_FILTER_SCIENTIFIC: u32 = 0x04;
    pub const CHAR_FILTER_UPPERCASE: u32 = 0x08;
    pub const CHAR_FILTER_NO_BLANK: u32 = 0x10;

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
    // element" abstraction — but the right factoring isn't
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

// ============================================================================
// SECTION - audio (was: src/audio.zig; expanded for audio-plan-v3)
// ============================================================================
// `web.audio` exposes the Web Audio API as a per-context-handle
// surface.  Every public fn takes a `ContextId` (a non-zero
// `u32`); 0 is the universal "invalid / no context" sentinel
// and every fn handles it silently (no panic, no stderr noise).
// This file provides the JS-bridge primitives only.  Higher-level
// types (`Wave`, `Sound`, `Music`, `AudioStream`) live in
// `src/sound.zig` (Phase 3 onward) and build on these.
// On host (non-wasm builds), every public fn returns a safe
// default (zero, 48000 Hz, 1.0, etc.) and never panics.  Real
// verification happens via the smoke harness
// (`webtests/smoke.ts`), which mocks the JS bridge.

pub const audio = struct {
    const is_wasm: bool = builtin.target.cpu.arch.isWasm();

    /// Opaque AudioContext handle.  0 means "invalid / no context".
    /// All audio fns accept this id; passing 0 or a stale id is
    /// silent (no panic, no stderr noise).
    pub const ContextId = u32;

    /// Opaque AudioBuffer handle.  Returned by `loadAudioBuffer`,
    /// passed to `playBuffer` / `unloadAudioBuffer`.  0 means
    /// "invalid / load failed".
    pub const BufferId = u32;

    /// Opaque AudioBufferSourceNode handle.  Returned by
    /// `playBuffer`; passed to `stopBuffer` / `pauseBuffer` /
    /// `resumeBuffer` / `isBufferPlaying`.  0 means "invalid
    /// / not playing".
    /// Each `playBuffer` call creates a *new* source node - Web
    /// Audio's source nodes are one-shot.  Same buffer played twice
    /// gives two distinct source ids.
    pub const SourceId = u32;

    /// Opaque async-decode handle.  Returned by `decodeOggBytes`;
    /// passed to `isDecodeReady` / `takeDecodedBuffer` /
    /// `cancelDecode`.  0 means "invalid / decode failed before it
    /// could even start".
    /// Lifecycle: created by decodeOggBytes; either consumed by
    /// takeDecodedBuffer (after isDecodeReady reports 1) or
    /// released early by cancelDecode.  Either way the id is dead
    /// after consumption.
    pub const DecodeId = u32;

    // ---- JS bridge
    extern "audio" fn js_audio_create_context() ContextId;
    extern "audio" fn js_audio_close_context(ctx_id: ContextId) void;
    extern "audio" fn js_audio_resume_context(ctx_id: ContextId) void;
    extern "audio" fn js_audio_get_sample_rate(ctx_id: ContextId) f32;
    extern "audio" fn js_audio_get_current_time(ctx_id: ContextId) f64;
    extern "audio" fn js_audio_get_master_volume(ctx_id: ContextId) f32;
    extern "audio" fn js_audio_set_master_volume(
        ctx_id: ContextId,
        v: f32,
    ) void;

    // Step 2 - PCM buffer upload / release.
    extern "audio" fn js_audio_load_buffer(
        ctx_id: ContextId,
        sample_rate: u32,
        channels: u32,
        frame_count: u32,
        data_ptr: [*]const f32,
        data_len: u32,
    ) BufferId;
    extern "audio" fn js_audio_unload_buffer(
        ctx_id: ContextId,
        buffer_id: BufferId,
    ) void;

    // Step 3 - buffer playback (one source per call).
    extern "audio" fn js_audio_play_buffer(
        ctx_id: ContextId,
        buffer_id: BufferId,
        volume: f32,
        pitch: f32,
        pan: f32,
        looping: u32,
    ) SourceId;
    extern "audio" fn js_audio_stop_buffer(
        ctx_id: ContextId,
        source_id: SourceId,
    ) void;
    extern "audio" fn js_audio_pause_buffer(
        ctx_id: ContextId,
        source_id: SourceId,
    ) void;
    extern "audio" fn js_audio_resume_buffer(
        ctx_id: ContextId,
        source_id: SourceId,
    ) void;
    extern "audio" fn js_audio_is_buffer_playing(
        ctx_id: ContextId,
        source_id: SourceId,
    ) u32;

    // Step 18 - scheduled-time playback for AudioStream gapless
    // chaining.  `when` is in AudioContext-time seconds (compare
    // with `getCurrentTime`).  Pass 0 for "asap" (same as
    // playBuffer).  Returns a SourceId same as playBuffer.
    extern "audio" fn js_audio_play_buffer_at(
        ctx_id: ContextId,
        buffer_id: BufferId,
        volume: f32,
        pitch: f32,
        pan: f32,
        when: f64,
    ) SourceId;

    // Step 36 - playback with a within-buffer start offset.  Used
    // by `music.seek` to start playback at a specific time inside
    // the buffer.  Same shape as `playBuffer` (looping included)
    // plus `offset_seconds` mapped to source.start(0, offset).
    extern "audio" fn js_audio_play_buffer_with_offset(
        ctx_id: ContextId,
        buffer_id: BufferId,
        volume: f32,
        pitch: f32,
        pan: f32,
        looping: u32,
        offset_seconds: f64,
    ) SourceId;

    // Step 8 - async OGG decode via Web Audio's `decodeAudioData`.
    // `decodeAudioData` is async and returns a Promise; on
    // single-threaded JS we can't block on it.  These primitives
    // implement a polling protocol:
    //   1. `decodeOggBytes(ctx, data, len)` → DecodeId, kicks off
    //      the Promise.  Bytes are copied JS-side immediately.
    //   2. `isDecodeReady(ctx, decode_id)` → 0/1 (poll each frame).
    //   3. `takeDecodedBuffer(ctx, decode_id)` → BufferId.  Once
    //      consumed, the decode_id is invalidated.
    //   4. `cancelDecode(ctx, decode_id)` if the caller gives up
    //      (e.g. Sound.unload before decode finished).
    extern "audio" fn js_audio_decode_ogg_bytes(
        ctx_id: ContextId,
        data_ptr: [*]const u8,
        data_len: u32,
    ) DecodeId;
    extern "audio" fn js_audio_is_decode_ready(
        ctx_id: ContextId,
        decode_id: DecodeId,
    ) u32;
    extern "audio" fn js_audio_take_decoded_buffer(
        ctx_id: ContextId,
        decode_id: DecodeId,
    ) BufferId;
    extern "audio" fn js_audio_cancel_decode(
        ctx_id: ContextId,
        decode_id: DecodeId,
    ) void;

    /// Opaque AnalyserNode handle. 0 means "invalid".
    pub const AnalyserId = u32;

    extern "audio" fn js_audio_create_analyser(
        ctx_id: ContextId,
        fft_size: u32,
    ) AnalyserId;
    extern "audio" fn js_audio_get_frequency_data(
        ctx_id: ContextId,
        analyser_id: AnalyserId,
        out_ptr: [*]u8,
        out_len: u32,
    ) u32;
    extern "audio" fn js_audio_destroy_analyser(
        ctx_id: ContextId,
        analyser_id: AnalyserId,
    ) void;

    // ---- v3 public API
    /// Create a new `AudioContext` plus its master `GainNode`.  Returns
    /// a non-zero id on success, 0 if the browser doesn't support Web
    /// Audio (very old) or context creation failed.
    /// AudioContexts in modern browsers start *suspended* - actual
    /// sound won't play until `resumeContext` is called from a
    /// user-gesture handler (click / touchend / keydown).  zimr's
    /// higher-level Sound / Music APIs handle this transparently.
    /// Host: returns 0 (no JS bridge, no real context).
    pub fn createContext() ContextId {
        if (comptime !is_wasm) {
            return 0;
        }
        return js_audio_create_context();
    }

    /// Tear down a previously-created context.  Idempotent / silent on
    /// invalid ids - safe to call even if the context is already gone.
    /// Host: silent no-op.
    pub fn closeContext(ctx_id: ContextId) void {
        if (comptime !is_wasm) {
            return;
        }
        js_audio_close_context(ctx_id);
    }

    /// Try to resume a suspended context.  Browsers reject the resume
    /// unless it's called from a user-gesture handler, but the call
    /// itself is always safe - failure is silent.
    /// Host: silent no-op.
    pub fn resumeContext(ctx_id: ContextId) void {
        if (comptime !is_wasm) {
            return;
        }
        js_audio_resume_context(ctx_id);
    }

    /// Get the context's audio device sample rate, in Hz.  Typical
    /// values: 48000 on Chrome/Firefox desktop; 44100 on iOS Safari
    /// (pinned).  Returns 0 for invalid ids.
    /// Host: returns 48000 - a plausible default so test code doesn't
    /// divide by zero on the resampler path.
    pub fn getSampleRate(ctx_id: ContextId) f32 {
        if (comptime !is_wasm) {
            return 48000.0;
        }
        return js_audio_get_sample_rate(ctx_id);
    }

    /// Get the context's current time, in seconds since context
    /// creation.  Used by AudioStream's gapless scheduling to
    /// compute the next-buffer start time.  Returns 0 for invalid
    /// ids.
    /// Host: returns 0.0.
    pub fn getCurrentTime(ctx_id: ContextId) f64 {
        if (comptime !is_wasm) {
            return 0.0;
        }
        return js_audio_get_current_time(ctx_id);
    }

    /// Get the master gain (1.0 = unity).  Returns 1.0 for invalid
    /// ids - same value a fresh context would report.
    /// Host: returns 1.0.
    pub fn getMasterVolume(ctx_id: ContextId) f32 {
        if (comptime !is_wasm) {
            return 1.0;
        }
        return js_audio_get_master_volume(ctx_id);
    }

    /// Set the master gain.  Clamped to `[0, 10]` - values above 1
    /// amplify (and risk clipping; we do not anti-clip).  Silent on
    /// invalid ids.
    /// Clamping happens on both sides (here AND in the JS bridge) so
    /// host tests can verify the Zig-side clamp without a real
    /// browser, and so a malformed JS environment can't push the gain
    /// node out of its valid range.
    /// Host: silent no-op.
    pub fn setMasterVolume(
        ctx_id: ContextId,
        volume: f32,
    ) void {
        if (comptime !is_wasm) {
            return;
        }
        const clamped: f32 = clamp(volume, 0.0, 10.0);
        js_audio_set_master_volume(ctx_id, clamped);
    }

    /// Upload interleaved-stereo `f32` PCM samples to a fresh
    /// `AudioBuffer`.  `frame_count` is the number of audio frames
    /// (one frame = one sample per channel); `data` is `frame_count *
    /// channels` floats.  Returns a non-zero `BufferId` on success, 0
    /// on failure (invalid ctx, allocation failure, channel-count out
    /// of Web Audio's [1, 32] range).
    /// The data is *copied* JS-side into the AudioBuffer's per-channel
    /// arrays (Web Audio uses planar storage; we deinterleave on the
    /// boundary).  The caller is free to drop / reuse `data` after
    /// this call returns.
    /// Channel layout:
    ///   - 1: mono (the one channel)
    ///   - 2: stereo (L/R interleaved per frame)
    ///   - >2: still planar after deinterleave; channel 0..N-1 from
    ///     each frame's interleaved samples
    /// Host: returns 0.
    pub fn loadAudioBuffer(
        ctx_id: ContextId,
        sample_rate: u32,
        channels: u32,
        frame_count: u32,
        data: []const f32,
    ) BufferId {
        if (comptime !is_wasm) {
            return 0;
        }
        return js_audio_load_buffer(
            ctx_id,
            sample_rate,
            channels,
            frame_count,
            data.ptr,
            @intCast(data.len),
        );
    }

    /// Release a previously-loaded buffer.  Idempotent / silent on
    /// invalid ids.  After this call the JS-side AudioBuffer becomes
    /// eligible for GC; any in-flight `AudioBufferSourceNode` playing
    /// from this buffer keeps its own reference and continues to
    /// completion.
    /// Host: silent no-op.
    pub fn unloadAudioBuffer(
        ctx_id: ContextId,
        buffer_id: BufferId,
    ) void {
        if (comptime !is_wasm) {
            return;
        }
        js_audio_unload_buffer(ctx_id, buffer_id);
    }

    /// Start playing `buffer_id` through a fresh source-graph.  The
    /// graph is `AudioBufferSourceNode → GainNode → StereoPannerNode
    /// → masterGain`, with `volume`/`pitch`/`pan` set on the per-play
    /// nodes.  Returns a non-zero `SourceId` for use with
    /// `stopBuffer` / `pauseBuffer` / `isBufferPlaying`, or 0 if the
    /// buffer or context is invalid.
    /// Parameters:
    ///   - `volume`: linear gain in `[0, 10]`, clamped here AND
    ///     JS-side.  Typical range is `[0, 1]` (1 = the buffer's
    ///     recorded amplitude); values above 1 amplify and risk
    ///     clipping.
    ///   - `pitch`: playback-rate multiplier; 1.0 = native, 2.0 = an
    ///     octave up + double speed, 0.5 = an octave down + half
    ///     speed.  Clamped to `[0.0625, 16.0]` matching Web Audio's
    ///     valid `playbackRate` range.
    ///   - `pan`: stereo balance in `[-1, 1]`; -1 = hard left, 0 =
    ///     center, +1 = hard right.  Clamped here.
    ///   - `looping`: 1 = loop forever (until explicit `stopBuffer`),
    ///     0 = play once and finish.  AudioBufferSourceNodes that
    ///     finish naturally drop their source-id from the table on
    ///     the JS side; subsequent `isBufferPlaying` reports false.
    /// `playBuffer` is the per-play entrypoint.  Even the same buffer
    /// played twice in quick succession produces TWO distinct source
    /// ids (Web Audio's nodes are one-shot).  This is also why
    /// raylib's `LoadSoundAlias` is degenerate on the web - every
    /// play is implicitly an alias.
    /// Host: returns 0.
    pub fn playBuffer(
        ctx_id: ContextId,
        buffer_id: BufferId,
        volume: f32,
        pitch: f32,
        pan: f32,
        looping: bool,
    ) SourceId {
        if (comptime !is_wasm) {
            return 0;
        }
        const v: f32 = clamp(volume, 0.0, 10.0);
        const p: f32 = clamp(pitch, 0.0625, 16.0);
        const pn: f32 = clamp(pan, -1.0, 1.0);
        const lp: u32 = if (looping) 1 else 0;
        return js_audio_play_buffer(ctx_id, buffer_id, v, p, pn, lp);
    }

    /// Stop a playing source.  Disconnects the graph and releases the
    /// source id.  Idempotent / silent on invalid ids - including
    /// sources that have already finished naturally.
    /// Host: silent no-op.
    pub fn stopBuffer(
        ctx_id: ContextId,
        source_id: SourceId,
    ) void {
        if (comptime !is_wasm) {
            return;
        }
        js_audio_stop_buffer(ctx_id, source_id);
    }

    /// Pause a playing source, capturing its current offset so
    /// `resumeBuffer` can restart at the same position.  Web Audio
    /// has no native pause on `AudioBufferSourceNode`, so we
    /// disconnect the source and remember `(currentTime - start_time)
    /// * playbackRate` as the resume offset.  Loses any in-flight
    /// `playbackRate` automation; for game audio this is fine.
    /// Idempotent / silent on already-paused or invalid ids.
    /// Host: silent no-op.
    pub fn pauseBuffer(
        ctx_id: ContextId,
        source_id: SourceId,
    ) void {
        if (comptime !is_wasm) {
            return;
        }
        js_audio_pause_buffer(ctx_id, source_id);
    }

    /// Resume a previously-paused source.  Builds a fresh source
    /// node starting at the captured offset.  The resumed source
    /// keeps the same `SourceId` from the caller's perspective
    /// (the JS bridge swaps the underlying node atomically).
    /// Idempotent / silent on never-paused or invalid ids.
    /// Host: silent no-op.
    pub fn resumeBuffer(
        ctx_id: ContextId,
        source_id: SourceId,
    ) void {
        if (comptime !is_wasm) {
            return;
        }
        js_audio_resume_buffer(ctx_id, source_id);
    }

    /// Check whether a source is currently playing (not stopped, not
    /// paused, not naturally finished).  Returns false for invalid
    /// ids.
    /// Host: returns false.
    pub fn isBufferPlaying(
        ctx_id: ContextId,
        source_id: SourceId,
    ) bool {
        if (comptime !is_wasm) {
            return false;
        }
        return js_audio_is_buffer_playing(ctx_id, source_id) != 0;
    }

    /// Schedule a buffer to start playing at AudioContext-time
    /// `when` (in seconds; compare with `getCurrentTime`).  This
    /// is the gapless-scheduling primitive for `AudioStream`.
    /// Pass `when = 0` for "as soon as possible" (matches
    /// `playBuffer`).  For gapless chaining: track the wall-clock
    /// of the previous chunk's end (`getCurrentTime + duration`)
    /// and pass that here as the next chunk's start.  The browser
    /// schedules the next source's start sample-accurately, which
    /// is what makes this gapless (vs scheduling at `currentTime`
    /// which has interrupt latency).
    /// `looping` is intentionally absent - looped streams are a
    /// design smell on the gapless-scheduling path; use
    /// `playBuffer` for one-off looping playback.
    /// Returns 0 for invalid ids or scheduling failure.
    /// Host: returns 0.
    pub fn playBufferAt(
        ctx_id: ContextId,
        buffer_id: BufferId,
        volume: f32,
        pitch: f32,
        pan: f32,
        when: f64,
    ) SourceId {
        if (comptime !is_wasm) {
            return 0;
        }
        const v: f32 = clamp(volume, 0.0, 10.0);
        const p: f32 = clamp(pitch, 0.0625, 16.0);
        const pn: f32 = clamp(pan, -1.0, 1.0);
        return js_audio_play_buffer_at(ctx_id, buffer_id, v, p, pn, when);
    }

    /// Same as `playBuffer` but starts playback `offset_seconds`
    /// into the buffer instead of from the beginning.  Used by
    /// `music.seek` to implement seeking.  `offset_seconds` is
    /// clamped to `[0, buffer_duration]` JS-side; passing a
    /// negative or out-of-range offset gets clamped, not rejected.
    /// Returns 0 for invalid ids.  Host: returns 0.
    pub fn playBufferWithOffset(
        ctx_id: ContextId,
        buffer_id: BufferId,
        volume: f32,
        pitch: f32,
        pan: f32,
        looping: bool,
        offset_seconds: f64,
    ) SourceId {
        if (comptime !is_wasm) {
            return 0;
        }
        const v: f32 = clamp(volume, 0.0, 10.0);
        const p: f32 = clamp(pitch, 0.0625, 16.0);
        const pn: f32 = clamp(pan, -1.0, 1.0);
        const lp: u32 = if (looping) 1 else 0;
        return js_audio_play_buffer_with_offset(
            ctx_id,
            buffer_id,
            v,
            p,
            pn,
            lp,
            offset_seconds,
        );
    }

    /// Begin async-decoding OGG-encoded bytes via Web Audio's
    /// `decodeAudioData`.  Bytes are copied JS-side; `data` is
    /// safe to drop after this call returns.  Returns a non-zero
    /// `DecodeId` on success; 0 if the AudioContext is gone.
    /// The caller polls with `isDecodeReady`; once ready, it calls
    /// `takeDecodedBuffer` to get a `BufferId` for playback.  If
    /// the caller gives up (decode taking too long, parent Sound
    /// unloaded), call `cancelDecode` to release the entry.
    /// `decodeAudioData` automatically resamples to the
    /// AudioContext's sample rate, so the returned BufferId is
    /// already at native rate - no client-side resample needed.
    /// Host: returns 0.
    pub fn decodeOggBytes(
        ctx_id: ContextId,
        data: []const u8,
    ) DecodeId {
        if (comptime !is_wasm) {
            return 0;
        }
        return js_audio_decode_ogg_bytes(ctx_id, data.ptr, @intCast(data.len));
    }

    /// Poll whether an async decode has completed.  Returns true
    /// once the Promise has resolved (or rejected - check via
    /// `takeDecodedBuffer` returning 0).  Returns false for
    /// invalid ids and for in-flight decodes.
    /// Host: returns false.
    pub fn isDecodeReady(
        ctx_id: ContextId,
        decode_id: DecodeId,
    ) bool {
        if (comptime !is_wasm) {
            return false;
        }
        return js_audio_is_decode_ready(ctx_id, decode_id) != 0;
    }

    /// Consume a completed decode, transferring ownership of the
    /// resulting `AudioBuffer` to a `BufferId` usable with
    /// `playBuffer` / `unloadAudioBuffer`.  After this call the
    /// `decode_id` is dead - calling it again returns 0.
    /// Returns 0 if: decode hasn't completed yet (caller polled
    /// wrong); decode failed (rejected Promise); decode_id is
    /// invalid.  In all error cases the JS-side state is cleaned
    /// up.
    /// Host: returns 0.
    pub fn takeDecodedBuffer(
        ctx_id: ContextId,
        decode_id: DecodeId,
    ) BufferId {
        if (comptime !is_wasm) {
            return 0;
        }
        return js_audio_take_decoded_buffer(ctx_id, decode_id);
    }

    /// Release an in-flight or completed decode without consuming
    /// the BufferId.  Idempotent / silent on invalid ids.  Use this
    /// when the caller gives up on a decode (e.g. owning Sound
    /// unloaded before the Promise resolved).
    /// Host: silent no-op.
    pub fn cancelDecode(
        ctx_id: ContextId,
        decode_id: DecodeId,
    ) void {
        if (comptime !is_wasm) {
            return;
        }
        js_audio_cancel_decode(ctx_id, decode_id);
    }

    /// Attach an AnalyserNode to the master bus and return its id (0 on failure).
    ///
    /// The analyser is a TAP: master already feeds `destination`, and connecting it
    /// additionally to the analyser hands the same signal to the FFT without
    /// altering what you hear. `fft_size` must be a power of two in [32, 32768];
    /// the number of usable frequency bins is HALF of it.
    /// Host: returns 0 (no JS bridge).
    pub fn createAnalyser(ctx_id: ContextId, fft_size: u32) AnalyserId {
        if (comptime !is_wasm) {
            return 0;
        }
        return js_audio_create_analyser(ctx_id, fft_size);
    }

    /// Fill `out` with the current magnitude spectrum (one byte per bin, 0..255)
    /// and return how many bins were written — which may be fewer than `out.len`
    /// if the analyser has fewer bins. Web Audio writes STRAIGHT into the wasm
    /// heap here, so there is no intermediate copy.
    /// Host: writes nothing, returns 0.
    pub fn getFrequencyData(ctx_id: ContextId, analyser_id: AnalyserId, out: []u8) u32 {
        if (comptime !is_wasm) {
            return 0;
        }
        return js_audio_get_frequency_data(ctx_id, analyser_id, out.ptr, @intCast(out.len));
    }

    /// Detach and drop an analyser.
    pub fn destroyAnalyser(ctx_id: ContextId, analyser_id: AnalyserId) void {
        if (comptime !is_wasm) {
            return;
        }
        js_audio_destroy_analyser(ctx_id, analyser_id);
    }

    // ---- Tests
    // Host-side sanity coverage only.  The Zig wrappers can be
    // exercised against the `is_wasm = false` branch to verify they
    // don't panic and return the documented safe defaults.  Real
    // browser-side behaviour is covered by the smoke harness's
    // mocked AudioContext.

    test "createContext on host returns 0 (no JS bridge)" {
        const id: ContextId = createContext();
        try expectEqual(@as(ContextId, 0), id);
    }

    test "closeContext on host is silent for any id" {
        closeContext(0);
        closeContext(1);
        closeContext(99999);
    }

    test "resumeContext on host is silent for any id" {
        resumeContext(0);
        resumeContext(1);
        resumeContext(99999);
    }

    test "getSampleRate on host returns the safe default 48000" {
        const sr: f32 = getSampleRate(0);
        try expect(sr > 0.0);
        try expectEqual(@as(f32, 48000.0), sr);
    }

    test "getCurrentTime on host returns 0.0" {
        const t: f64 = getCurrentTime(0);
        try expectEqual(@as(f64, 0.0), t);
    }

    test "getMasterVolume on host returns unity (1.0)" {
        const v: f32 = getMasterVolume(0);
        try expectEqual(@as(f32, 1.0), v);
    }

    test "setMasterVolume on host is silent for any input" {
        // No assertions on output (host has no real gain node).
        // The contract is that the call doesn't panic, regardless
        // of the input - including negatives, NaN, +inf, and
        // values past the clamp ceiling.
        setMasterVolume(0, 0.5);
        setMasterVolume(0, 0.0);
        setMasterVolume(0, 1.0);
        setMasterVolume(0, -1.0);
        setMasterVolume(0, 100.0);
        setMasterVolume(1, 1.5);
        setMasterVolume(99999, 2.5);
    }

    test "loadAudioBuffer on host returns 0 for any input" {
        const samples: []const f32 = &.{ 0.0, 0.5, -0.5, 1.0 };
        const id1: BufferId = loadAudioBuffer(0, 48000, 2, 2, samples);
        try expectEqual(@as(BufferId, 0), id1);

        // Empty data is also fine (host).
        const empty: []const f32 = &.{};
        const id2: BufferId = loadAudioBuffer(1, 44100, 1, 0, empty);
        try expectEqual(@as(BufferId, 0), id2);
    }

    test "unloadAudioBuffer on host is silent for any id" {
        unloadAudioBuffer(0, 0);
        unloadAudioBuffer(1, 1);
        unloadAudioBuffer(99999, 99999);
    }

    test "playBuffer on host returns 0 for any input" {
        const id1: SourceId = playBuffer(0, 0, 1.0, 1.0, 0.0, false);
        try expectEqual(@as(SourceId, 0), id1);

        // Edge cases: clamped inputs (extreme volume, negative pitch,
        // hard pan) - all must return 0 without panicking.
        const id2: SourceId = playBuffer(1, 1, -5.0, -10.0, -2.0, true);
        try expectEqual(@as(SourceId, 0), id2);

        const id3: SourceId = playBuffer(1, 1, 100.0, 100.0, 5.0, true);
        try expectEqual(@as(SourceId, 0), id3);
    }

    test "stopBuffer / pauseBuffer / resumeBuffer on host are silent" {
        stopBuffer(0, 0);
        stopBuffer(1, 1);
        pauseBuffer(0, 0);
        pauseBuffer(1, 1);
        resumeBuffer(0, 0);
        resumeBuffer(1, 1);
    }

    test "isBufferPlaying on host returns false for any id" {
        try expect(!isBufferPlaying(0, 0));
        try expect(!isBufferPlaying(1, 1));
        try expect(!isBufferPlaying(99999, 99999));
    }

    test "playBufferAt on host returns 0 for any input" {
        try expectEqual(@as(SourceId, 0), playBufferAt(0, 0, 1.0, 1.0, 0.0, 0.0));
        try expectEqual(@as(SourceId, 0), playBufferAt(1, 1, 1.0, 1.0, 0.0, 1.5));
        // Clamped inputs must also return 0 without panicking.
        try expectEqual(@as(SourceId, 0), playBufferAt(1, 1, -10.0, -10.0, 5.0, 0.0));
    }

    test "playBufferWithOffset on host returns 0 for any input" {
        try expectEqual(
            @as(SourceId, 0),
            playBufferWithOffset(0, 0, 1.0, 1.0, 0.0, false, 0.0),
        );
        try expectEqual(
            @as(SourceId, 0),
            playBufferWithOffset(1, 1, 1.0, 1.0, 0.0, true, 5.5),
        );
        // Negative + huge offsets must not panic - JS side clamps.
        try expectEqual(
            @as(SourceId, 0),
            playBufferWithOffset(1, 1, 1.0, 1.0, 0.0, true, -100.0),
        );
    }

    test "decodeOggBytes on host returns 0 for any input" {
        const bytes: []const u8 = "OggS\x00\x02";
        try expectEqual(@as(DecodeId, 0), decodeOggBytes(0, bytes));
        try expectEqual(@as(DecodeId, 0), decodeOggBytes(1, bytes));
    }

    test "isDecodeReady on host returns false" {
        try expect(!isDecodeReady(0, 0));
        try expect(!isDecodeReady(1, 1));
    }

    test "takeDecodedBuffer on host returns 0" {
        try expectEqual(@as(BufferId, 0), takeDecodedBuffer(0, 0));
        try expectEqual(@as(BufferId, 0), takeDecodedBuffer(1, 1));
    }

    test "cancelDecode on host is silent for any id" {
        cancelDecode(0, 0);
        cancelDecode(1, 1);
        cancelDecode(99999, 99999);
    }
};

/// Off-main-thread jobs. The transport for `src/jobs.zig`.
///
/// Deliberately the SAME shape as `web.audio`'s async decode
/// (`decodeOggBytes` -> `isDecodeReady` -> `takeDecodedBuffer`): submit, poll, take.
/// A worker pool is a new BACKEND for an idiom the engine already has, not a new idea.
///
/// Host (and any browser where `new Worker()` throws — a sandboxed iframe does):
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
    /// a multi-megabyte allocation and memcpy on every dispatch — in the frame path — for a
    /// buffer that was immediately copied again on the other side.
    /// The failed kernel's error NAME, copied into `dst`. Returns how many bytes it wrote.
    ///
    /// The worker always sent this; the host used to print it and drop it. So `KernelFailed`
    /// was every failure's only description — on a device with no console to read.
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
    const POLL_PENDING: i32 = 0;
    const POLL_OK: i32 = 1;
    const POLL_NOT_FOUND: i32 = 2;
    const POLL_NETWORK_FAILED: i32 = 3;

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
            POLL_PENDING => .pending,
            POLL_OK => blk: {
                const ptr: [*]const u8 = js_fetch_data_ptr(handle);
                const len: usize = js_fetch_data_len(handle);
                break :blk .{ .ok = ptr[0..len] };
            },
            POLL_NOT_FOUND => .{ .failed = Error.NotFound },
            POLL_NETWORK_FAILED => .{ .failed = Error.NetworkFailed },
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

// Force discovery of nested-namespace inline tests.  Without this,
// `_ = @import("web.zig")` in tests.zig only sees file-scope tests
// (of which there are none) and skips the `audio.*` tests.
comptime {
    _ = audio;
    _ = fetch;
}
