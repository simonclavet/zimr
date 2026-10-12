//! src/platform/contract.zig - the contract between the engine and a platform.
//!
//! A platform is what stands between the engine and one operating system or browser. It owns the loop - it calls the
//! engine each frame, never the other way round, as the browser, iOS and Android require - and it is the engine's only
//! way to the system: it turns the system's input into events, and carries out the engine's requests.
//!
//! The contract runs in two directions.
//!
//!   EVENTS, platform to engine. What happens - a key pressed, the window resized, focus lost, the outcome of an
//!   asynchronous request - arrives as an `Event`, in order, before the frame that sees it. The byte slices some events
//!   carry (`text`, `composition`, `paste`) are valid only while the engine handles the event; it copies what it keeps.
//!
//!   REQUESTS AND QUERIES, engine to platform. What the engine asks of the system - the time, the size, a title, a
//!   cursor, the clipboard, saved values, audio, gamepads - is a function every platform module provides, with the
//!   type `requests` gives it. State read every frame (the size, the time, the gamepads) is queried; anything a system
//!   may grant only later (pointer lock, fullscreen, the clipboard's contents) is requested, and an event reports the
//!   outcome - in the browser after a user gesture or a permission prompt, elsewhere before the next frame. One shape
//!   on every platform.
//!
//! Every platform speaks the browser's units, converting at its own edge: positions and sizes in logical (CSS) pixels,
//! with one scale - physical pixels per logical pixel, the browser's `devicePixelRatio`; keys by physical position
//! (`KeyboardKey`, the DOM's `KeyboardEvent.code`); mouse buttons in the DOM's numbering; the wheel in notches.
//!
//! A platform that cannot do something declares it, with the reason: the function exists with its contract type, and
//! its body is a `@compileError` saying why - for a function not written yet, or one the system cannot carry out. The
//! check here, `requirePlatform`, looks at names and types only, so such a refusal passes it; the build fails only
//! where the engine calls the function, with the reason as the message. What every platform lacks is then visible in
//! its own source, one function at a time.

const std = @import("std");
const types = @import("../types.zig");
const startsWith = std.mem.startsWith;
const eql = std.mem.eql;

/// A key, by its physical position: the DOM's `KeyboardEvent.code` names, the same on every keyboard layout.
pub const KeyboardKey = types.KeyboardKey;

// ---- Events ----

/// The modifier keys held, and the two lock keys' states, when an input event happened.
pub const Modifiers = packed struct(u8) {
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
    meta: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    _unused: u2 = 0,
};

/// A key going down: `repeat` when the system repeats a held key.
///
/// `key` names the key by its position, the same on every layout - what movement keys want. `label` is what the
/// key types on the current layout without modifiers, lowercased - what shortcuts want: on a French keyboard the key
/// in QWERTY's W position types z, so Ctrl+Z is that key. 0 when the key types nothing by itself (Shift, an arrow, a
/// dead key) or its platform cannot tell. SDL3 makes the same split, as scancode and keycode.
pub const KeyDown = struct {
    key: KeyboardKey,
    repeat: bool,
    label: u21 = 0,
    modifiers: Modifiers,
};

/// A key coming up.
pub const KeyUp = struct {
    key: KeyboardKey,
    modifiers: Modifiers,
};

/// Committed text while text input is on (`startTextInput`), or pasted text: UTF-8, valid only while the event is
/// handled.
pub const Text = struct {
    bytes: []const u8,
};

/// An input method's unfinished text while text input is on, and its cursor as a byte offset into it. Empty when the
/// composition ends - committed, its text then arrives as a `text` event, or abandoned.
pub const Composition = struct {
    bytes: []const u8,
    cursor: u32,
};

/// The pointer's position, and its movement since the previous move - while the pointer is locked, the movement alone
/// means anything, the position staying put.
pub const MouseMove = struct {
    x: f32,
    y: f32,
    dx: f32,
    dy: f32,
    modifiers: Modifiers,
};

