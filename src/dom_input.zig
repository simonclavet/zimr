//! lint:alias dom_input
//! src/dom_input.zig - the browser's key and mouse-button numbering, translated to raylib's.
//!
//! `src/bridge.zig` forwards DOM input events to the engine through the wasm's
//! `input_push_key_*` and `input_push_mouse_button_*` exports, and the engine indexes its key
//! and button arrays with those numbers directly - raylib's numbers, `types.KeyboardKey` and
//! `types.MouseButton`. The DOM counts differently:
//!
//!   * KEYS. The legacy `KeyboardEvent.keyCode` agrees with raylib only on letters, digits and
//!     space. Escape is 27 where raylib says 256, F1 is 112 against 290, ';' is 186 against 59 -
//!     and some land on the WRONG key: ArrowRight is 39, which is raylib's apostrophe. So the
//!     key comes from `KeyboardEvent.code` instead: the physical key's name ("KeyA",
//!     "ArrowRight") whatever the keyboard layout, which is GLFW's notion of a key and so
//!     raylib's on desktop. `.w` names the key above `.s` on AZERTY as on QWERTY.
//!   * MOUSE BUTTONS. The DOM counts main 0, auxiliary (the wheel) 1, secondary 2; raylib
//!     counts left 0, right 1, middle 2.
//!
//! raylib's own emscripten platform swaps the buttons the same way
//! (`src/platforms/rcore_web_emscripten.c:1444-1454`, raylib 5.6-dev) and still indexes keys
//! by `keyCode`, under a TODO saying they should be mapped (:1387).
//!
//! WHY A FILE OF ITS OWN, when bridge.zig is otherwise the whole browser side in one file:
//! bridge.zig cannot build for the host - its exports reach JavaScript externs - so nothing
//! inside it can be unit-tested. This file is pure (no externs, and `std` only in tests), so
//! the bridge imports it and `zig build test` checks it. Its one import, `types.zig`, is read
//! for two enums that need nothing else; the bridge's bare `build-obj` compile never analyses
//! the rest of that file, so it never needs the `zm` module.
//!
//! A Run step's cache sees only the files it is told about, so build.zig's `addBridgeSource`
//! declares both files as inputs of every bridge compile. An import added here or in
//! bridge.zig goes there too, or an edit to it leaves every page on the old zimr.js.

const std = @import("std");
const types = @import("types.zig");

const KeyboardKey = types.KeyboardKey;
const MouseButton = types.MouseButton;

/// One row of the key table: a `KeyboardEvent.code` and the raylib key it names.
const DomKey = struct {
    dom_code: []const u8,
    engine_key: KeyboardKey,
};

