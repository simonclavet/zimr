//! NATIVE INPUT - Windows' input messages, translated into the engine's input calls exactly as the browser bridge
//! makes them.
//!
//! The engine receives input through a handful of calls (`wgpu_app.zig`'s `inputPush*`): a key down or up, a typed
//! character, the mouse's position, a button, the wheel. In the browser the bridge makes those calls from DOM events.
//! On Windows the window procedure (`win32.zig`) turns each message into an `InputEvent` here and queues it, and once
//! per frame the native loop hands the queued events, in order, to the program's input function, which makes the
//! engine's calls. The rules match what the bridge sends, so the engine cannot tell the platforms apart:
//!
//!     keys      physical keys, as `KeyboardEvent.code` is on the web: a scancode names a key by its position,
//!               whatever the keyboard layout. It is turned into the DOM code's name, and looked up in the bridge's
//!               own table (`dom_input.keyboardKeyFromDomCode`), so the two platforms share one mapping.
//!     repeat    the operating system's: a held key's repeated `WM_KEYDOWN` carries "already down" in bit 30 of its
//!               `lParam`, as the browser's `repeat` flag does - so the user's own repeat settings apply.
//!     text      only from `WM_CHAR`, never from key codes: by then Windows has applied the keyboard layout, dead
//!               keys and the IME. It arrives as UTF-16 units, combined here into code points. Control characters
//!               (Backspace's 0x08, Enter's 0x0D, Ctrl+A's 0x01) are left to the keys, as the browser leaves them.
//!     mouse     client coordinates in physical pixels, divided by the window's scale: the engine works in the
//!               browser's CSS pixels.
//!     buttons   Windows' left, middle, right, X1 and X2, numbered as the DOM numbers them (0, 1, 2, 3, 4), then the
//!               bridge's own mapping (`dom_input.mouseButtonFromDomButton`).
//!     wheel     one unit per notch - Windows reports 120 - positive away from the user and to the right.
//!     focus     the window gaining and losing the keyboard's focus become events. The engine, not this file,
//!               releases what is held when focus leaves, as it does for the browser's blur.
//!
//! Platform-neutral on purpose: `win32.zig` supplies only the messages' numbers, nothing here calls Windows, and so
//! every rule is tested on any host, from the messages' own bits.

const std = @import("std");
const utf8Encode = std.unicode.utf8Encode;
const startsWith = std.mem.startsWith;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const trim = std.mem.trim;
const dom_input = @import("dom_input.zig");
const types = @import("types.zig");
const contract = @import("platform/contract.zig");
const win32 = @import("win32.zig");

const KeyboardKey = types.KeyboardKey;
const StaticBitSet = std.bit_set.StaticBitSet;
const expectEqualStrings = std.testing.expectEqualStrings;
const bufPrint = std.fmt.bufPrint;
const indexOf = std.mem.indexOf;

// ---- Keys ----

/// One key's Windows scancode and the DOM code naming the same key.
const ScancodeName = struct {
    /// Set 1, with 0x100 added for an extended key (`KF_EXTENDED`, the `E0` prefix).
    scancode: u16,
    dom_code: []const u8,
};

/// Every key the bridge's table names, by its Windows scancode: the Windows column of the W3C "UI Events
/// KeyboardEvent code Values". Windows reports Pause as 0x45 and Num Lock as 0x145 (the keyboard itself sends them
/// the other way round, and the driver swaps them).
const scancode_names = [_]ScancodeName{
    // Letters.
    .{ .scancode = 0x1E, .dom_code = "KeyA" },
    .{ .scancode = 0x30, .dom_code = "KeyB" },
    .{ .scancode = 0x2E, .dom_code = "KeyC" },
    .{ .scancode = 0x20, .dom_code = "KeyD" },
    .{ .scancode = 0x12, .dom_code = "KeyE" },
    .{ .scancode = 0x21, .dom_code = "KeyF" },
    .{ .scancode = 0x22, .dom_code = "KeyG" },
    .{ .scancode = 0x23, .dom_code = "KeyH" },
    .{ .scancode = 0x17, .dom_code = "KeyI" },
    .{ .scancode = 0x24, .dom_code = "KeyJ" },
    .{ .scancode = 0x25, .dom_code = "KeyK" },
    .{ .scancode = 0x26, .dom_code = "KeyL" },
    .{ .scancode = 0x32, .dom_code = "KeyM" },
    .{ .scancode = 0x31, .dom_code = "KeyN" },
    .{ .scancode = 0x18, .dom_code = "KeyO" },
    .{ .scancode = 0x19, .dom_code = "KeyP" },
    .{ .scancode = 0x10, .dom_code = "KeyQ" },
    .{ .scancode = 0x13, .dom_code = "KeyR" },
    .{ .scancode = 0x1F, .dom_code = "KeyS" },
    .{ .scancode = 0x14, .dom_code = "KeyT" },
    .{ .scancode = 0x16, .dom_code = "KeyU" },
    .{ .scancode = 0x2F, .dom_code = "KeyV" },
    .{ .scancode = 0x11, .dom_code = "KeyW" },
    .{ .scancode = 0x2D, .dom_code = "KeyX" },
    .{ .scancode = 0x15, .dom_code = "KeyY" },
    .{ .scancode = 0x2C, .dom_code = "KeyZ" },
    // Digits.
    .{ .scancode = 0x0B, .dom_code = "Digit0" },
    .{ .scancode = 0x02, .dom_code = "Digit1" },
    .{ .scancode = 0x03, .dom_code = "Digit2" },
    .{ .scancode = 0x04, .dom_code = "Digit3" },
    .{ .scancode = 0x05, .dom_code = "Digit4" },
    .{ .scancode = 0x06, .dom_code = "Digit5" },
    .{ .scancode = 0x07, .dom_code = "Digit6" },
    .{ .scancode = 0x08, .dom_code = "Digit7" },
    .{ .scancode = 0x09, .dom_code = "Digit8" },
    .{ .scancode = 0x0A, .dom_code = "Digit9" },
    // Punctuation.
    .{ .scancode = 0x29, .dom_code = "Backquote" },
    .{ .scancode = 0x0C, .dom_code = "Minus" },
    .{ .scancode = 0x0D, .dom_code = "Equal" },
    .{ .scancode = 0x1A, .dom_code = "BracketLeft" },
    .{ .scancode = 0x1B, .dom_code = "BracketRight" },
    .{ .scancode = 0x2B, .dom_code = "Backslash" },
    .{ .scancode = 0x27, .dom_code = "Semicolon" },
    .{ .scancode = 0x28, .dom_code = "Quote" },
    .{ .scancode = 0x33, .dom_code = "Comma" },
    .{ .scancode = 0x34, .dom_code = "Period" },
    .{ .scancode = 0x35, .dom_code = "Slash" },
    // Whitespace and editing.
    .{ .scancode = 0x39, .dom_code = "Space" },
    .{ .scancode = 0x01, .dom_code = "Escape" },
    .{ .scancode = 0x1C, .dom_code = "Enter" },
    .{ .scancode = 0x0F, .dom_code = "Tab" },
    .{ .scancode = 0x0E, .dom_code = "Backspace" },
    .{ .scancode = 0x152, .dom_code = "Insert" },
    .{ .scancode = 0x153, .dom_code = "Delete" },
    .{ .scancode = 0x147, .dom_code = "Home" },
    .{ .scancode = 0x14F, .dom_code = "End" },
    .{ .scancode = 0x149, .dom_code = "PageUp" },
    .{ .scancode = 0x151, .dom_code = "PageDown" },
    // Arrows.
    .{ .scancode = 0x14D, .dom_code = "ArrowRight" },
    .{ .scancode = 0x14B, .dom_code = "ArrowLeft" },
    .{ .scancode = 0x150, .dom_code = "ArrowDown" },
    .{ .scancode = 0x148, .dom_code = "ArrowUp" },
    // Function keys.
    .{ .scancode = 0x3B, .dom_code = "F1" },
    .{ .scancode = 0x3C, .dom_code = "F2" },
    .{ .scancode = 0x3D, .dom_code = "F3" },
    .{ .scancode = 0x3E, .dom_code = "F4" },
    .{ .scancode = 0x3F, .dom_code = "F5" },
    .{ .scancode = 0x40, .dom_code = "F6" },
    .{ .scancode = 0x41, .dom_code = "F7" },
    .{ .scancode = 0x42, .dom_code = "F8" },
    .{ .scancode = 0x43, .dom_code = "F9" },
    .{ .scancode = 0x44, .dom_code = "F10" },
    .{ .scancode = 0x57, .dom_code = "F11" },
    .{ .scancode = 0x58, .dom_code = "F12" },
    // Locks and system keys.
    .{ .scancode = 0x3A, .dom_code = "CapsLock" },
    .{ .scancode = 0x46, .dom_code = "ScrollLock" },
    .{ .scancode = 0x145, .dom_code = "NumLock" },
    .{ .scancode = 0x137, .dom_code = "PrintScreen" },
    .{ .scancode = 0x45, .dom_code = "Pause" },
    // Modifiers: the extended bit tells the right Ctrl and Alt from the left ones.
    .{ .scancode = 0x2A, .dom_code = "ShiftLeft" },
    .{ .scancode = 0x1D, .dom_code = "ControlLeft" },
    .{ .scancode = 0x38, .dom_code = "AltLeft" },
    .{ .scancode = 0x15B, .dom_code = "MetaLeft" },
    .{ .scancode = 0x36, .dom_code = "ShiftRight" },
    .{ .scancode = 0x11D, .dom_code = "ControlRight" },
    .{ .scancode = 0x138, .dom_code = "AltRight" },
    .{ .scancode = 0x15C, .dom_code = "MetaRight" },
    .{ .scancode = 0x15D, .dom_code = "ContextMenu" },
    // The keypad: its keys keep their own scancodes with Num Lock off, as the browser keeps their codes.
    .{ .scancode = 0x52, .dom_code = "Numpad0" },
    .{ .scancode = 0x4F, .dom_code = "Numpad1" },
    .{ .scancode = 0x50, .dom_code = "Numpad2" },
    .{ .scancode = 0x51, .dom_code = "Numpad3" },
    .{ .scancode = 0x4B, .dom_code = "Numpad4" },
    .{ .scancode = 0x4C, .dom_code = "Numpad5" },
    .{ .scancode = 0x4D, .dom_code = "Numpad6" },
    .{ .scancode = 0x47, .dom_code = "Numpad7" },
    .{ .scancode = 0x48, .dom_code = "Numpad8" },
    .{ .scancode = 0x49, .dom_code = "Numpad9" },
    .{ .scancode = 0x53, .dom_code = "NumpadDecimal" },
    .{ .scancode = 0x135, .dom_code = "NumpadDivide" },
    .{ .scancode = 0x37, .dom_code = "NumpadMultiply" },
    .{ .scancode = 0x4A, .dom_code = "NumpadSubtract" },
    .{ .scancode = 0x4E, .dom_code = "NumpadAdd" },
    .{ .scancode = 0x11C, .dom_code = "NumpadEnter" },
    .{ .scancode = 0x59, .dom_code = "NumpadEqual" },
};