/// A mouse button, in the DOM's numbering (`MouseEvent.button`): 0 the main button, usually the left; 1 the
/// auxiliary, usually the wheel; 2 the secondary, usually the right; 3 and 4 the side buttons that browsers map to
/// back and forward. Every platform reports this numbering; the engine maps it to its own once (`receiveEvent`).
/// Numbers past 4 - a pen's eraser, a mouse with more buttons - are kept as they come.
pub const Button = enum(u8) {
    left = 0,
    middle = 1,
    right = 2,
    back = 3,
    forward = 4,
    _,
};

/// A mouse button pressed or released, and where the pointer was.
pub const MouseButton = struct {
    button: Button,
    x: f32,
    y: f32,
    modifiers: Modifiers,
};

/// A wheel's turn, in notches: one per step of a stepped wheel, fractions from smooth wheels and touchpads; positive
/// away from the user and to the right.
pub const Wheel = struct {
    dx: f32,
    dy: f32,
    modifiers: Modifiers,
};

/// A touch: `id` follows one finger from its `touch_begin` to its `touch_end` or `touch_cancel`.
pub const Touch = struct {
    id: u32,
    x: f32,
    y: f32,
};

/// The device's acceleration, in meters per second squared, and the screen's rotation in degrees - the browser's
/// `devicemotion`. Only devices with the sensor send it.
pub const Motion = struct {
    ax: f32,
    ay: f32,
    az: f32,
    screen_angle: f32,
};

/// The drawing area's size in logical pixels, and the scale: physical pixels per logical pixel.
pub const Size = struct {
    width: f32,
    height: f32,
    scale: f32,
};

/// A gamepad's slot, from 0: it keeps its slot from connection to disconnection.
pub const GamepadSlot = u8;

/// Something that happened, as a platform reports it to the engine.
pub const Event = union(enum) {
    key_down: KeyDown,
    key_up: KeyUp,
    text: Text,
    composition: Composition,
    mouse_move: MouseMove,
    mouse_button_down: MouseButton,
    mouse_button_up: MouseButton,
    mouse_wheel: Wheel,
    /// The pointer entered the drawing area.
    mouse_enter,
    /// The pointer left the drawing area.
    mouse_leave,
    touch_begin: Touch,
    touch_move: Touch,
    touch_end: Touch,
    /// The system took the touch away - a gesture it recognized, an incoming call - so it neither ends nor counts.
    touch_cancel: Touch,
    motion: Motion,
    resized: Size,
    /// The app gained the keyboard's focus.
    focus_gained,
    /// The app lost the keyboard's focus. The engine releases every key and button held, whose releases it will
    /// not see.
    focus_lost,
    /// Nothing the app draws can be seen: minimized, or its tab in the background.
    hidden,
    /// The app can be seen again.
    shown,
    /// The user asked to close the app: a window's close button, or the system's own quit command. A request, not
    /// a command - the app may answer it, saving work first or asking to confirm.
    quit_requested,
    /// The outcome of `requestPointerLock`, or the end of a lock: a lock ends when focus leaves, on every platform.
    pointer_lock_changed: bool,
    /// The outcome of `requestFullscreen`, or its end.
    fullscreen_changed: bool,
    /// Text from the clipboard: the outcome of `requestPaste`, or the system's own paste command.
    paste: Text,
    gamepad_connected: GamepadSlot,
    gamepad_disconnected: GamepadSlot,
};

// ---- What requests take ----

/// The pointer's shape over the drawing area.
pub const Cursor = enum {
    default,
    text,
    pointer,
    crosshair,
    move,
    resize_horizontal,
    resize_vertical,
    resize_diagonal_down,
    resize_diagonal_up,
    not_allowed,
    wait,
    hidden,
};

/// What a text field expects, as hints: a platform uses those it can and ignores the rest. The browser uses them all,
/// as its input element's type, input mode, capitalization and correction attributes - which choose a phone's
/// keyboard; a desktop uses only `password`, which keeps the input method off.
pub const TextInputOptions = struct {
    kind: Kind = .text,
    capitalization: Capitalization = .sentences,
    autocorrect: bool = true,
    multiline: bool = false,

    pub const Kind = enum { text, name, email, username, password, number, numeric_password, url };
    pub const Capitalization = enum { none, sentences, words, letters };
};