/// Every raylib key a browser reports, by its `KeyboardEvent.code` (the W3C "UI Events
/// KeyboardEvent code Values"), grouped by keyboard area. Absent, and so dropped by the bridge:
///
///   * keys raylib has no name for - F13 and up, IntlBackslash, the media and browser keys;
///   * raylib's four Android keys (`back`, `menu`, `volume_up`, `volume_down`). GLFW has no
///     such keys, so raylib on desktop never reports them either.
///
/// The last test below holds this table to exactly one row per raylib key.
///
/// A function rather than a table constant, and read only at comptime: Zig's C backend emits a
/// container-level constant into the bridge even when nothing reads it at run time, and this
/// one would be a hundred slices plus the strings they point at - about 3 KB of dead data on
/// every page. The lookup reads the packed copy below instead.
fn domKeyRows() []const DomKey {
    return &.{
        // Letters and digits: the only keys whose keyCode already matched raylib.
        .{ .dom_code = "KeyA", .engine_key = .a },
        .{ .dom_code = "KeyB", .engine_key = .b },
        .{ .dom_code = "KeyC", .engine_key = .c },
        .{ .dom_code = "KeyD", .engine_key = .d },
        .{ .dom_code = "KeyE", .engine_key = .e },
        .{ .dom_code = "KeyF", .engine_key = .f },
        .{ .dom_code = "KeyG", .engine_key = .g },
        .{ .dom_code = "KeyH", .engine_key = .h },
        .{ .dom_code = "KeyI", .engine_key = .i },
        .{ .dom_code = "KeyJ", .engine_key = .j },
        .{ .dom_code = "KeyK", .engine_key = .k },
        .{ .dom_code = "KeyL", .engine_key = .l },
        .{ .dom_code = "KeyM", .engine_key = .m },
        .{ .dom_code = "KeyN", .engine_key = .n },
        .{ .dom_code = "KeyO", .engine_key = .o },
        .{ .dom_code = "KeyP", .engine_key = .p },
        .{ .dom_code = "KeyQ", .engine_key = .q },
        .{ .dom_code = "KeyR", .engine_key = .r },
        .{ .dom_code = "KeyS", .engine_key = .s },
        .{ .dom_code = "KeyT", .engine_key = .t },
        .{ .dom_code = "KeyU", .engine_key = .u },
        .{ .dom_code = "KeyV", .engine_key = .v },
        .{ .dom_code = "KeyW", .engine_key = .w },
        .{ .dom_code = "KeyX", .engine_key = .x },
        .{ .dom_code = "KeyY", .engine_key = .y },
        .{ .dom_code = "KeyZ", .engine_key = .z },
        .{ .dom_code = "Digit0", .engine_key = .zero },
        .{ .dom_code = "Digit1", .engine_key = .one },
        .{ .dom_code = "Digit2", .engine_key = .two },
        .{ .dom_code = "Digit3", .engine_key = .three },
        .{ .dom_code = "Digit4", .engine_key = .four },
        .{ .dom_code = "Digit5", .engine_key = .five },
        .{ .dom_code = "Digit6", .engine_key = .six },
        .{ .dom_code = "Digit7", .engine_key = .seven },
        .{ .dom_code = "Digit8", .engine_key = .eight },
        .{ .dom_code = "Digit9", .engine_key = .nine },
        // Punctuation, named for where it sits on a US keyboard.
        .{ .dom_code = "Backquote", .engine_key = .grave },
        .{ .dom_code = "Minus", .engine_key = .minus },
        .{ .dom_code = "Equal", .engine_key = .equal },
        .{ .dom_code = "BracketLeft", .engine_key = .left_bracket },
        .{ .dom_code = "BracketRight", .engine_key = .right_bracket },
        .{ .dom_code = "Backslash", .engine_key = .backslash },
        .{ .dom_code = "Semicolon", .engine_key = .semicolon },
        .{ .dom_code = "Quote", .engine_key = .apostrophe },
        .{ .dom_code = "Comma", .engine_key = .comma },
        .{ .dom_code = "Period", .engine_key = .period },
        .{ .dom_code = "Slash", .engine_key = .slash },
        // Whitespace and editing.
        .{ .dom_code = "Space", .engine_key = .space },
        .{ .dom_code = "Escape", .engine_key = .escape },
        .{ .dom_code = "Enter", .engine_key = .enter },
        .{ .dom_code = "Tab", .engine_key = .tab },
        .{ .dom_code = "Backspace", .engine_key = .backspace },
        .{ .dom_code = "Insert", .engine_key = .insert },
        .{ .dom_code = "Delete", .engine_key = .delete },
        .{ .dom_code = "Home", .engine_key = .home },
        .{ .dom_code = "End", .engine_key = .end },
        .{ .dom_code = "PageUp", .engine_key = .page_up },
        .{ .dom_code = "PageDown", .engine_key = .page_down },
        // Arrows.
        .{ .dom_code = "ArrowRight", .engine_key = .right },
        .{ .dom_code = "ArrowLeft", .engine_key = .left },
        .{ .dom_code = "ArrowDown", .engine_key = .down },
        .{ .dom_code = "ArrowUp", .engine_key = .up },
        // The function row, and the lock and print keys.
        .{ .dom_code = "F1", .engine_key = .f1 },
        .{ .dom_code = "F2", .engine_key = .f2 },
        .{ .dom_code = "F3", .engine_key = .f3 },
        .{ .dom_code = "F4", .engine_key = .f4 },
        .{ .dom_code = "F5", .engine_key = .f5 },
        .{ .dom_code = "F6", .engine_key = .f6 },
        .{ .dom_code = "F7", .engine_key = .f7 },
        .{ .dom_code = "F8", .engine_key = .f8 },
        .{ .dom_code = "F9", .engine_key = .f9 },
        .{ .dom_code = "F10", .engine_key = .f10 },
        .{ .dom_code = "F11", .engine_key = .f11 },
        .{ .dom_code = "F12", .engine_key = .f12 },
        .{ .dom_code = "CapsLock", .engine_key = .caps_lock },
        .{ .dom_code = "ScrollLock", .engine_key = .scroll_lock },
        .{ .dom_code = "NumLock", .engine_key = .num_lock },
        .{ .dom_code = "PrintScreen", .engine_key = .print_screen },
        .{ .dom_code = "Pause", .engine_key = .pause },
        // Modifiers, one per side, and the menu key.
        .{ .dom_code = "ShiftLeft", .engine_key = .left_shift },
        .{ .dom_code = "ControlLeft", .engine_key = .left_control },
        .{ .dom_code = "AltLeft", .engine_key = .left_alt },
        .{ .dom_code = "MetaLeft", .engine_key = .left_super },
        .{ .dom_code = "ShiftRight", .engine_key = .right_shift },
        .{ .dom_code = "ControlRight", .engine_key = .right_control },
        .{ .dom_code = "AltRight", .engine_key = .right_alt },
        .{ .dom_code = "MetaRight", .engine_key = .right_super },
        .{ .dom_code = "ContextMenu", .engine_key = .kb_menu },
        // The keypad: keys of its own, not the top-row digits.
        .{ .dom_code = "Numpad0", .engine_key = .kp_0 },
        .{ .dom_code = "Numpad1", .engine_key = .kp_1 },
        .{ .dom_code = "Numpad2", .engine_key = .kp_2 },
        .{ .dom_code = "Numpad3", .engine_key = .kp_3 },
        .{ .dom_code = "Numpad4", .engine_key = .kp_4 },
        .{ .dom_code = "Numpad5", .engine_key = .kp_5 },
        .{ .dom_code = "Numpad6", .engine_key = .kp_6 },
        .{ .dom_code = "Numpad7", .engine_key = .kp_7 },
        .{ .dom_code = "Numpad8", .engine_key = .kp_8 },
        .{ .dom_code = "Numpad9", .engine_key = .kp_9 },
        .{ .dom_code = "NumpadDecimal", .engine_key = .kp_decimal },
        .{ .dom_code = "NumpadDivide", .engine_key = .kp_divide },
        .{ .dom_code = "NumpadMultiply", .engine_key = .kp_multiply },
        .{ .dom_code = "NumpadSubtract", .engine_key = .kp_subtract },
        .{ .dom_code = "NumpadAdd", .engine_key = .kp_add },
        .{ .dom_code = "NumpadEnter", .engine_key = .kp_enter },
        .{ .dom_code = "NumpadEqual", .engine_key = .kp_equal },
    };
}