/// How many scancodes there are, the extended ones included: 0x00 to 0x1FF.
const scancode_count: usize = 0x200;

/// The engine key at each scancode, or null for a key the engine has no name for. Built at compile time from the
/// table above, through the bridge's own mapping from DOM codes to engine keys.
const engine_key_by_scancode: [scancode_count]?KeyboardKey = table: {
    @setEvalBranchQuota(200_000);
    var keys: [scancode_count]?KeyboardKey = @splat(null);
    for (scancode_names) |entry| {
        keys[entry.scancode] = dom_input.keyboardKeyFromDomCode(entry.dom_code) orelse
            @compileError("the bridge's key table has no DOM code " ++ entry.dom_code);
    }
    break :table keys;
};

/// The scancode of each engine key - the table above, turned the other way - indexed by the key's value, null for a
/// key no scancode names. Built at compile time.
const scancode_by_engine_key: [512]?u16 = table: {
    @setEvalBranchQuota(200_000);
    var scancodes: [512]?u16 = @splat(null);
    for (scancode_names) |entry| {
        const key: KeyboardKey = dom_input.keyboardKeyFromDomCode(entry.dom_code).?;
        const key_index: usize = @intCast(@backingInt(key));
        if (scancodes[key_index] == null) {
            scancodes[key_index] = entry.scancode;
        }
    }
    break :table scancodes;
};

/// The scancode of an engine key, the extended ones with 0x100 added (`ScancodeName`); null for a key no scancode
/// names.
pub fn scancodeOfEngineKey(key: KeyboardKey) ?u16 {
    const key_value: i32 = @backingInt(key);
    if (key_value < 0 or key_value >= scancode_by_engine_key.len) {
        return null;
    }
    return scancode_by_engine_key[@intCast(key_value)];
}

/// The scancode Windows reports, corrected where it misreports a key (the rules RGFW applies): Alt+PrintScreen
/// arrives as 0x54 and Ctrl+Pause as 0x146, and CJK input methods set the extended bit on the right Shift (0x136).
pub fn correctedScancode(scancode: u16) u16 {
    return switch (scancode) {
        0x54 => 0x137, // PrintScreen
        0x146 => 0x45, // Pause
        0x136 => 0x36, // ShiftRight
        else => scancode,
    };
}

/// The engine key at a scancode - the scancode plus 0x100 when the key is extended - or null for one it has no name
/// for (as the bridge drops a DOM code it has no row for).
pub fn engineKeyFromScancode(scancode: u16) ?KeyboardKey {
    if (scancode >= scancode_count) {
        return null;
    }
    return engine_key_by_scancode[scancode];
}

// ---- Text ----

/// The replacement character, for a UTF-16 unit that cannot form a code point.
pub const replacement_character: u21 = 0xFFFD;

/// A surrogate's top six bits tell which half it is: 0xD800 for a high surrogate, 0xDC00 for a low one. The other
/// ten bits are its share of the character.
const surrogate_half_mask: u16 = 0xFC00;
const high_surrogate_base: u16 = 0xD800;
const low_surrogate_base: u16 = 0xDC00;

/// The first code point past the Basic Multilingual Plane, which a surrogate pair counts from.
const first_supplementary_code_point: u21 = 0x10000;

/// Pairs UTF-16 units into code points, as `WM_CHAR` delivers them. A character outside the Basic Multilingual
/// Plane - an emoji, a rare CJK ideograph - arrives as two messages, a high surrogate (0xD800 to 0xDBFF) and then a
/// low one (0xDC00 to 0xDFFF), which combine into one code point. A surrogate without its partner becomes U+FFFD.
pub const Utf16Decoder = struct {
    /// A high surrogate waiting for its low one.
    pending_high: ?u16 = null,

    /// The code points `unit` completes, written into `out`: none (a high surrogate, now waiting), one, or two (an
    /// unpaired high surrogate replaced, then `unit`'s own character).
    pub fn push(decoder: *Utf16Decoder, unit: u16, out: *[2]u21) []const u21 {
        var count: usize = 0;
        const is_high: bool = unit & surrogate_half_mask == high_surrogate_base;
        const is_low: bool = unit & surrogate_half_mask == low_surrogate_base;
        if (decoder.pending_high) |high| {
            decoder.pending_high = null;
            if (is_low) {
                // The pair carries the character's distance past the Basic Multilingual Plane in twenty bits: the
                // high surrogate the top ten, the low one the bottom ten.
                const high_bits: u21 = high - high_surrogate_base;
                const low_bits: u21 = unit - low_surrogate_base;
                out[0] = first_supplementary_code_point + (high_bits << 10) + low_bits;
                return out[0..1];
            }
            out[count] = replacement_character;
            count += 1;
        }
        if (is_high) {
            decoder.pending_high = unit;
        } else if (is_low) {
            out[count] = replacement_character;
            count += 1;
        } else {
            out[count] = unit;
            count += 1;
        }
        return out[0..count];
    }
};