/// Where a text field is, in logical pixels, and its caret's distance from the field's left edge: where an input
/// method puts its candidate window, and what a phone keeps clear of its keyboard.
pub const TextInputArea = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    caret_x: f32,
};

/// A WebSocket connection's state: connecting until its opening handshake ends, then open, and closed once the
/// connection ends or fails to open - and for a handle that names no socket. The values are the browser module's.
pub const SocketState = enum(i32) {
    connecting = 0,
    open = 1,
    closed = 2,
};

/// Checks, at compile time, that a platform's own enum - a socket's states, say - carries each of the contract's
/// values under the same name, so that converting between the two by number is exact.
pub fn requireSameValues(comptime PlatformEnum: type, comptime ContractEnum: type) void {
    const contract_values: std.builtin.Type.Enum = @typeInfo(ContractEnum).@"enum";
    for (contract_values.field_names, contract_values.field_values) |name, value| {
        if (@backingInt(@field(PlatformEnum, name)) != value) {
            @compileError(@typeName(PlatformEnum) ++ "." ++ name ++ " differs from " ++ @typeName(ContractEnum));
        }
    }
}

/// The area, in app pixels, where an app draws a button the platform watches: a press there opens the platform's
/// own dialog - choosing a file to load, or where to save one. In the browser such a dialog opens only from the
/// person's own press on an element of the page, so the platform places an invisible one over the button.
pub const ButtonArea = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

/// Samples per second and channels: the format the engine asks for, and the one a platform grants.
pub const AudioFormat = struct {
    sample_rate: u32,
    channels: u8,
};

/// On which thread a platform's output asks the mixer's renderer for its frames (`startAudioPull`), as the platform
/// declares it (`audio_output_kind`). Every output pulls: it asks for each block when its device needs it, so nothing
/// waits in a queue between the renderer and the speaker.
pub const AudioOutputKind = enum {
    /// On the main thread: a headless run's clock, at each frame; a page's script processor, between frames.
    pull_on_main_thread,
    /// The output asks the mixer's renderer for the frames its device needs, on the device's audio thread, as it
    /// needs them (`startAudioPull`): no queue, no margin, and a sound starts in the next block the device asks for.
    pull_on_audio_thread,
};

/// When an output asks for a block, and when that block will be heard: what the engine measures a sound's lag by.
/// Both times are on the output's clock (`audioClockMilliseconds`), the same clock a request is stamped with, so a
/// difference between them is a duration whichever thread took each.
pub const AudioRenderTiming = struct {
    /// When the output asked for the block.
    asked_at_ms: f64,
    /// When the block's first frame reaches the output - after the frames already queued in the device ahead of it,
    /// or, for an output that renders after the fact on a run's clock, when that clock passed it. Past the output lie
    /// only the driver and the speaker.
    first_frame_out_ms: f64,
};

/// What an output that pulls its frames calls for them: `render(context, samples, timing)` fills `samples` with
/// interleaved whole frames at the granted format, on whatever thread the output's device asks from, `timing` saying
/// when it asked and when the block will reach the output.
pub const AudioRenderCallback = struct {
    context: *anyopaque,
    render: *const fn (
        context: *anyopaque,
        samples: []f32,
        timing: AudioRenderTiming,
    ) void,
};

/// A gamepad's buttons by position, not label - south is A on an Xbox pad, cross on a PlayStation pad, B on a
/// Nintendo one - in the W3C standard gamepad's order.
pub const GamepadButton = enum(u5) {
    south,
    east,
    west,
    north,
    left_shoulder,
    right_shoulder,
    left_trigger,
    right_trigger,
    back,
    start,
    left_stick,
    right_stick,
    dpad_up,
    dpad_down,
    dpad_left,
    dpad_right,
    guide,
};