const dom_key_count: usize = domKeyRows().len;

/// The longest code in the table. A longer one cannot name a raylib key, so the bridge reads
/// `KeyboardEvent.code` into a buffer of exactly this many bytes and drops anything longer.
pub const longest_dom_code_length: usize = longest: {
    var longest_so_far: usize = 0;
    for (domKeyRows()) |dom_key| {
        longest_so_far = @max(longest_so_far, dom_key.dom_code.len);
    }
    break :longest longest_so_far;
};

// ===== the table as the lookup reads it =====
//
// The rows are a hundred slices, and a slice in a data image is a POINTER: c2js relocates
// those, but its corpus only proves it for `var` globals. So the lookup reads the table packed
// into plain bytes and integers, the shape every string literal in the bridge already has.
// (Unrolling the lookup over the rows with `inline for` avoided the pointers too, and cost the
// bridge 51 KB of JavaScript.)

const total_dom_code_bytes: usize = total: {
    var byte_count: usize = 0;
    for (domKeyRows()) |dom_key| {
        byte_count += dom_key.dom_code.len;
    }
    break :total byte_count;
};

/// Every row's code, back to back in table order.
const packed_dom_codes: [total_dom_code_bytes]u8 = codes: {
    var all_codes: []const u8 = "";
    for (domKeyRows()) |dom_key| {
        all_codes = all_codes ++ dom_key.dom_code;
    }
    break :codes all_codes[0..total_dom_code_bytes].*;
};