/// Whether a code point is text to type, rather than a control character the keys already stand for: the C0
/// controls below a space (Backspace, Tab, Enter, Escape, Ctrl+letter), DEL, and the C1 controls are not.
pub fn isTypedText(code_point: u21) bool {
    const is_c0_control: bool = code_point < 0x20;
    const is_delete: bool = code_point == 0x7F;
    const is_c1_control: bool = code_point >= 0x80 and code_point < 0xA0;
    return !(is_c0_control or is_delete or is_c1_control);
}

// ---- The mouse ----

/// The wheel distance Windows reports for one notch (`WHEEL_DELTA`).
pub const wheel_delta: f32 = 120;

/// A wheel message's distance in notches, the engine's unit: positive away from the user (`WM_MOUSEWHEEL`) or to
/// the right (`WM_MOUSEHWHEEL`). A fine-grained wheel or touchpad reports fractions of a notch.
pub fn wheelNotches(delta: i16) f32 {
    const distance: f32 = @floatFromInt(delta);
    return distance / wheel_delta;
}

/// A client coordinate in physical pixels as the engine's logical pixel - the browser's CSS pixel. `scale` is the
/// window's (1.0 at 100%, 1.5 at 150%).
pub fn logicalPixels(physical: i32, scale: f32) f32 {
    const physical_pixels: f32 = @floatFromInt(physical);
    return physical_pixels / scale;
}

/// A mouse button in the DOM's numbering - the contract's (`contract.Button`), which the engine maps to its own.
pub const DomButton = contract.Button;

// ---- Events and the queue ----

/// A key going down: the engine's key, whether it was down already (an auto-repeat), and what it types on the
/// current layout (`win32.InputMessage.label`).
pub const KeyDown = struct {
    key: KeyboardKey,
    repeat: bool,
    label: u21 = 0,
};

/// A position in logical pixels.
pub const Position = struct {
    x: f32,
    y: f32,
};

/// A wheel movement in notches, on each axis.
pub const WheelMovement = struct {
    horizontal: f32,
    vertical: f32,
};

/// The mouse's motion as raw input reports it, while the pointer is locked: logical pixels, signed.
pub const PointerMotion = struct {
    dx: f32,
    dy: f32,
};

/// One input event, as the engine's calls take it.
pub const InputEvent = union(enum) {
    key_down: KeyDown,
    key_up: KeyboardKey,
    character: u21,
    mouse_move: Position,
    mouse_button_down: DomButton,
    mouse_button_up: DomButton,
    /// The window gained the keyboard's focus.
    focus_gained,
    /// The window lost the keyboard's focus; the releases of what is held go to another window.
    focus_lost,
    /// The pointer entered the window's client area.
    mouse_enter,
    /// The pointer left it.
    mouse_leave,
    /// The mouse's own motion while the pointer is locked, in logical pixels.
    pointer_motion: PointerMotion,
    /// The pointer lock began (true) or ended.
    pointer_lock_changed: bool,
    /// Fullscreen began (true) or ended.
    fullscreen_changed: bool,
    /// A text pasted, as UTF-8, in the window's paste buffer until the next paste.
    paste: []const u8,
    mouse_wheel: WheelMovement,
};

/// The size of a set of keys: above the engine's highest key number (348).
const key_number_limit: usize = 512;

/// The input waiting for the next frame, in the order it happened. The window procedure
/// pushes; the native loop drains, once per frame. A frame's input is a few dozen events at most; a queue that
/// fills drops the newest, so the events already queued keep their order.
pub const InputQueue = struct {
    /// The events waiting, in order; the first `count` are queued.
    events: [capacity]InputEvent = undefined,
    count: usize = 0,
    /// The text decoder's state: a high surrogate may wait from one `WM_CHAR` to the next.
    decoder: Utf16Decoder = .{},
    /// Whether PrintScreen is down. Windows usually sends its release without its press, which the screenshot tool
    /// takes, so a release finding it up is given its press first (`translateKeyUp`).
    print_screen_held: bool = false,

    /// The events one frame can queue; past it, the newest are dropped.
    const capacity: usize = 512;

    /// Queues an event.
    pub fn push(queue: *InputQueue, event: InputEvent) void {
        if (queue.count == capacity) {
            return;
        }
        queue.events[queue.count] = event;
        queue.count += 1;
    }

    /// Queues the characters a `WM_CHAR` unit completes, leaving out control characters.
    pub fn pushUtf16(queue: *InputQueue, unit: u16) void {
        var code_points: [2]u21 = undefined;
        for (queue.decoder.push(unit, &code_points)) |code_point| {
            if (isTypedText(code_point)) {
                queue.push(.{ .character = code_point });
            }
        }
    }

    /// The queued events, in order; `clear` after handling them.
    pub fn pending(queue: *const InputQueue) []const InputEvent {
        return queue.events[0..queue.count];
    }

    /// Empties the queue.
    pub fn clear(queue: *InputQueue) void {
        queue.count = 0;
    }
};

/// The queue's events as the contract's (`platform/contract.zig`), converted one at a time in the order they were
/// queued. Two things come from earlier events: a button event happens where the pointer is, which the last move
/// reported (the queue puts a move before every button); and a move's movement is its distance from the last move.
/// A character becomes UTF-8 text, in bytes the converter holds until the next conversion - the engine copies what it
/// keeps. Modifiers are not recorded here: the engine reads them from the keys it holds.
pub const ContractEvents = struct {
    pointer: Position = .{ .x = 0, .y = 0 },
    text_bytes: [4]u8 = undefined,
    /// When the events being converted arrived, in milliseconds on the system's monotonic clock - the clock sound is
    /// requested on - or 0 for none: the time a press carries (`KeyDown.time_ms`, `MouseButton.time_ms`), from which
    /// the latency readout measures the frame's wait. The window's loop sets it as it hands a pass's input over, which
    /// it does as soon as the input arrives (`native_loop.waitForFrame`).
    arrival_ms: f64 = 0,

    pub fn convert(converter: *ContractEvents, event: InputEvent) contract.Event {
        return switch (event) {
            .key_down => |down| .{ .key_down = .{
                .key = down.key,
                .repeat = down.repeat,
                .label = down.label,
                .modifiers = .{},
                .time_ms = converter.arrival_ms,
            } },
            .key_up => |key| .{ .key_up = .{ .key = key, .modifiers = .{} } },
            .character => |code_point| .{ .text = .{ .bytes = converter.encode(code_point) } },
            .mouse_move => |position| move: {
                const previous: Position = converter.pointer;
                converter.pointer = position;
                break :move .{ .mouse_move = .{
                    .x = position.x,
                    .y = position.y,
                    .dx = position.x - previous.x,
                    .dy = position.y - previous.y,
                    .modifiers = .{},
                } };
            },
            .mouse_button_down => |button| .{ .mouse_button_down = converter.buttonAtPointer(button) },
            .mouse_button_up => |button| .{ .mouse_button_up = converter.buttonAtPointer(button) },
            .mouse_wheel => |wheel| .{ .mouse_wheel = .{
                .dx = wheel.horizontal,
                .dy = wheel.vertical,
                .modifiers = .{},
            } },
            .focus_gained => .focus_gained,
            .focus_lost => .focus_lost,
            .mouse_enter => .mouse_enter,
            .mouse_leave => .mouse_leave,
            // A locked pointer stays where it was; the motion is the hand's.
            .pointer_motion => |motion| .{ .mouse_move = .{
                .x = converter.pointer.x,
                .y = converter.pointer.y,
                .dx = motion.dx,
                .dy = motion.dy,
                .modifiers = .{},
            } },
            .pointer_lock_changed => |is_locked| .{ .pointer_lock_changed = is_locked },
            .fullscreen_changed => |is_on| .{ .fullscreen_changed = is_on },
            .paste => |text| .{ .paste = .{ .bytes = text } },
        };
    }

    /// A button event at the pointer's last position, the button in the DOM's numbering.
    fn buttonAtPointer(converter: *const ContractEvents, button: DomButton) contract.MouseButton {
        return .{
            .button = button,
            .x = converter.pointer.x,
            .y = converter.pointer.y,
            .modifiers = .{},
            .time_ms = converter.arrival_ms,
        };
    }

    /// A code point's UTF-8 bytes, in the converter's buffer. One that cannot be encoded - a lone surrogate, which the
    /// decoder already replaces - becomes U+FFFD, the replacement character, as the decoder's own replacements do.
    fn encode(converter: *ContractEvents, code_point: u21) []const u8 {
        const byte_count: u3 = utf8Encode(code_point, &converter.text_bytes) catch return "\u{fffd}";
        return converter.text_bytes[0..byte_count];
    }
};