/// A gamepad's stick axes, each from -1 to 1, positive to the right and down.
pub const GamepadAxis = enum(u2) { left_x, left_y, right_x, right_y };

/// A gamepad's state: each button from 0 (released) to 1 (fully pressed; triggers are analog), each axis from -1 to 1.
pub const Gamepad = struct {
    buttons: std.EnumArray(GamepadButton, f32),
    axes: std.EnumArray(GamepadAxis, f32),
};

/// A gamepad's two rumble motors, each from 0 to 1 - the heavy low-frequency one and the light high-frequency one -
/// for how long.
pub const Rumble = struct {
    low: f32,
    high: f32,
    milliseconds: u32,
};

/// A monitor - a display a window can be on - as the platform reports it (`monitor`): where its top-left corner sits
/// on the desktop, and its size, in its own logical pixels (its physical pixels over its scale); its scale, physical
/// pixels per logical pixel; its refresh rate in hertz, 0 when the platform cannot tell (a page cannot); the name the
/// system gives it; and whether it is the primary one.
pub const Monitor = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    scale: f32,
    refresh_hz: f32,
    is_primary: bool,
    name_bytes: [64]u8 = undefined,
    name_len: u8 = 0,

    /// The monitor's name, as the system gives it.
    pub fn name(monitor: *const Monitor) []const u8 {
        return monitor.name_bytes[0..monitor.name_len];
    }

    /// Sets the name from UTF-8 `text`, cut at a character boundary when longer than `name_bytes`: a UTF-8
    /// continuation byte (10xxxxxx) at the cut would split a character, so the cut moves back.
    pub fn setName(monitor: *Monitor, text: []const u8) void {
        var kept: usize = @min(text.len, monitor.name_bytes.len);
        while (kept > 0 and kept < text.len and text[kept] & 0xc0 == 0x80) {
            kept -= 1;
        }
        @memcpy(monitor.name_bytes[0..kept], text[0..kept]);
        monitor.name_len = @intCast(kept);
    }
};

/// How a window is shown: where it was placed, minimized, or maximized over its monitor's work area.
pub const WindowShow = enum { normal, minimized, maximized };

/// The smallest and largest sizes a person may give the window's drawing area, in logical pixels; 0 leaves that
/// side unlimited.
pub const SizeLimits = struct {
    min_width: f32 = 0,
    min_height: f32 = 0,
    max_width: f32 = 0,
    max_height: f32 = 0,
};

/// A key's name in words, from its tag at compile time: each word capitalized, the underscores spaces, and the
/// keypad's `kp` prefix spelled out - `left_shift` is "Left Shift", `kp_7` "Keypad 7", `a` "A".
fn spelledKeyLabel(comptime tag: []const u8) []const u8 {
    comptime {
        const keypad_prefix: []const u8 = "kp_";
        const is_keypad: bool = startsWith(u8, tag, keypad_prefix);
        const words: []const u8 = if (is_keypad) tag[keypad_prefix.len..] else tag;
        var label: [words.len]u8 = undefined;
        var is_word_start: bool = true;
        for (words, 0..) |character, index| {
            if (character == '_') {
                label[index] = ' ';
                is_word_start = true;
            } else {
                label[index] = if (is_word_start) std.ascii.toUpper(character) else character;
                is_word_start = false;
            }
        }
        const spelled: [words.len]u8 = label;
        return if (is_keypad) "Keypad " ++ spelled else &spelled;
    }
}