/// Where each row's code ends in `packed_dom_codes`; the next row's starts there.
const packed_code_ends: [dom_key_count]u16 = ends: {
    var code_ends: [dom_key_count]u16 = undefined;
    var code_end: usize = 0;
    for (domKeyRows(), 0..) |dom_key, row_index| {
        code_end += dom_key.dom_code.len;
        code_ends[row_index] = @intCast(code_end);
    }
    break :ends code_ends;
};

/// Each row's key, in table order.
const packed_engine_keys: [dom_key_count]KeyboardKey = keys: {
    var engine_keys: [dom_key_count]KeyboardKey = undefined;
    for (domKeyRows(), 0..) |dom_key, row_index| {
        engine_keys[row_index] = dom_key.engine_key;
    }
    break :keys engine_keys;
};

/// The raylib key a `KeyboardEvent.code` names, or null for a key raylib has no name for.
pub fn keyboardKeyFromDomCode(dom_code: []const u8) ?KeyboardKey {
    // Through slices, not the arrays themselves: Zig's C backend passes a const array used BY
    // VALUE as its whole contents, which c2js rewrites into memory on every iteration.
    const code_ends: []const u16 = &packed_code_ends;
    const engine_keys: []const KeyboardKey = &packed_engine_keys;
    var code_start: usize = 0;
    for (code_ends, engine_keys) |code_end, engine_key| {
        const table_code: []const u8 = packed_dom_codes[code_start..code_end];
        if (sameBytes(dom_code, table_code)) {
            return engine_key;
        }
        code_start = code_end;
    }
    return null;
}

/// Byte-for-byte equality. Hand-written rather than `std.mem.eql` because the bridge compiles
/// without std, and this keeps it that way.
fn sameBytes(first: []const u8, second: []const u8) bool {
    const lengths_differ: bool = first.len != second.len;
    if (lengths_differ) {
        return false;
    }
    for (first, second) |first_byte, second_byte| {
        if (first_byte != second_byte) {
            return false;
        }
    }
    return true;
}

/// `MouseEvent.button` as the DOM numbers it, under the UI Events spec's names.
const DomButton = struct {
    /// Usually the left button.
    const main: i32 = 0;
    /// Usually the wheel, pressed.
    const auxiliary: i32 = 1;
    /// Usually the right button.
    const secondary: i32 = 2;
    /// Usually the thumb button the browser treats as Back.
    const fourth: i32 = 3;
    /// Usually the thumb button the browser treats as Forward.
    const fifth: i32 = 4;
};