// ---- Translation ----

/// The key a key message names: the scancode in bits 16 to 23, plus 0x100 when bit 24 marks the key extended.
fn keyOf(parameter_bits: usize) ?KeyboardKey {
    // Nine bits from bit 16: the scancode's eight, and the extended bit above them - which lands as the 0x100.
    const scancode: u16 = @intCast((parameter_bits >> 16) & 0x1ff);
    return engineKeyFromScancode(correctedScancode(scancode));
}

/// A key-down message as the engine's key down: the key it names, and whether it is an auto-repeat.
fn translateKeyDown(parameter_bits: usize, label: u21, queue: *InputQueue) void {
    const key: KeyboardKey = keyOf(parameter_bits) orelse return;
    // Bit 30: the key was down before this message - an auto-repeat.
    const was_down: bool = (parameter_bits >> 30) & 1 != 0;
    if (key == .print_screen) {
        queue.print_screen_held = true;
    }
    queue.push(.{ .key_down = .{ .key = key, .repeat = was_down, .label = label } });
}

/// A key-up message as the engine's key up.
fn translateKeyUp(w_param: usize, parameter_bits: usize, queue: *InputQueue) void {
    const key: KeyboardKey = keyOf(parameter_bits) orelse return;
    // Windows usually sends PrintScreen's release without its press (the screenshot tool takes the press); the press
    // is given here, so the engine sees both - unless the press did arrive, and the key is held already.
    const is_print_screen: bool = w_param == win32.VK_SNAPSHOT;
    if (is_print_screen and !queue.print_screen_held) {
        queue.push(.{ .key_down = .{ .key = key, .repeat = false } });
    }
    if (is_print_screen) {
        queue.print_screen_held = false;
    }
    queue.push(.{ .key_up = key });
}

/// A mouse message's position, in logical pixels.
fn positionOf(parameter_bits: usize, scale: f32) Position {
    return .{
        .x = logicalPixels(win32.signedLowWord(parameter_bits), scale),
        .y = logicalPixels(win32.signedHighWord(parameter_bits), scale),
    };
}

/// A button message: the position first - the engine takes where a press happened from the position before it, as
/// the browser's event order gives it - then the button.
fn translateButton(message: win32.InputMessage, queue: *InputQueue) void {
    const button: DomButton = switch (message.message) {
        win32.WM_LBUTTONDOWN, win32.WM_LBUTTONUP => .left,
        win32.WM_MBUTTONDOWN, win32.WM_MBUTTONUP => .middle,
        win32.WM_RBUTTONDOWN, win32.WM_RBUTTONUP => .right,
        // An X button's message names which one in its parameter's high word.
        // The first side button is the browser's back, the second its forward.
        else => if (win32.highWord(message.w_param) == win32.XBUTTON1) .back else .forward,
    };
    const is_press: bool = switch (message.message) {
        win32.WM_LBUTTONDOWN, win32.WM_RBUTTONDOWN, win32.WM_MBUTTONDOWN, win32.WM_XBUTTONDOWN => true,
        else => false,
    };
    const parameter_bits: usize = @bitCast(message.l_param);
    queue.push(.{ .mouse_move = positionOf(parameter_bits, message.scale) });
    if (is_press) {
        queue.push(.{ .mouse_button_down = button });
    } else {
        queue.push(.{ .mouse_button_up = button });
    }
}

/// Turns one of the window's input messages into the engine's events, queued in order. The window procedure has
/// done Windows' own part of the message already (`win32.Window.forwardInput`).
pub fn translate(message: win32.InputMessage, queue: *InputQueue) void {
    const parameter_bits: usize = @bitCast(message.l_param);
    switch (message.message) {
        win32.WM_KEYDOWN, win32.WM_SYSKEYDOWN => translateKeyDown(parameter_bits, message.label, queue),
        win32.WM_KEYUP, win32.WM_SYSKEYUP => translateKeyUp(message.w_param, parameter_bits, queue),
        win32.WM_CHAR => queue.pushUtf16(@truncate(message.w_param)),
        win32.WM_MOUSEMOVE => queue.push(.{ .mouse_move = positionOf(parameter_bits, message.scale) }),
        win32.WM_LBUTTONDOWN,
        win32.WM_RBUTTONDOWN,
        win32.WM_MBUTTONDOWN,
        win32.WM_XBUTTONDOWN,
        win32.WM_LBUTTONUP,
        win32.WM_RBUTTONUP,
        win32.WM_MBUTTONUP,
        win32.WM_XBUTTONUP,
        => translateButton(message, queue),
        win32.WM_MOUSEWHEEL => {
            const notches: f32 = wheelNotches(win32.signedHighWord(message.w_param));
            queue.push(.{ .mouse_wheel = .{ .horizontal = 0, .vertical = notches } });
        },
        win32.WM_MOUSEHWHEEL => {
            const notches: f32 = wheelNotches(win32.signedHighWord(message.w_param));
            queue.push(.{ .mouse_wheel = .{ .horizontal = notches, .vertical = 0 } });
        },
        win32.WM_SETFOCUS => queue.push(.focus_gained),
        win32.WM_KILLFOCUS => queue.push(.focus_lost),
        win32.message_pointer_entered => queue.push(.mouse_enter),
        win32.WM_MOUSELEAVE => queue.push(.mouse_leave),
        win32.message_pointer_motion => {
            const horizontal: isize = @bitCast(message.w_param);
            const vertical: isize = message.l_param;
            const horizontal_pixels: f32 = @floatFromInt(horizontal);
            const vertical_pixels: f32 = @floatFromInt(vertical);
            queue.push(.{ .pointer_motion = .{
                .dx = horizontal_pixels / message.scale,
                .dy = vertical_pixels / message.scale,
            } });
        },
        win32.message_pointer_lock_changed => queue.push(.{ .pointer_lock_changed = message.w_param != 0 }),
        win32.message_fullscreen_changed => queue.push(.{ .fullscreen_changed = message.w_param != 0 }),
        win32.message_paste => queue.push(.{ .paste = message.text }),
        else => {},
    }
}

// ---- Tests ----

// ---- Scripts ----
//
// A headless run's person is a script: a stream of lines, each one command (`Command`) written in ZON, which the run
// executes as it reads them - so a run is paused whenever it waits for its next line, and more lines resume it. The
// commands that stand for a person's hands are turned into the contract's events here (`ScriptedPerson`), carrying
// what a real mouse and keyboard's events carry; the run's frame driver (`native_loop.headless`) delivers them, draws
// frames when told to (`advance`), and answers the commands that observe (`capture`, `sync`).

/// The most frames one `advance` draws: ten minutes' worth, so that a slip of the keyboard cannot hold a run for hours.
pub const most_frames_per_advance: u32 = 36_000;