/// The keys whose label is not their tag spelled out - symbols, digits, the menu key - by tag.
const explicit_labels = [_]struct { tag: []const u8, label: []const u8 }{
    .{ .tag = "null", .label = "" },
    .{ .tag = "kb_menu", .label = "Menu" },
    .{ .tag = "apostrophe", .label = "'" },
    .{ .tag = "comma", .label = "," },
    .{ .tag = "minus", .label = "-" },
    .{ .tag = "period", .label = "." },
    .{ .tag = "slash", .label = "/" },
    .{ .tag = "semicolon", .label = ";" },
    .{ .tag = "equal", .label = "=" },
    .{ .tag = "left_bracket", .label = "[" },
    .{ .tag = "backslash", .label = "\\" },
    .{ .tag = "right_bracket", .label = "]" },
    .{ .tag = "grave", .label = "`" },
    .{ .tag = "zero", .label = "0" },
    .{ .tag = "one", .label = "1" },
    .{ .tag = "two", .label = "2" },
    .{ .tag = "three", .label = "3" },
    .{ .tag = "four", .label = "4" },
    .{ .tag = "five", .label = "5" },
    .{ .tag = "six", .label = "6" },
    .{ .tag = "seven", .label = "7" },
    .{ .tag = "eight", .label = "8" },
    .{ .tag = "nine", .label = "9" },
};

/// A key's label from its tag, at compile time: its explicit label when it has one, or else its name spelled out.
fn keyLabelOfTag(comptime tag: []const u8) []const u8 {
    for (explicit_labels) |explicit| {
        if (eql(u8, explicit.tag, tag)) {
            return explicit.label;
        }
    }
    return spelledKeyLabel(tag);
}

/// Every key's US label, indexed by the key's value: built at compile time from the key enum's own fields - the
/// enum is open (`_`), so a `switch` cannot enumerate it - each tag given its explicit label (`explicit_labels`) or
/// spelled out (`spelledKeyLabel`).
const us_key_labels: [512][]const u8 = table: {
    @setEvalBranchQuota(200_000);
    var labels: [512][]const u8 = @splat("");
    const key_info = @typeInfo(KeyboardKey).@"enum";
    for (key_info.field_names, key_info.field_values) |tag, value| {
        if (value >= 0 and value < labels.len) {
            labels[value] = keyLabelOfTag(tag);
        }
    }
    break :table labels;
};

/// A key's label on a US keyboard - what its position is named after: the letter or digit it types there, its
/// symbol, or its name in words ("Enter", "Left Shift", "Keypad 7"); empty for `.null` and for values no key has.
/// What a platform reports when it cannot read the person's own layout (`keyName`).
pub fn usKeyLabel(key: KeyboardKey) []const u8 {
    const key_value: i32 = @backingInt(key);
    if (key_value < 0 or key_value >= us_key_labels.len) {
        return "";
    }
    return us_key_labels[@intCast(key_value)];
}

/// A key's US label (`usKeyLabel`) copied into `buffer`, as `keyName` answers: what a platform that cannot read the
/// person's layout gives. Null for no key, or a label longer than `buffer`.
pub fn usKeyName(key: KeyboardKey, buffer: []u8) ?[]const u8 {
    const label: []const u8 = usKeyLabel(key);
    const fits: bool = label.len > 0 and label.len <= buffer.len;
    if (!fits) {
        return null;
    }
    @memcpy(buffer[0..label.len], label);
    return buffer[0..label.len];
}

// ---- Requests and queries ----

/// One function every platform module provides: its name, and the exact type it must have.
pub const Request = struct {
    name: []const u8,
    signature: type,
};