/// raylib's number for a DOM `MouseEvent.button`. Only the middle and right buttons move: the
/// DOM calls the wheel 1 and the right button 2, raylib the other way round. The thumb buttons
/// already agree - DOM 3 and 4 are GLFW's fourth and fifth buttons, which raylib on desktop
/// stores as `side` and `extra` - and any other value (-1 for "no button changed", 5 for a
/// pen's eraser) passes through unchanged, for `pushMouseButtonDown`'s range check to judge
/// exactly as before.
pub fn mouseButtonFromDomButton(dom_button: i32) i32 {
    return switch (dom_button) {
        DomButton.main => @backingInt(MouseButton.left),
        DomButton.auxiliary => @backingInt(MouseButton.middle),
        DomButton.secondary => @backingInt(MouseButton.right),
        DomButton.fourth => @backingInt(MouseButton.side),
        DomButton.fifth => @backingInt(MouseButton.extra),
        else => dom_button,
    };
}

// ===== tests =====

const expectEqual = std.testing.expectEqual;

/// raylib's number for the key a DOM code names, or null: exactly what the bridge sends.
fn raylibNumberFor(dom_code: []const u8) ?i32 {
    const engine_key: ?KeyboardKey = keyboardKeyFromDomCode(dom_code);
    return if (engine_key) |key| @backingInt(key) else null;
}

/// Check one translation, naming the code if it is wrong. The expected numbers in these tests
/// are copied from raylib.h's `KEY_*` values rather than read from `types.KeyboardKey`, so the
/// table AND the enum are checked against raylib itself.
fn expectRaylibNumber(dom_code: []const u8, raylib_number: ?i32) !void {
    errdefer std.log.warn("dom_input: KeyboardEvent.code \"{s}\"", .{dom_code});
    try expectEqual(raylib_number, raylibNumberFor(dom_code));
}

/// A DOM code and the number raylib.h gives its key - null where raylib has no such key.
const ExpectedKey = struct {
    dom_code: []const u8,
    raylib_number: ?i32,
};

fn expectRaylibNumbers(expected_keys: []const ExpectedKey) !void {
    for (expected_keys) |expected_key| {
        try expectRaylibNumber(expected_key.dom_code, expected_key.raylib_number);
    }
}

test "dom_input: every letter and digit keeps the number keyCode already had" {
    // raylib's KEY_A..KEY_Z and KEY_ZERO..KEY_NINE are the ASCII codes of 'A'..'Z' and
    // '0'..'9', so these expectations are computed, not read from the table.
    inline for ("ABCDEFGHIJKLMNOPQRSTUVWXYZ") |letter| {
        try expectRaylibNumber(std.fmt.comptimePrint("Key{c}", .{letter}), letter);
    }
    inline for ("0123456789") |digit| {
        try expectRaylibNumber(std.fmt.comptimePrint("Digit{c}", .{digit}), digit);
    }
    try expectRaylibNumber("Space", 32);
}

test "dom_input: escape, enter, tab, backspace and the editing keys reach 256-269" {
    const expected_keys = [_]ExpectedKey{
        .{ .dom_code = "Escape", .raylib_number = 256 },
        .{ .dom_code = "Enter", .raylib_number = 257 },
        .{ .dom_code = "Tab", .raylib_number = 258 },
        .{ .dom_code = "Backspace", .raylib_number = 259 },
        .{ .dom_code = "Insert", .raylib_number = 260 },
        .{ .dom_code = "Delete", .raylib_number = 261 },
        .{ .dom_code = "PageUp", .raylib_number = 266 },
        .{ .dom_code = "PageDown", .raylib_number = 267 },
        .{ .dom_code = "Home", .raylib_number = 268 },
        .{ .dom_code = "End", .raylib_number = 269 },
    };
    try expectRaylibNumbers(&expected_keys);
}

test "dom_input: the arrows reach 262-265, so ArrowRight is no longer the apostrophe" {
    const expected_keys = [_]ExpectedKey{
        .{ .dom_code = "ArrowRight", .raylib_number = 262 },
        .{ .dom_code = "ArrowLeft", .raylib_number = 263 },
        .{ .dom_code = "ArrowDown", .raylib_number = 264 },
        .{ .dom_code = "ArrowUp", .raylib_number = 265 },
        // keyCode 39 was both ArrowRight and raylib's KEY_APOSTROPHE; by code they are two keys.
        .{ .dom_code = "Quote", .raylib_number = 39 },
    };
    try expectRaylibNumbers(&expected_keys);
}