/// A wheel's turn, in notches: `dy` positive away from the person, `dx` to the right; an axis not given does not turn.
/// A frame saved shrunk (`Command.capture_thumbnail`): the file's path, and the width it is shrunk to - its height in
/// proportion. A width at least the frame's saves it whole.
pub const Thumbnail = struct {
    path: []const u8,
    width: u32,
};

pub const Notches = struct {
    dx: f32 = 0,
    dy: f32 = 0,
};

/// A gamepad button's new value, from 0 released to 1 fully pressed - a trigger takes the values between
/// (`gamepad_button`). The slot is 0, and the value 1, unless given.
pub const GamepadButtonValue = struct {
    slot: contract.GamepadSlot = 0,
    button: contract.GamepadButton,
    value: f32 = 1,
};

/// A gamepad stick axis's new position, from -1 to 1, right and down positive (`gamepad_axis`). The slot is 0 unless
/// given.
pub const GamepadAxisValue = struct {
    slot: contract.GamepadSlot = 0,
    axis: contract.GamepadAxis,
    value: f32,
};

/// One command of a script: the language itself, each line one value of this type written in ZON (`parseCommand`).
///
///     .{ .advance = 3 }                         draws 3 frames: the only command that moves time
///     .{ .move = .{ .x = 240, .y = 121 } }      the pointer moves there, in the drawing area's logical pixels
///     .{ .press = .left }                       a mouse button goes down where the pointer is: .left, .middle,
///                                               .right, .back or .forward
///     .{ .release = .left }                     ... and comes up
///     .{ .wheel = .{ .dy = 1 } }                the wheel turns a notch away from the person (`Notches`)
///     .{ .key_down = .left_shift }              a key goes down, by its name in `KeyboardKey`
///     .{ .key_up = .left_shift }                ... and comes up
///     .{ .text = "Simon" }                      text typed - a ZON string, so "\n" and "\u{e9}" are written so
///     .{ .paste = "12ab34" }                    text pasted by the system's paste command
///     .capture                                  saves the frame last drawn, as frame_<n>.png in the capture directory
///     .{ .capture_to = "shots/name.png" }       saves the frame last drawn at a path of its own
///     .{ .capture_thumbnail = .{ .path = "shots/name.png", .width = 320 } }  ... shrunk to that width, its height
///                                               in proportion (`Thumbnail`) - each pixel the mean of those it covers
///     .{ .capture_audio_to = "run.wav" }        saves the sound played so far, as a 32-bit float WAV - headless only
///     .{ .sync = "7" }                          answered with "synced 7" once every line before it has run
///     .{ .gamepad_connect = 0 }                 a gamepad is plugged into slot 0: every button up, the sticks centred
///     .{ .gamepad_button = .{ .button = .south } }  its south button goes down (`GamepadButtonValue`: the slot 0 and
///                                               the value 1 unless given; a value of 0 lets it up)
///     .{ .gamepad_axis = .{ .axis = .left_x, .value = 0.5 } }  a stick moves (`GamepadAxisValue`)
///     .{ .gamepad_disconnect = 0 }              the gamepad in slot 0 is unplugged
///     .quit                                     ends the run, as the script's end does
///
/// Lines that are blank, or hold only a `//` comment, are skipped by the run.
pub const Command = union(enum) {
    advance: u32,
    move: Position,
    press: contract.Button,
    release: contract.Button,
    wheel: Notches,
    key_down: KeyboardKey,
    key_up: KeyboardKey,
    text: []const u8,
    paste: []const u8,
    capture,
    capture_to: []const u8,
    capture_thumbnail: Thumbnail,
    capture_audio_to: []const u8,
    sync: []const u8,
    gamepad_connect: contract.GamepadSlot,
    gamepad_disconnect: contract.GamepadSlot,
    gamepad_button: GamepadButtonValue,
    gamepad_axis: GamepadAxisValue,
    quit,
};

/// Why a line is not a command: not a `Command` in ZON - the diagnostics say where, and what was expected - or an
/// `advance` past `most_frames_per_advance`.
pub const ParseError = error{ OutOfMemory, ParseZon, TooManyFrames };

/// Parses one line of a script into a `Command`, its strings - and `diagnostics`, when the line is not ZON for a
/// command, saying where and why - allocated from `arena`, which the caller frees once done with both. `gpa` is
/// scratch only.
pub fn parseCommand(
    gpa: Allocator,
    arena: Allocator,
    line: []const u8,
    diagnostics: *std.zon.parse.Diagnostics,
) ParseError!Command {
    // ZON reads a source ending in a zero byte.
    const source: [:0]u8 = try gpa.dupeSentinel(u8, line, 0);
    defer gpa.free(source);
    const command: Command = try std.zon.parse.fromSlice(Command, .{
        .gpa = gpa,
        .arena = arena,
        .source = source,
        .diagnostics = diagnostics,
    });
    const is_too_long: bool = switch (command) {
        .advance => |frame_count| frame_count > most_frames_per_advance,
        else => false,
    };
    if (is_too_long) {
        return ParseError.TooManyFrames;
    }
    return command;
}

/// Whether a script line holds no command: blank, or only a `//` comment.
pub fn isBlankLine(line: []const u8) bool {
    const content: []const u8 = trim(u8, line, " \t\r");
    return content.len == 0 or startsWith(u8, content, "//");
}

/// The person a script stands for: where their pointer is, whether it has entered the drawing area, and which
/// modifier keys they hold - what each event from a real mouse and keyboard carries. `eventsFor` turns a command into
/// the events it makes.
pub const ScriptedPerson = struct {
    pointer: Position = .{ .x = 0, .y = 0 },
    has_pointer_entered: bool = false,
    modifiers: contract.Modifiers = .{},

    /// The most events one command makes: the pointer entering the drawing area, then its move.
    pub const most_events_per_command: usize = 2;

    /// The events `command` makes, written into `out`; none for the commands that draw or observe. The pointer enters
    /// the drawing area with its first move, and a modifier key's own event already carries its new state, as a
    /// browser's does. Text and paste events point into the command.
    pub fn eventsFor(
        person: *ScriptedPerson,
        command: Command,
        out: *[most_events_per_command]contract.Event,
    ) []const contract.Event {
        switch (command) {
            .move => |position| {
                var count: usize = 0;
                if (!person.has_pointer_entered) {
                    out[count] = .mouse_enter;
                    count += 1;
                    person.has_pointer_entered = true;
                }
                out[count] = .{ .mouse_move = .{
                    .x = position.x,
                    .y = position.y,
                    .dx = position.x - person.pointer.x,
                    .dy = position.y - person.pointer.y,
                    .modifiers = person.modifiers,
                } };
                count += 1;
                person.pointer = position;
                return out[0..count];
            },
            .press => |button| out[0] = .{ .mouse_button_down = person.buttonEvent(button) },
            .release => |button| out[0] = .{ .mouse_button_up = person.buttonEvent(button) },
            .wheel => |notches| out[0] = .{ .mouse_wheel = .{
                .dx = notches.dx,
                .dy = notches.dy,
                .modifiers = person.modifiers,
            } },
            .key_down => |key| {
                person.setModifier(key, true);
                out[0] = .{ .key_down = .{ .key = key, .repeat = false, .modifiers = person.modifiers } };
            },
            .key_up => |key| {
                person.setModifier(key, false);
                out[0] = .{ .key_up = .{ .key = key, .modifiers = person.modifiers } };
            },
            .text => |bytes| out[0] = .{ .text = .{ .bytes = bytes } },
            .paste => |bytes| out[0] = .{ .paste = .{ .bytes = bytes } },
            // Drawing and observing make no events; neither do the gamepad commands - a gamepad is read, each frame,
            // not told of (`Session.playGamepad`).
            .advance,
            .capture,
            .capture_to,
            .capture_thumbnail,
            .capture_audio_to,
            .sync,
            .quit,
            .gamepad_connect,
            .gamepad_disconnect,
            .gamepad_button,
            .gamepad_axis,
            => return out[0..0],
        }
        return out[0..1];
    }

    fn buttonEvent(person: *const ScriptedPerson, button: contract.Button) contract.MouseButton {
        return .{ .button = button, .x = person.pointer.x, .y = person.pointer.y, .modifiers = person.modifiers };
    }

    /// Records a modifier key going down or coming up; other keys leave the modifiers as they are.
    fn setModifier(person: *ScriptedPerson, key: KeyboardKey, is_down: bool) void {
        switch (key) {
            .left_shift, .right_shift => person.modifiers.shift = is_down,
            .left_control, .right_control => person.modifiers.control = is_down,
            .left_alt, .right_alt => person.modifiers.alt = is_down,
            .left_super, .right_super => person.modifiers.meta = is_down,
            else => {},
        }
    }
};

