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
const zm = @import("zm");
const clamp = zm.clamp;
const assert = zm.assert;
const cache_line = std.atomic.cache_line;
const types = @import("../types.zig");
const expect = std.testing.expect;
const startsWith = std.mem.startsWith;
const eql = std.mem.eql;
const expectEqualSlices = std.testing.expectEqualSlices;

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

/// How a platform's output gets its frames, as the platform declares it (`audio_output_kind`).
pub const AudioOutputKind = enum {
    /// The mixer renders ahead, on the main thread, and queues blocks that the device plays (`startAudio`,
    /// `queueAudio`, `queuedAudioFrames`, `mixIntoQueuedAudio`): it keeps a margin queued, and a sound waits for the
    /// frame that starts it.
    push,
    /// The output asks the mixer's renderer for the frames it needs (`startAudioPull`), on the main thread: a run's
    /// clock, at each frame - the headless output.
    pull_on_main_thread,
    /// The output asks the mixer's renderer for the frames its device needs, on the device's audio thread, as it
    /// needs them (`startAudioPull`): no queue, no margin, and a sound starts in the next block the device asks for.
    pull_on_audio_thread,
};

/// What an output that pulls its frames calls for them: `render(context, samples)` fills `samples` with interleaved
/// whole frames at the granted format, on whatever thread the output's device asks from.
pub const AudioRenderCallback = struct {
    context: *anyopaque,
    render: *const fn (context: *anyopaque, samples: []f32) void,
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
    // Audio output, pushed. The engine mixes on the main thread, a frame's worth at a time, and the platform plays what
    // it is given on its own clock. `startAudio` opens the output at the format the engine asks for and returns the
    // format granted - the engine mixes in that one; output that was already started starts again, its queue emptied.
    // `queueAudio` appends samples, interleaved, one per channel per frame, whole frames only; before `startAudio` or
    // after `stopAudio` they are dropped. `queuedAudioFrames` is how many frames have been queued and not yet played -
    // what the engine tops up to its margin each frame. When the queue runs dry, the output plays silence (an
    // underrun) and goes on: a frame queued late plays late, never in place of the silence. `stopAudio` closes the
    // output, dropping what was queued. `mixIntoQueuedAudio` adds samples onto frames already queued, aligned to the
    // queue's end - its last frame onto the queue's last - each sum held to -1..1; the part that would land on frames
    // already played, or too close to playing for the output to change, is dropped. Mixing is addition, so a sound
    // started this frame can begin inside the queue rather than after it.
    .{ .name = "startAudio", .signature = fn (wanted: AudioFormat) AudioFormat },
    .{ .name = "queueAudio", .signature = fn (samples: []const f32) void },
    .{ .name = "queuedAudioFrames", .signature = fn () u32 },
    .{ .name = "mixIntoQueuedAudio", .signature = fn (samples: []const f32) void },
    .{ .name = "stopAudio", .signature = fn () void },
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

// ---- The audio ring: between the mixer's thread and a device's ----

/// A single-producer, single-consumer ring of interleaved samples between two threads: the main thread, where the
/// mixer queues each frame's block (`write`) and mixes new sounds into what is queued (`mixInto`), and a device's audio
/// thread, which takes frames as the device asks for them (`read`). Every native output keeps one.
///
/// The ring holds `capacity_frames` frames - a power of two - in `samples`. Each side's place is a counter of frames
/// since the start, not a position in the ring: `written_frames`, moved only by the main thread, and `read_frames`,
/// moved only by the audio thread. Their difference is the frames waiting, and a counter's position in the ring is its
/// value modulo the capacity - a mask, the capacity being a power of two. 64 bits never wrap: at 48 000 frames a second
/// they would last twelve million years. A side publishes its counter with a release store after touching the
/// samples, and reads the other side's with an acquire load before touching them, so it sees every sample the other
/// wrote before moving its counter: no lock, and neither side ever waits for the other.
///
///     samples:   [ . . R # # # # # W . . . . . . . ]     # waiting, R = read_frames, W = written_frames (mod 16)
///     main thread:   writes at W, then stores W (release)        audio thread: loads W (acquire), reads from R,
///     waiting = W - R          room = capacity - waiting                       then stores R (release)
///
/// Each side's state sits on a cache line of its own (`WriterSide`, `ReaderSide`), as in Erik Rigtorp's queue. A
/// processor core keeps a line it writes in its own cache; were both counters on one line, each write of either would
/// take the line from the other core, which would fetch it back to read its own counter - though neither touched the
/// other's - a cost called false sharing. And each side keeps the other's counter as it last loaded it, loading the
/// real one only when that copy says the ring is too full (for the writer) or holds too few frames (for the reader).
/// A copy can only lag the real counter, and a lagging copy only understates the room or the frames waiting, so it is
/// always safe; and most calls then touch no line the other core writes. Each copy sits with its owner's counter, on
/// the line only its owner writes.
///
///     cache line of the main thread:   written_frames, read_frames_seen
///     cache line of the audio thread:  read_frames, written_frames_seen, underrun_count
///
/// One overlap remains: `mixInto` changes frames already written, which the audio thread may be reading meanwhile.
/// Those samples are loaded and stored atomically - relaxed, which costs nothing more than a plain access on the
/// targets the engine runs on, so that a sample is read whole, old or new - and `mixInto` leaves alone the frames
/// within `guard_frames` of the read position, which the audio thread may be about to take.
pub const AudioRing = struct {
    /// Set once by `init`, then only read, by both threads.
    samples: []f32,
    capacity_frames: u32,
    channel_count: u8,
    /// The main thread's cache line.
    writer: WriterSide align(cache_line) = .{},
    /// The audio thread's cache line. The ring's alignment rounds its size up to a whole number of lines, so nothing
    /// after the ring shares this one.
    reader: ReaderSide align(cache_line) = .{},

    const WriterSide = struct {
        /// Frames written since the start: stored by the main thread, loaded by the audio thread.
        written_frames: std.atomic.Value(u64) = .{ .raw = 0 },
        /// `read_frames` as the main thread last loaded it, never ahead of the real one. Main thread only.
        read_frames_seen: u64 = 0,
    };

    const ReaderSide = struct {
        /// Frames read since the start: stored by the audio thread, loaded by the main thread.
        read_frames: std.atomic.Value(u64) = .{ .raw = 0 },
        /// `written_frames` as the audio thread last loaded it, never ahead of the real one. Audio thread only.
        written_frames_seen: u64 = 0,
        /// How often `read` found fewer frames waiting than it was asked for, once anything had been written, and gave
        /// silence for the rest. Stored by the audio thread, loaded by any (`underrunCount`).
        underrun_count: std.atomic.Value(u32) = .{ .raw = 0 },
    };

    /// Some frames as they lie in `samples`, in one piece: the index of the first sample, and how many samples.
    const SampleRun = struct {
        first_sample: usize,
        sample_count: usize,
    };

    comptime {
        const line_distance: usize = @offsetOf(AudioRing, "reader") - @offsetOf(AudioRing, "writer");
        if (line_distance < cache_line) {
            @compileError("the audio ring's two sides share a cache line");
        }
    }

    /// A ring over `samples`, which holds `capacity_frames` frames - a power of two - of `channel_count` samples each.
    pub fn init(samples: []f32, capacity_frames: u32, channel_count: u8) AudioRing {
        // A power of two has one bit set: clearing its lowest set bit leaves nothing.
        const is_power_of_two: bool = capacity_frames != 0 and (capacity_frames & (capacity_frames - 1)) == 0;
        assert(is_power_of_two, @src());
        assert(samples.len == @as(usize, capacity_frames) * channel_count, @src());
        return .{ .samples = samples, .capacity_frames = capacity_frames, .channel_count = channel_count };
    }

    /// The `frame_count` frames from frame `first_frame` on, as they lie in `samples`: one run, or two when they pass
    /// the ring's end - the second starting at its beginning (with no samples when there is no second).
    fn runsOf(ring: *const AudioRing, first_frame: u64, frame_count: u64) [2]SampleRun {
        const frame_mask: u64 = ring.capacity_frames - 1;
        const first_slot: u64 = first_frame & frame_mask;
        const frames_before_end: u64 = ring.capacity_frames - first_slot;
        const first_run_frames: u64 = @min(frame_count, frames_before_end);
        const second_run_frames: u64 = frame_count - first_run_frames;
        const channel_count: u64 = ring.channel_count;
        const first_run: SampleRun = .{
            .first_sample = @intCast(first_slot * channel_count),
            .sample_count = @intCast(first_run_frames * channel_count),
        };
        const second_run: SampleRun = .{
            .first_sample = 0,
            .sample_count = @intCast(second_run_frames * channel_count),
        };
        return .{ first_run, second_run };
    }

    /// Frames written and not yet read. Main thread.
    pub fn queuedFrames(ring: *const AudioRing) u32 {
        const written: u64 = ring.writer.written_frames.load(.monotonic);
        const read_so_far: u64 = ring.reader.read_frames.load(.acquire);
        return @intCast(written - read_so_far);
    }

    /// How often the audio thread found the ring dry since the start.
    pub fn underrunCount(ring: *const AudioRing) u32 {
        return ring.reader.underrun_count.load(.monotonic);
    }

    /// Appends the whole frames of `samples` that fit; returns how many frames it wrote. The room is first judged by
    /// the reader's counter as last seen; only if that shows too little is the real one loaded. The slots written hold
    /// frames the audio thread has already read - the room ensures it - so plain copies suffice, in at most two runs,
    /// and the release store of the counter then makes them visible together. Main thread.
    pub fn write(ring: *AudioRing, samples: []const f32) usize {
        const written: u64 = ring.writer.written_frames.load(.monotonic);
        const offered_frames: u64 = samples.len / ring.channel_count;
        var room_frames: u64 = ring.capacity_frames - (written - ring.writer.read_frames_seen);
        if (room_frames < offered_frames) {
            ring.writer.read_frames_seen = ring.reader.read_frames.load(.acquire);
            room_frames = ring.capacity_frames - (written - ring.writer.read_frames_seen);
        }
        const frames_to_write: u64 = @min(offered_frames, room_frames);
        const runs: [2]SampleRun = ring.runsOf(written, frames_to_write);
        var source_sample: usize = 0;
        for (runs) |run| {
            const destination: []f32 = ring.samples[run.first_sample..][0..run.sample_count];
            @memcpy(destination, samples[source_sample..][0..run.sample_count]);
            source_sample += run.sample_count;
        }
        ring.writer.written_frames.store(written + frames_to_write, .release);
        return @intCast(frames_to_write);
    }

    /// Adds `samples` onto the frames waiting, aligned to their end - the last frame of `samples` onto the last frame
    /// written, and back from there - each sum held to -1..1. Frames within `guard_frames` of the read position, which
    /// the audio thread may be about to take, and frames before it, are left alone: what would land there is dropped.
    /// The read position must be the real one here, so its counter is loaded every time. Main thread.
    pub fn mixInto(ring: *AudioRing, samples: []const f32, guard_frames: u32) void {
        const written: u64 = ring.writer.written_frames.load(.monotonic);
        const read_so_far: u64 = ring.reader.read_frames.load(.acquire);
        ring.writer.read_frames_seen = read_so_far;
        const first_changeable_frame: u64 = @min(read_so_far + guard_frames, written);
        const changeable_frames: u64 = written - first_changeable_frame;
        const offered_frames: u64 = samples.len / ring.channel_count;
        const frames_to_add: u64 = @min(offered_frames, changeable_frames);
        const runs: [2]SampleRun = ring.runsOf(written - frames_to_add, frames_to_add);
        var source_sample: usize = @intCast((offered_frames - frames_to_add) * ring.channel_count);
        for (runs) |run| {
            for (ring.samples[run.first_sample..][0..run.sample_count]) |*queued_sample| {
                const queued_value: f32 = @atomicLoad(f32, queued_sample, .monotonic);
                const held_sum: f32 = clamp(queued_value + samples[source_sample], -1, 1);
                @atomicStore(f32, queued_sample, held_sum, .monotonic);
                source_sample += 1;
            }
        }
    }

    /// Copies waiting frames into `destination` (interleaved, whole frames), then silence for whatever it lacks - an
    /// underrun, counted once anything was ever written: a device that opens before the first block is not running
    /// dry. The frames waiting are first judged by the writer's counter as last seen; only if that shows too few is
    /// the real one loaded. Each sample is loaded atomically, `mixInto` possibly changing it meanwhile. Returns how
    /// many frames it took. Audio thread.
    pub fn read(ring: *AudioRing, destination: []f32) usize {
        const read_so_far: u64 = ring.reader.read_frames.load(.monotonic);
        const wanted_frames: u64 = destination.len / ring.channel_count;
        var waiting_frames: u64 = ring.reader.written_frames_seen - read_so_far;
        if (waiting_frames < wanted_frames) {
            ring.reader.written_frames_seen = ring.writer.written_frames.load(.acquire);
            waiting_frames = ring.reader.written_frames_seen - read_so_far;
        }
        const frames_to_read: u64 = @min(waiting_frames, wanted_frames);
        const runs: [2]SampleRun = ring.runsOf(read_so_far, frames_to_read);
        var destination_sample: usize = 0;
        for (runs) |run| {
            for (ring.samples[run.first_sample..][0..run.sample_count]) |*queued_sample| {
                destination[destination_sample] = @atomicLoad(f32, queued_sample, .monotonic);
                destination_sample += 1;
            }
        }
        @memset(destination[destination_sample..], 0);
        ring.reader.read_frames.store(read_so_far + frames_to_read, .release);
        const has_run_dry: bool = frames_to_read < wanted_frames and ring.reader.written_frames_seen > 0;
        if (has_run_dry) {
            _ = ring.reader.underrun_count.fetchAdd(1, .monotonic);
        }
        return @intCast(frames_to_read);
    }

    /// Takes up to `frame_count` waiting frames without copying them anywhere: played to nowhere, as an output with no
    /// device plays them, so that the mixer still sees its queue drain at the real rate. Audio thread.
    pub fn discard(ring: *AudioRing, frame_count: u64) void {
        const read_so_far: u64 = ring.reader.read_frames.load(.monotonic);
        ring.reader.written_frames_seen = ring.writer.written_frames.load(.acquire);
        const frames_to_discard: u64 = @min(ring.reader.written_frames_seen - read_so_far, frame_count);
        ring.reader.read_frames.store(read_so_far + frames_to_discard, .release);
    }
};

test "the audio ring keeps frames in order across its end, and gives silence when dry" {
    var samples: [8 * 2]f32 = undefined;
    var ring: AudioRing = .init(&samples, 8, 2);
    const six_frames: [12]f32 = .{ 1, -1, 2, -2, 3, -3, 4, -4, 5, -5, 6, -6 };
    try expect(ring.write(&six_frames) == 6);
    var four: [8]f32 = undefined;
    try expect(ring.read(&four) == 4);
    try expectEqualSlices(f32, &.{ 1, -1, 2, -2, 3, -3, 4, -4 }, &four);
    // Six more: the ring holds 2, so these wrap past its end.
    try expect(ring.write(&six_frames) == 6);
    try expect(ring.queuedFrames() == 8);
    // A full ring takes nothing more.
    try expect(ring.write(&six_frames) == 0);
    var ten: [20]f32 = undefined;
    try expect(ring.read(&ten) == 8);
    try expectEqualSlices(f32, &.{ 5, -5, 6, -6, 1, -1, 2, -2, 3, -3, 4, -4, 5, -5, 6, -6 }, ten[0..16]);
    try expectEqualSlices(f32, &.{ 0, 0, 0, 0 }, ten[16..20]);
    try expect(ring.underrunCount() == 1);
}

test "the audio ring mixes in aligned to its end, past the guard, held to -1..1" {
    var samples: [8 * 2]f32 = undefined;
    var ring: AudioRing = .init(&samples, 8, 2);
    const quarter: [16]f32 = @splat(0.25);
    _ = ring.write(&quarter);
    var first: [2]f32 = undefined;
    _ = ring.read(&first);
    // Seven frames wait; the first two past the read position are guarded. Ten frames offered: only the last five
    // reach the ring, onto its last five frames.
    const addition: [20]f32 = @splat(0.875);
    ring.mixInto(&addition, 2);
    var rest: [14]f32 = undefined;
    _ = ring.read(&rest);
    try expectEqualSlices(f32, &.{ 0.25, 0.25, 0.25, 0.25, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 }, &rest);
}

test "the audio ring, written by one thread and read by another, delivers every frame once, in order" {
    const frame_total: u32 = 200_000;
    var samples: [256 * 2]f32 = undefined;
    var ring: AudioRing = .init(&samples, 256, 2);
    const Producer = struct {
        fn run(target: *AudioRing) void {
            var next_frame: u32 = 0;
            while (next_frame < frame_total) {
                var chunk: [37 * 2]f32 = undefined;
                const chunk_frames: u32 = @min(37, frame_total - next_frame);
                for (0..chunk_frames) |offset| {
                    const value: f32 = @floatFromInt(next_frame + offset);
                    chunk[offset * 2] = value;
                    chunk[offset * 2 + 1] = -value;
                }
                next_frame += @intCast(target.write(chunk[0 .. chunk_frames * 2]));
            }
        }
    };
    const producer: std.Thread = try .spawn(.{}, Producer.run, .{&ring});
    var expected_frame: u32 = 0;
    var destination: [53 * 2]f32 = undefined;
    while (expected_frame < frame_total) {
        const frames_read: usize = ring.read(&destination);
        for (0..frames_read) |offset| {
            const expected_value: f32 = @floatFromInt(expected_frame);
            try expect(destination[offset * 2] == expected_value);
            try expect(destination[offset * 2 + 1] == -expected_value);
            expected_frame += 1;
        }
    }
    producer.join();
}

test "the audio ring, mixed into as another thread reads it, keeps every frame exact and in order" {
    const frame_total: u32 = 100_000;
    var samples: [256 * 2]f32 = undefined;
    var ring: AudioRing = .init(&samples, 256, 2);
    const Frames = struct {
        /// A frame's value: within -1..1, so that the clamp of a sum never changes it.
        fn valueOf(frame_number: u32) f32 {
            const step: f32 = @floatFromInt(frame_number % 1000);
            return step / 1000.0;
        }

        /// Writes the frames in uneven chunks; after each, adds silence onto every frame waiting, with no guard - each
        /// value stays bit for bit what it was, but the frames the reader may be copying are loaded and stored.
        fn write(target: *AudioRing) void {
            const silence: [256 * 2]f32 = @splat(0);
            var next_frame: u32 = 0;
            while (next_frame < frame_total) {
                var chunk: [37 * 2]f32 = undefined;
                const chunk_frames: u32 = @min(37, frame_total - next_frame);
                for (0..chunk_frames) |offset| {
                    const frame_number: u32 = next_frame + @as(u32, @intCast(offset));
                    chunk[offset * 2] = valueOf(frame_number);
                    chunk[offset * 2 + 1] = -valueOf(frame_number);
                }
                next_frame += @intCast(target.write(chunk[0 .. chunk_frames * 2]));
                target.mixInto(&silence, 0);
            }
        }
    };
    const writer: std.Thread = try .spawn(.{}, Frames.write, .{&ring});
    var expected_frame: u32 = 0;
    var destination: [53 * 2]f32 = undefined;
    while (expected_frame < frame_total) {
        const frames_read: usize = ring.read(&destination);
        for (0..frames_read) |offset| {
            try expect(destination[offset * 2] == Frames.valueOf(expected_frame));
            try expect(destination[offset * 2 + 1] == -Frames.valueOf(expected_frame));
            expected_frame += 1;
        }
    }
    writer.join();
}