test "dom_input: F1-F12 reach 290-301, and the lock and print keys 280-284" {
    const raylib_key_f1: i32 = 290;
    inline for (0..12) |offset_from_f1| {
        const dom_code: []const u8 = std.fmt.comptimePrint("F{d}", .{offset_from_f1 + 1});
        try expectRaylibNumber(dom_code, raylib_key_f1 + offset_from_f1);
    }
    const expected_keys = [_]ExpectedKey{
        .{ .dom_code = "CapsLock", .raylib_number = 280 },
        .{ .dom_code = "ScrollLock", .raylib_number = 281 },
        .{ .dom_code = "NumLock", .raylib_number = 282 },
        .{ .dom_code = "PrintScreen", .raylib_number = 283 },
        .{ .dom_code = "Pause", .raylib_number = 284 },
    };
    try expectRaylibNumbers(&expected_keys);
}

test "dom_input: punctuation follows the physical key" {
    // keyCode put most of these at 186 and up, where raylib has no keys at all.
    const expected_keys = [_]ExpectedKey{
        .{ .dom_code = "Quote", .raylib_number = 39 },
        .{ .dom_code = "Comma", .raylib_number = 44 },
        .{ .dom_code = "Minus", .raylib_number = 45 },
        .{ .dom_code = "Period", .raylib_number = 46 },
        .{ .dom_code = "Slash", .raylib_number = 47 },
        .{ .dom_code = "Semicolon", .raylib_number = 59 },
        .{ .dom_code = "Equal", .raylib_number = 61 },
        .{ .dom_code = "BracketLeft", .raylib_number = 91 },
        .{ .dom_code = "Backslash", .raylib_number = 92 },
        .{ .dom_code = "BracketRight", .raylib_number = 93 },
        .{ .dom_code = "Backquote", .raylib_number = 96 },
    };
    try expectRaylibNumbers(&expected_keys);
}

test "dom_input: the modifiers and the menu key reach 340-348" {
    const expected_keys = [_]ExpectedKey{
        .{ .dom_code = "ShiftLeft", .raylib_number = 340 },
        .{ .dom_code = "ControlLeft", .raylib_number = 341 },
        .{ .dom_code = "AltLeft", .raylib_number = 342 },
        .{ .dom_code = "MetaLeft", .raylib_number = 343 },
        .{ .dom_code = "ShiftRight", .raylib_number = 344 },
        .{ .dom_code = "ControlRight", .raylib_number = 345 },
        .{ .dom_code = "AltRight", .raylib_number = 346 },
        .{ .dom_code = "MetaRight", .raylib_number = 347 },
        .{ .dom_code = "ContextMenu", .raylib_number = 348 },
    };
    try expectRaylibNumbers(&expected_keys);
}

test "dom_input: the keypad has keys of its own, 320-336" {
    const raylib_key_kp_0: i32 = 320;
    inline for ("0123456789", 0..) |digit, offset_from_kp_0| {
        const dom_code: []const u8 = std.fmt.comptimePrint("Numpad{c}", .{digit});
        try expectRaylibNumber(dom_code, raylib_key_kp_0 + offset_from_kp_0);
    }
    const expected_keys = [_]ExpectedKey{
        .{ .dom_code = "NumpadDecimal", .raylib_number = 330 },
        .{ .dom_code = "NumpadDivide", .raylib_number = 331 },
        .{ .dom_code = "NumpadMultiply", .raylib_number = 332 },
        .{ .dom_code = "NumpadSubtract", .raylib_number = 333 },
        .{ .dom_code = "NumpadAdd", .raylib_number = 334 },
        .{ .dom_code = "NumpadEnter", .raylib_number = 335 },
        .{ .dom_code = "NumpadEqual", .raylib_number = 336 },
    };
    try expectRaylibNumbers(&expected_keys);
}