/// Whether a key going down is the system's paste command: V with Ctrl held and Alt not - AltGr is Ctrl and Alt
/// together, and types - or Insert with Shift held. A platform answers it with the clipboard's text, as Windows does
/// for a window (`win32.isPasteCommand`, from the keys' live state) and a headless run does for its script.
pub fn isPasteCommand(down: contract.KeyDown) bool {
    const is_control_v: bool = down.key == .v and down.modifiers.control and !down.modifiers.alt;
    const is_shift_insert: bool = down.key == .insert and down.modifiers.shift;
    return is_control_v or is_shift_insert;
}

const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualSlices = testing.expectEqualSlices;

test "native_input: the scancodes name every key the bridge's table names, each once" {
    var seen_scancodes: StaticBitSet(scancode_count) = .empty;
    var seen_keys: StaticBitSet(key_number_limit) = .empty;
    for (scancode_names) |entry| {
        try expectEqual(false, seen_scancodes.isSet(entry.scancode));
        seen_scancodes.set(entry.scancode);
        const key: KeyboardKey = engineKeyFromScancode(entry.scancode) orelse return error.TestUnexpectedResult;
        const key_index: usize = @intCast(@backingInt(key));
        try expectEqual(false, seen_keys.isSet(key_index));
        seen_keys.set(key_index);
    }
    // Distinct keys, as many as the bridge's rows: every row is covered.
    try expectEqual(dom_input.dom_key_count, scancode_names.len);
}

test "native_input: scancodes name the keys the browser's codes name" {
    try expectEqual(@as(?KeyboardKey, .a), engineKeyFromScancode(0x1E));
    try expectEqual(@as(?KeyboardKey, .enter), engineKeyFromScancode(0x1C));
    try expectEqual(@as(?KeyboardKey, .kp_enter), engineKeyFromScancode(0x11C));
    try expectEqual(@as(?KeyboardKey, .left), engineKeyFromScancode(0x14B));
    try expectEqual(@as(?KeyboardKey, .right_shift), engineKeyFromScancode(0x36));
    try expectEqual(@as(?KeyboardKey, .right_control), engineKeyFromScancode(0x11D));
    try expectEqual(@as(?KeyboardKey, .num_lock), engineKeyFromScancode(0x145));
    try expectEqual(@as(?KeyboardKey, .pause), engineKeyFromScancode(0x45));
    // A key the engine has no name for (IntlBackslash, 0x56), and one past the table.
    try expectEqual(@as(?KeyboardKey, null), engineKeyFromScancode(0x56));
    try expectEqual(@as(?KeyboardKey, null), engineKeyFromScancode(0x200));
}

test "native_input: the three misreported scancodes are corrected" {
    try expectEqual(@as(u16, 0x137), correctedScancode(0x54));
    try expectEqual(@as(u16, 0x45), correctedScancode(0x146));
    try expectEqual(@as(u16, 0x36), correctedScancode(0x136));
    try expectEqual(@as(u16, 0x1E), correctedScancode(0x1E));
}

test "native_input: UTF-16 units pair into code points; a lone surrogate is replaced" {
    var decoder: Utf16Decoder = .{};
    var out: [2]u21 = undefined;
    try expectEqualSlices(u21, &.{'A'}, decoder.push('A', &out));
    try expectEqualSlices(u21, &.{0xE9}, decoder.push(0xE9, &out));
    // U+1F600 is 0xD83D 0xDE00.
    try expectEqualSlices(u21, &.{}, decoder.push(0xD83D, &out));
    try expectEqualSlices(u21, &.{0x1F600}, decoder.push(0xDE00, &out));
    // A low surrogate alone, and a high one followed by an ordinary character.
    try expectEqualSlices(u21, &.{replacement_character}, decoder.push(0xDE00, &out));
    try expectEqualSlices(u21, &.{}, decoder.push(0xD83D, &out));
    try expectEqualSlices(u21, &.{ replacement_character, 'B' }, decoder.push('B', &out));
}

test "native_input: control characters are left to the keys" {
    for ([_]u21{ 0x01, 0x08, 0x09, 0x0D, 0x1B, 0x7F, 0x85 }) |control| {
        try expectEqual(false, isTypedText(control));
    }
    for ([_]u21{ ' ', 'a', 0xE9, 0x1F600 }) |text| {
        try expectEqual(true, isTypedText(text));
    }
}

test "native_input: the wheel in notches, the mouse in logical pixels, buttons through the bridge's mapping" {
    try expectEqual(@as(f32, 1), wheelNotches(120));
    try expectEqual(@as(f32, -2), wheelNotches(-240));
    try expectEqual(@as(f32, 0.5), wheelNotches(60));
    try expectEqual(@as(f32, 200), logicalPixels(300, 1.5));
    const mapping = dom_input.mouseButtonFromDomButton;
    try expectEqual(@backingInt(types.MouseButton.left), mapping(@backingInt(DomButton.left)));
    try expectEqual(@backingInt(types.MouseButton.middle), mapping(@backingInt(DomButton.middle)));
    try expectEqual(@backingInt(types.MouseButton.right), mapping(@backingInt(DomButton.right)));
    try expectEqual(@backingInt(types.MouseButton.side), mapping(@backingInt(DomButton.back)));
}

/// A key message's parameter: the scancode's low byte in bits 16 to 23, bit 24 for an extended key, bit 30 for a
/// key already down.
fn keyParameter(scancode: u16, was_down: bool) win32.LPARAM {
    const scancode_bits: usize = @as(usize, scancode & 0xff) << 16;
    const extended_bit: usize = @as(usize, scancode >> 8) << 24;
    const was_down_bit: usize = @as(usize, @intFromBool(was_down)) << 30;
    return @bitCast(scancode_bits | extended_bit | was_down_bit);
}

/// A mouse message's parameter: x in the low word, y in the high one, each a signed 16-bit number.
fn mouseParameter(x: i16, y: i16) win32.LPARAM {
    const x_bits: usize = @as(u16, @bitCast(x));
    const y_bits: usize = @as(u16, @bitCast(y));
    return @bitCast(x_bits | (y_bits << 16));
}

fn translated(messages: []const win32.InputMessage) InputQueue {
    var queue: InputQueue = .{};
    for (messages) |message| {
        translate(message, &queue);
    }
    return queue;
}