/// The requests and queries, engine to platform. Each platform module declares every one as a public function of
/// this type - written, or refusing with the reason (see the top of this file).
pub const requests = [_]Request{
    // Monotonic time in nanoseconds, from an arbitrary start.
    .{ .name = "now", .signature = fn () u64 },
    // The drawing area's size and scale.
    .{ .name = "size", .signature = fn () Size },
    .{ .name = "setTitle", .signature = fn (title: []const u8) void },
    // Fullscreen on or off; `fullscreen_changed` reports the outcome.
    .{ .name = "requestFullscreen", .signature = fn (on: bool) void },
    .{ .name = "setCursor", .signature = fn (cursor: Cursor) void },
    // The pointer hidden and held, its movement still reported; `pointer_lock_changed` reports the outcome.
    .{ .name = "requestPointerLock", .signature = fn () void },
    .{ .name = "releasePointerLock", .signature = fn () void },
    // The screen kept on while the app runs, or allowed to sleep again.
    .{ .name = "keepAwake", .signature = fn (on: bool) void },
    // Text input on - `text` and `composition` events follow - for a field expecting `options`.
    .{ .name = "startTextInput", .signature = fn (options: TextInputOptions) void },
    .{ .name = "setTextInputArea", .signature = fn (area: TextInputArea) void },
    .{ .name = "stopTextInput", .signature = fn () void },
    .{ .name = "setClipboardText", .signature = fn (text: []const u8) void },
    // The clipboard's text, delivered as a `paste` event.
    .{ .name = "requestPaste", .signature = fn () void },
    .{ .name = "openUrl", .signature = fn (url: []const u8) void },
    // Saved values, kept across runs: the value under `key` read into `buffer` (null when there is none, or when it
    // does not fit), written, or removed.
    .{ .name = "loadValue", .signature = fn (key: []const u8, buffer: []u8) ?[]u8 },
    .{ .name = "saveValue", .signature = fn (key: []const u8, bytes: []const u8) void },
    .{ .name = "removeValue", .signature = fn (key: []const u8) void },
    // Files the person hands the app wait in a queue, oldest first - chosen with a Load button the app draws, whose
    // area the platform is given each frame the button shows (`setFilePickerArea`, with the names it accepts, such
    // as ".bvh"), or dropped on the window: how many wait; the oldest's size, and its name copied out (its length
    // returned); its bytes copied out and the file removed - nothing copied, and the file kept, when `out` is too
    // small; or the file removed unread. Then a file the person may save with a Save button the app draws: its
    // bytes and name, copied at once, and the button's area each frame it shows; the person chooses where it goes.
    .{ .name = "pendingFileCount", .signature = fn () u32 },
    .{ .name = "nextFileSize", .signature = fn () u32 },
    .{ .name = "nextFileName", .signature = fn (out: []u8) u32 },
    .{ .name = "readNextFile", .signature = fn (out: []u8) u32 },
    .{ .name = "discardNextFile", .signature = fn () void },
    .{ .name = "setFilePickerArea", .signature = fn (area: ButtonArea, accept: []const u8) void },
    .{ .name = "hideFilePicker", .signature = fn () void },
    .{ .name = "offerFile", .signature = fn (bytes: []const u8, name: []const u8) void },
    .{ .name = "setSaveArea", .signature = fn (area: ButtonArea) void },
    .{ .name = "hideSave", .signature = fn () void },
    // WebSocket connections, with the browser's model on every platform: opened at once, connecting in the background
    // (`socketState`); messages sent as text, dropped before the socket is open; received messages waiting in a
    // queue, the oldest copied out by `pollSocket` - dropped, and null returned, when longer than `out`; closed, the
    // handle freed. Handle 0 is no socket, and reads closed. `socketOriginUrl` is the address of the server the app
    // came from: the page's own origin in the browser; natively, the signaling server on this machine.
    // Then the wall clock: milliseconds since the Unix epoch, UTC.
    .{ .name = "openSocket", .signature = fn (url: []const u8) u32 },
    .{ .name = "socketState", .signature = fn (handle: u32) SocketState },
    .{ .name = "sendSocket", .signature = fn (handle: u32, bytes: []const u8) void },
    .{ .name = "pollSocket", .signature = fn (handle: u32, out: []u8) ?[]const u8 },
    .{ .name = "closeSocket", .signature = fn (handle: u32) void },
    .{ .name = "socketOriginUrl", .signature = fn (out: []u8) []const u8 },
    .{ .name = "epochMillis", .signature = fn () f64 },
    // The monitors: how many there are, each one's description (null past the count), and the one holding the drawing
    // area - the window's, or the page's screen.
    .{ .name = "monitorCount", .signature = fn () u32 },
    .{ .name = "monitor", .signature = fn (index: u32) ?Monitor },
    .{ .name = "currentMonitor", .signature = fn () u32 },
    // The window: minimized, maximized or back to normal - a fullscreen window does not maximize, covering its
    // monitor already; brought to the front; placed on a monitor, its drawing area's top-left corner at a position
    // from the monitor's own top-left corner, in the monitor's logical pixels - a desktop whose monitors have
    // different scales has no one logical space, so a position is given on one monitor - a fullscreen window staying
    // where it is; and its drawing area's size limits, which apply at once: a window outside new limits is resized
    // into them.
    .{ .name = "showWindow", .signature = fn (show: WindowShow) void },
    .{ .name = "focusWindow", .signature = fn () void },
    .{ .name = "setWindowPosition", .signature = fn (monitor: u32, x: f32, y: f32) void },
    .{ .name = "setWindowSizeLimits", .signature = fn (limits: SizeLimits) void },
    // A key's label in the person's current layout, as UTF-8 written into `buffer`: for a letter key, the letter it
    // types there - the key at the US Q is "A" on a French keyboard - and for the others the layout's own name for
    // them; null for no key, or a label longer than `buffer`.
    .{ .name = "keyName", .signature = fn (key: KeyboardKey, buffer: []u8) ?[]const u8 },
    // Audio output, pulled. `startAudioPull` opens the output at the format the engine asks for and returns the format
    // granted - the engine mixes in that one; an output already started starts again. From then on the output calls
    // `render_callback` for each block its device needs, on the thread the platform's `audio_output_kind` names,
    // with the block's timing (`AudioRenderTiming`); the renderer fills it with every voice playing. `stopAudio`
    // closes the output: no call to the renderer follows its return.
    .{
        .name = "startAudioPull",
        .signature = fn (wanted: AudioFormat, render_callback: AudioRenderCallback) AudioFormat,
    },
    .{ .name = "stopAudio", .signature = fn () void },
    // The clock sound is timed by, in milliseconds from any fixed start: a request to play is stamped with it, and an
    // output reports when it asked for a block and when the block will be heard on it (`AudioRenderTiming`). It is
    // read from the main thread and from a device's audio thread alike, so it is the system's monotonic clock - or a
    // headless run's own clock, which the run's frames move.
    .{ .name = "audioClockMilliseconds", .signature = fn () f64 },
    // What lies past the output, for the latency readout: how long a block's first frame, once out
    // (`AudioRenderTiming`), still takes to be heard, as far as the platform can tell - a browser's own buffers and
    // the latency it reports, a stream's latency as the system reports it; and the output's name, which says which
    // of a platform's paths is playing.
    .{ .name = "audioOutputLatencyMilliseconds", .signature = fn () f64 },
    .{ .name = "audioOutputName", .signature = fn () []const u8 },
    // The gamepad in a slot, or null when none is connected there.
    .{ .name = "gamepad", .signature = fn (slot: GamepadSlot) ?Gamepad },
    .{ .name = "setGamepadRumble", .signature = fn (slot: GamepadSlot, rumble: Rumble) void },
    .{ .name = "log", .signature = fn (level: std.log.Level, text: []const u8) void },
};

// ---- The check ----

/// Every way `Platform` breaks the contract, one line each - a function missing, or one of another type - or an empty
/// text when it keeps it. Function types compare by their parameter and return types; parameter names do not count.
pub fn problemsOf(comptime Platform: type) []const u8 {
    comptime var problems: []const u8 = "";
    inline for (requests) |request| {
        if (!@hasDecl(Platform, request.name)) {
            problems = problems ++ "  `" ++ request.name ++ "` is missing\n";
        } else {
            const Actual: type = @TypeOf(@field(Platform, request.name));
            if (Actual != request.signature) {
                const found: []const u8 = "  `" ++ request.name ++ "` is " ++ @typeName(Actual);
                problems = problems ++ found ++ "; the contract's is " ++ @typeName(request.signature) ++ "\n";
            }
        }
    }
    return problems;
}

/// Fails the build, listing every problem, unless `Platform` - a platform module - provides every request with its
/// contract type.
pub fn requirePlatform(comptime Platform: type) void {
    const problems: []const u8 = comptime problemsOf(Platform);
    if (problems.len != 0) {
        @compileError("platform " ++ @typeName(Platform) ++ " breaks the contract:\n" ++ problems);
    }
}