test "dom_input: a code raylib has no key for translates to null" {
    const expected_keys = [_]ExpectedKey{
        .{ .dom_code = "", .raylib_number = null },
        .{ .dom_code = "Unidentified", .raylib_number = null },
        .{ .dom_code = "F13", .raylib_number = null },
        .{ .dom_code = "IntlBackslash", .raylib_number = null },
        .{ .dom_code = "AudioVolumeUp", .raylib_number = null },
        .{ .dom_code = "BrowserBack", .raylib_number = null },
        // Codes are case-sensitive and whole: no prefix, suffix or near miss matches.
        .{ .dom_code = "keya", .raylib_number = null },
        .{ .dom_code = "Key", .raylib_number = null },
        .{ .dom_code = "KeyAA", .raylib_number = null },
        .{ .dom_code = "NumpadMultiplyX", .raylib_number = null },
    };
    try expectRaylibNumbers(&expected_keys);
}

test "dom_input: DOM mouse buttons 1 and 2 swap, and every other value passes through" {
    // raylib.h: MOUSE_BUTTON_LEFT 0, RIGHT 1, MIDDLE 2, SIDE 3, EXTRA 4.
    const ButtonCase = struct { dom_button: i32, raylib_button: i32 };
    const cases = [_]ButtonCase{
        .{ .dom_button = 0, .raylib_button = 0 },
        .{ .dom_button = 1, .raylib_button = 2 },
        .{ .dom_button = 2, .raylib_button = 1 },
        .{ .dom_button = 3, .raylib_button = 3 },
        .{ .dom_button = 4, .raylib_button = 4 },
        .{ .dom_button = -1, .raylib_button = -1 },
        .{ .dom_button = 5, .raylib_button = 5 },
    };
    for (cases) |case| {
        errdefer std.log.warn("dom_input: MouseEvent.button {d}", .{case.dom_button});
        try expectEqual(case.raylib_button, mouseButtonFromDomButton(case.dom_button));
    }
}

test "dom_input: every raylib key has exactly one DOM code, except Android's four" {
    // Walks the ENUM, so a key added to types.KeyboardKey fails here until it gets a row or
    // joins the exclusions below.
    const android_only_keys = [_]KeyboardKey{ .back, .menu, .volume_up, .volume_down };
    const table_rows: []const DomKey = domKeyRows();
    inline for (@typeInfo(KeyboardKey).@"enum".field_names) |key_name| {
        const key: KeyboardKey = @field(KeyboardKey, key_name);
        var rows_naming_key: usize = 0;
        for (table_rows) |dom_key| {
            if (dom_key.engine_key == key) {
                rows_naming_key += 1;
            }
        }
        const key_is_android_only: bool = std.mem.indexOfScalar(KeyboardKey, &android_only_keys, key) != null;
        const key_needs_no_row: bool = key == .null or key_is_android_only;
        const expected_rows: usize = if (key_needs_no_row) 0 else 1;
        errdefer std.log.warn("dom_input: KeyboardKey.{s} is named by {d} rows", .{ key_name, rows_naming_key });
        try expectEqual(expected_rows, rows_naming_key);
    }
    // And no code appears twice: a second row for the same code could never be reached.
    for (table_rows) |dom_key| {
        var rows_with_code: usize = 0;
        for (table_rows) |other_dom_key| {
            if (sameBytes(dom_key.dom_code, other_dom_key.dom_code)) {
                rows_with_code += 1;
            }
        }
        errdefer std.log.warn("dom_input: code \"{s}\" is in {d} rows", .{ dom_key.dom_code, rows_with_code });
        try expectEqual(@as(usize, 1), rows_with_code);
    }
}