test "native_input: key messages - physical keys, the extended bit, repeat, PrintScreen's lone release" {
    const queue: InputQueue = translated(&.{
        .{ .message = win32.WM_KEYDOWN, .w_param = 'A', .l_param = keyParameter(0x1E, false), .scale = 1 },
        .{ .message = win32.WM_KEYDOWN, .w_param = 'A', .l_param = keyParameter(0x1E, true), .scale = 1 },
        // 0x4B is the keypad's 4; extended, the left arrow.
        .{ .message = win32.WM_KEYDOWN, .w_param = 0, .l_param = keyParameter(0x4B, false), .scale = 1 },
        .{ .message = win32.WM_KEYDOWN, .w_param = 0, .l_param = keyParameter(0x14B, false), .scale = 1 },
        .{ .message = win32.WM_KEYUP, .w_param = win32.VK_SNAPSHOT, .l_param = keyParameter(0x137, true), .scale = 1 },
    });
    const events: []const InputEvent = queue.pending();
    try expectEqual(@as(usize, 6), events.len);
    try expectEqual(KeyDown{ .key = .a, .repeat = false }, events[0].key_down);
    try expectEqual(KeyDown{ .key = .a, .repeat = true }, events[1].key_down);
    try expectEqual(KeyboardKey.kp_4, events[2].key_down.key);
    try expectEqual(KeyboardKey.left, events[3].key_down.key);
    try expectEqual(KeyboardKey.print_screen, events[4].key_down.key);
    try expectEqual(KeyboardKey.print_screen, events[5].key_up);
}

test "native_input: PrintScreen gives one press and one release, whether or not Windows sent the press" {
    const release_alone: InputQueue = translated(&.{
        .{ .message = win32.WM_KEYUP, .w_param = win32.VK_SNAPSHOT, .l_param = keyParameter(0x137, true), .scale = 1 },
    });
    try expectEqual(@as(usize, 2), release_alone.pending().len);
    const press_and_release: InputQueue = translated(&.{
        .{
            .message = win32.WM_KEYDOWN,
            .w_param = win32.VK_SNAPSHOT,
            .l_param = keyParameter(0x137, false),
            .scale = 1,
        },
        .{ .message = win32.WM_KEYUP, .w_param = win32.VK_SNAPSHOT, .l_param = keyParameter(0x137, true), .scale = 1 },
    });
    const events: []const InputEvent = press_and_release.pending();
    try expectEqual(@as(usize, 2), events.len);
    try expectEqual(KeyboardKey.print_screen, events[0].key_down.key);
    try expectEqual(KeyboardKey.print_screen, events[1].key_up);
}

test "native_input: WM_CHAR pairs surrogates and leaves control characters out" {
    const queue: InputQueue = translated(&.{
        .{ .message = win32.WM_CHAR, .w_param = 0xD83D, .l_param = 0, .scale = 1 },
        .{ .message = win32.WM_CHAR, .w_param = 0xDE00, .l_param = 0, .scale = 1 },
        .{ .message = win32.WM_CHAR, .w_param = 0x08, .l_param = 0, .scale = 1 },
        .{ .message = win32.WM_CHAR, .w_param = 0xE9, .l_param = 0, .scale = 1 },
    });
    const events: []const InputEvent = queue.pending();
    try expectEqual(@as(usize, 2), events.len);
    try expectEqual(@as(u21, 0x1F600), events[0].character);
    try expectEqual(@as(u21, 0xE9), events[1].character);
}

test "native_input: mouse messages - logical pixels, negative when captured, the position before the button" {
    const x2_down: usize = @as(usize, win32.XBUTTON2) << 16;
    const wheel_toward_user: usize = @as(usize, @as(u16, @bitCast(@as(i16, -120)))) << 16;
    const queue: InputQueue = translated(&.{
        .{ .message = win32.WM_MOUSEMOVE, .w_param = 0, .l_param = mouseParameter(-10, 300), .scale = 2 },
        .{ .message = win32.WM_XBUTTONDOWN, .w_param = x2_down, .l_param = mouseParameter(40, 60), .scale = 2 },
        .{ .message = win32.WM_MOUSEWHEEL, .w_param = wheel_toward_user, .l_param = 0, .scale = 2 },
    });
    const events: []const InputEvent = queue.pending();
    try expectEqual(@as(usize, 4), events.len);
    try expectEqual(Position{ .x = -5, .y = 150 }, events[0].mouse_move);
    try expectEqual(Position{ .x = 20, .y = 30 }, events[1].mouse_move);
    try expectEqual(DomButton.forward, events[2].mouse_button_down);
    try expectEqual(WheelMovement{ .horizontal = 0, .vertical = -1 }, events[3].mouse_wheel);
}

test "native_input: the pointer entering and leaving become events, in order with the moves around them" {
    var queue: InputQueue = translated(&.{
        .{ .message = win32.message_pointer_entered, .w_param = 0, .l_param = 0, .scale = 1 },
        .{ .message = win32.WM_MOUSEMOVE, .w_param = 0, .l_param = mouseParameter(10, 20), .scale = 1 },
        .{ .message = win32.WM_MOUSELEAVE, .w_param = 0, .l_param = 0, .scale = 1 },
    });
    try expectEqual(@as(usize, 3), queue.pending().len);
    try expectEqual(InputEvent.mouse_enter, queue.pending()[0]);
    try expectEqual(Position{ .x = 10, .y = 20 }, queue.pending()[1].mouse_move);
    try expectEqual(InputEvent.mouse_leave, queue.pending()[2]);
    var converter: ContractEvents = .{};
    try expectEqual(contract.Event.mouse_enter, converter.convert(queue.pending()[0]));
    try expectEqual(contract.Event.mouse_leave, converter.convert(queue.pending()[2]));
}

test "native_input: a locked pointer's raw motion becomes a move that stays where the pointer was" {
    const left_three: win32.WPARAM = @bitCast(@as(isize, -6));
    var queue: InputQueue = translated(&.{
        .{ .message = win32.WM_MOUSEMOVE, .w_param = 0, .l_param = mouseParameter(40, 60), .scale = 2 },
        .{ .message = win32.message_pointer_lock_changed, .w_param = 1, .l_param = 0, .scale = 2 },
        .{ .message = win32.message_pointer_motion, .w_param = left_three, .l_param = 10, .scale = 2 },
        .{ .message = win32.message_pointer_lock_changed, .w_param = 0, .l_param = 0, .scale = 2 },
    });
    try expectEqual(@as(usize, 4), queue.pending().len);
    var converter: ContractEvents = .{};
    _ = converter.convert(queue.pending()[0]);
    try expectEqual(contract.Event{ .pointer_lock_changed = true }, converter.convert(queue.pending()[1]));
    const locked_move: contract.Event = converter.convert(queue.pending()[2]);
    try expectEqual(@as(f32, 20), locked_move.mouse_move.x);
    try expectEqual(@as(f32, 30), locked_move.mouse_move.y);
    try expectEqual(@as(f32, -3), locked_move.mouse_move.dx);
    try expectEqual(@as(f32, 5), locked_move.mouse_move.dy);
    try expectEqual(contract.Event{ .pointer_lock_changed = false }, converter.convert(queue.pending()[3]));
}

test "native_input: a paste carries its text through the queue to the contract's event" {
    var queue: InputQueue = translated(&.{
        .{ .message = win32.message_paste, .w_param = 0, .l_param = 0, .scale = 1, .text = "pasted text" },
    });
    try expectEqual(@as(usize, 1), queue.pending().len);
    var converter: ContractEvents = .{};
    const event: contract.Event = converter.convert(queue.pending()[0]);
    try expectEqualStrings("pasted text", event.paste.bytes);
}

test "native_input: focus gained and lost become events, in order with the keys around them" {
    var queue: InputQueue = translated(&.{
        .{ .message = win32.WM_KEYDOWN, .w_param = 'W', .l_param = keyParameter(0x11, false), .scale = 1 },
        .{ .message = win32.WM_KILLFOCUS, .w_param = 0, .l_param = 0, .scale = 1 },
        .{ .message = win32.WM_SETFOCUS, .w_param = 0, .l_param = 0, .scale = 1 },
    });
    try expectEqual(@as(usize, 3), queue.pending().len);
    try expectEqual(KeyboardKey.w, queue.pending()[0].key_down.key);
    try expectEqual(InputEvent.focus_lost, queue.pending()[1]);
    try expectEqual(InputEvent.focus_gained, queue.pending()[2]);
    var converter: ContractEvents = .{};
    try expectEqual(contract.Event.focus_lost, converter.convert(queue.pending()[1]));
    queue.clear();
    try expectEqual(@as(usize, 0), queue.pending().len);
}

test "native_input: the queue keeps order and drops control characters" {
    var queue: InputQueue = .{};
    queue.push(.{ .key_down = .{ .key = .a, .repeat = false } });
    queue.pushUtf16('a');
    queue.pushUtf16(0x08);
    queue.push(.{ .mouse_button_down = .left });
    try expectEqual(@as(usize, 3), queue.pending().len);
    try expectEqual(@as(u21, 'a'), queue.pending()[1].character);
    try expectEqual(DomButton.left, queue.pending()[2].mouse_button_down);
}

test "native_input: the contract's events - a button where the pointer last moved, a move's movement, text as UTF-8" {
    var converter: ContractEvents = .{};
    _ = converter.convert(.{ .mouse_move = .{ .x = 10, .y = 20 } });
    const moved: contract.Event = converter.convert(.{ .mouse_move = .{ .x = 13, .y = 16 } });
    try expectEqual(@as(f32, 3), moved.mouse_move.dx);
    try expectEqual(@as(f32, -4), moved.mouse_move.dy);
    const pressed: contract.Event = converter.convert(.{ .mouse_button_down = .right });
    try expectEqual(DomButton.right, pressed.mouse_button_down.button);
    try expectEqual(@as(f32, 13), pressed.mouse_button_down.x);
    const typed: contract.Event = converter.convert(.{ .character = 0xe9 });
    try expectEqualStrings("\u{e9}", typed.text.bytes);
}

test "native_input: a key going down carries what it types, as the window procedure read it from the layout" {
    // On a French keyboard the key in QWERTY's W position (scancode 0x11) types z.
    const queue: InputQueue = translated(&.{
        .{
            .message = win32.WM_KEYDOWN,
            .w_param = 'Z',
            .l_param = keyParameter(0x11, false),
            .scale = 1,
            .label = 'z',
        },
    });
    try expectEqual(KeyboardKey.w, queue.pending()[0].key_down.key);
    try expectEqual(@as(u21, 'z'), queue.pending()[0].key_down.label);
    var converter: ContractEvents = .{};
    try expectEqual(@as(u21, 'z'), converter.convert(queue.pending()[0]).key_down.label);
}

/// Parses `line` for a test, its strings from `arena`, failing it - with ZON's own explanation - when the line is not a
/// command.
fn parseForTest(arena: Allocator, line: []const u8) !Command {
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    return parseCommand(testing.allocator, arena, line, &diagnostics) catch |err| {
        if (err == error.ParseZon) {
            std.log.err("\"{s}\" is not a command: {f}", .{ line, diagnostics.fmt("line") });
        }
        return err;
    };
}

test "native_input: script lines are commands written in ZON" {
    var arena_state: ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    try expectEqual(Command{ .advance = 12 }, try parseForTest(arena, ".{ .advance = 12 }"));
    const moved: Command = try parseForTest(arena, ".{ .move = .{ .x = 240, .y = 121.5 } }");
    try expectEqual(Command{ .move = .{ .x = 240, .y = 121.5 } }, moved);
    try expectEqual(Command{ .press = .left }, try parseForTest(arena, ".{ .press = .left }"));
    try expectEqual(Command{ .wheel = .{ .dy = -2 } }, try parseForTest(arena, ".{ .wheel = .{ .dy = -2 } }"));
    try expectEqual(Command{ .key_down = .left_shift }, try parseForTest(arena, ".{ .key_down = .left_shift }"));
    try expectEqual(Command.capture, try parseForTest(arena, ".capture"));
    try expectEqual(Command.quit, try parseForTest(arena, ".quit // the end"));
    // A string is ZON's: escapes give a line break, or any character by its code point.
    const typed: Command = try parseForTest(arena, ".{ .text = \"two\\nlines \\u{e9}\" }");
    try expectEqualStrings("two\nlines \u{e9}", typed.text);
    const saved: Command = try parseForTest(arena, ".{ .capture_to = \"shots/a frame.png\" }");
    try expectEqualStrings("shots/a frame.png", saved.capture_to);
    const thumbnail_line: []const u8 = ".{ .capture_thumbnail = .{ .path = \"shots/t.png\", .width = 320 } }";
    const shrunk: Command = try parseForTest(arena, thumbnail_line);
    try expectEqualStrings("shots/t.png", shrunk.capture_thumbnail.path);
    try expectEqual(@as(u32, 320), shrunk.capture_thumbnail.width);
    try expect(isBlankLine("  // a comment\r"));
    try expect(!isBlankLine(".quit"));
}

test "native_input: a line that is not a command says where and why" {
    var arena_state: ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const thumb: []const u8 = ".{ .press = .thumb }";
    try testing.expectError(ParseError.ParseZon, parseCommand(testing.allocator, arena, thumb, &diagnostics));
    var message_bytes: [512]u8 = undefined;
    const message: []const u8 = try bufPrint(&message_bytes, "{f}", .{diagnostics.fmt("line")});
    try expect(indexOf(u8, message, "thumb") != null);
    var advance_diagnostics: std.zon.parse.Diagnostics = undefined;
    const far: []const u8 = ".{ .advance = 99999999 }";
    const too_many: ParseError!Command = parseCommand(testing.allocator, arena, far, &advance_diagnostics);
    try testing.expectError(ParseError.TooManyFrames, too_many);
}

test "native_input: a scripted person's events carry the pointer and the held modifiers" {
    var person: ScriptedPerson = .{};
    var events: [ScriptedPerson.most_events_per_command]contract.Event = undefined;
    // The first move enters the drawing area, then moves from its corner.
    const first_move: []const contract.Event = person.eventsFor(.{ .move = .{ .x = 30, .y = 40 } }, &events);
    try expectEqual(@as(usize, 2), first_move.len);
    try expectEqual(contract.Event.mouse_enter, first_move[0]);
    try expectEqual(@as(f32, 30), first_move[1].mouse_move.dx);
    const second_move: []const contract.Event = person.eventsFor(.{ .move = .{ .x = 35, .y = 40 } }, &events);
    try expectEqual(@as(usize, 1), second_move.len);
    try expectEqual(@as(f32, 5), second_move[0].mouse_move.dx);
    // Shift held: the press carries it, where the pointer is; once Shift is up, the release does not.
    _ = person.eventsFor(.{ .key_down = .left_shift }, &events);
    const pressed: contract.MouseButton = person.eventsFor(.{ .press = .left }, &events)[0].mouse_button_down;
    try expect(pressed.modifiers.shift);
    try expectEqual(@as(f32, 35), pressed.x);
    _ = person.eventsFor(.{ .key_up = .left_shift }, &events);
    try expect(!person.eventsFor(.{ .release = .left }, &events)[0].mouse_button_up.modifiers.shift);
    // Commands that draw or observe make no events.
    try expectEqual(@as(usize, 0), person.eventsFor(.{ .advance = 3 }, &events).len);
}

test "native_input: the paste command is Ctrl+V without Alt, or Shift+Insert" {
    try expect(isPasteCommand(.{ .key = .v, .repeat = false, .modifiers = .{ .control = true } }));
    try expect(!isPasteCommand(.{ .key = .v, .repeat = false, .modifiers = .{ .control = true, .alt = true } }));
    try expect(isPasteCommand(.{ .key = .insert, .repeat = false, .modifiers = .{ .shift = true } }));
    try expect(!isPasteCommand(.{ .key = .v, .repeat = false, .modifiers = .{} }));
}

test "native_input: an engine key's scancode is the one that names it" {
    try expectEqual(@as(?u16, 0x1E), scancodeOfEngineKey(.a));
    try expectEqual(@as(?u16, 0x11C), scancodeOfEngineKey(.kp_enter));
    try expectEqual(KeyboardKey.q, engineKeyFromScancode(scancodeOfEngineKey(.q).?).?);
}
