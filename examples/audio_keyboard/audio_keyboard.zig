//! examples/audio_keyboard - a playable keyboard: seventeen keys, from middle C to the E an octave and a third above,
//! played with the computer keyboard or the pointer, sounded by the mixer's instrument (`z.mixer.sine_instrument`).
//!
//! The computer keyboard is laid out as music programs lay it out: the middle row is the white keys, the row above it
//! the black keys between them.
//!
//!          W   E       T   Y   U       O   P
//!        A   S   D   F   G   H   J   K   L   ;
//!        C   D   E   F   G   A   B   C   D   E
//!
//! A key's note goes to the instrument as a note event (`Mixer.sendNote`) - a key down starts it, a key up releases
//! it - and the renderer starts it at its next block. The events are read at the app's frame here; the latency plan
//! moves them off the frame path. In a page, the browser keeps the sound silent until the first click or key press.
const std = @import("std");
const Allocator = std.mem.Allocator;
const indexOfScalar = std.mem.indexOfScalar;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const Vec2 = zm.Vec2;
const float = zm.float;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const background: Color = .{ .r = 24, .g = 26, .b = 34, .a = 255 };
const text_color: Color = .{ .r = 230, .g = 230, .b = 235, .a = 255 };
const white_key_color: Color = .{ .r = 236, .g = 236, .b = 240, .a = 255 };
const black_key_color: Color = .{ .r = 30, .g = 30, .b = 36, .a = 255 };
const held_key_color: Color = .{ .r = 255, .g = 170, .b = 60, .a = 255 };
const key_outline_color: Color = .{ .r = 90, .g = 94, .b = 110, .a = 255 };

/// The lowest note: MIDI key 60, middle C.
const lowest_key: u8 = 60;
/// The computer keys that play the notes, one semitone each from `lowest_key` up.
const note_keys = [_]z.KeyboardKey{ .a, .w, .s, .e, .d, .f, .t, .g, .y, .h, .u, .j, .k, .o, .l, .p, .semicolon };
const note_count: usize = note_keys.len;

/// Whether each semitone of an octave, from C, is a black key: C# D# F# G# A#.
const is_black_in_octave = [12]bool{ false, true, false, true, false, false, true, false, true, false, true, false };

/// Where a note's key is drawn: black or white, and the white key it sits on or to the right of.
const KeyPlace = struct {
    is_black: bool,
    white_index: usize,
};

/// Each note's place on the drawn keyboard: a white key takes the next white place; a black key sits over the gap to
/// the right of the white key before it.
fn keyPlaces() [note_count]KeyPlace {
    var places: [note_count]KeyPlace = undefined;
    var white_count: usize = 0;
    for (&places, 0..) |*place, note_index| {
        const is_black: bool = is_black_in_octave[note_index % 12];
        if (is_black) {
            place.* = .{ .is_black = true, .white_index = white_count - 1 };
        } else {
            place.* = .{ .is_black = false, .white_index = white_count };
            white_count += 1;
        }
    }
    return places;
}
const key_places: [note_count]KeyPlace = keyPlaces();
const white_key_count: usize = 10;

const State = struct {
    font: z.Font,
    /// Which notes the computer keyboard holds down.
    held_by_keyboard: [note_count]bool,
    /// The note the pointer holds down, while it does.
    held_by_pointer: ?usize,
    /// Whether presses and releases arrive through `onInput` (`AppSpec.on_input`): set at its first call. Until then
    /// - and in a launcher that does not call it - each frame reads the computer keyboard instead.
    is_input_from_events: bool,
    notes_started: u32,
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 16);
    s.* = .{
        .font = font,
        .held_by_keyboard = @splat(false),
        .held_by_pointer = null,
        .is_input_from_events = false,
        .notes_started = 0,
    };
    z.audio_device.init(f.audio_device);
    // The page's sound diagnostics, at its top: the path that plays, and the renderer's own reports.
    z.audio_device.showDiagnostics(f.audio_device);
    f.mixer.setInstrument(z.mixer.sine_instrument);
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

/// Sends a note's key going down or up to the instrument.
fn sendNote(
    f: *z.Frame,
    s: *State,
    note_index: usize,
    is_down: bool,
    pressed_at_ms: f64,
) void {
    const key: u8 = lowest_key + @as(u8, @intCast(note_index));
    // The press's own time, when there is one, so that the readout measures the note's lag from the press.
    const note: z.mixer.NoteEvent = .{
        .key = key,
        .is_down = is_down,
        .velocity = 0.5,
        .pressed_at_ms = pressed_at_ms,
    };
    const is_sent: bool = f.mixer.sendNote(note);
    if (is_sent and is_down) {
        s.notes_started += 1;
    }
}

/// The keyboard's rectangle in the window: the window's width less a margin, and a third of its height.
const Layout = struct {
    left: f32,
    top: f32,
    white_width: f32,
    white_height: f32,

    fn ofWindow(f: *z.Frame) Layout {
        const margin: f32 = 24;
        const keyboard_width: f32 = f.window.widthf() - 2 * margin;
        const white_width: f32 = keyboard_width / float(white_key_count);
        return .{ .left = margin, .top = 96, .white_width = white_width, .white_height = white_width * 3.5 };
    }

    fn keyRect(layout: Layout, note_index: usize) z.Rectangle {
        const place: KeyPlace = key_places[note_index];
        const white_left: f32 = layout.left + float(place.white_index) * layout.white_width;
        if (!place.is_black) {
            return .{ .x = white_left, .y = layout.top, .width = layout.white_width, .height = layout.white_height };
        }
        const black_width: f32 = layout.white_width * 0.6;
        const black_left: f32 = white_left + layout.white_width - black_width / 2;
        return .{ .x = black_left, .y = layout.top, .width = black_width, .height = layout.white_height * 0.62 };
    }
};

fn isInside(point: Vec2, rect: z.Rectangle) bool {
    const is_inside_x: bool = point[0] >= rect.x and point[0] < rect.x + rect.width;
    const is_inside_y: bool = point[1] >= rect.y and point[1] < rect.y + rect.height;
    return is_inside_x and is_inside_y;
}

/// The note under the pointer: a black key first, since it is drawn over the white ones.
fn noteUnderPointer(layout: Layout, pointer: Vec2) ?usize {
    for (0..note_count) |note_index| {
        if (key_places[note_index].is_black and isInside(pointer, layout.keyRect(note_index))) {
            return note_index;
        }
    }
    for (0..note_count) |note_index| {
        if (!key_places[note_index].is_black and isInside(pointer, layout.keyRect(note_index))) {
            return note_index;
        }
    }
    return null;
}

/// The computer keyboard, read each frame while presses do not arrive as events (`is_input_from_events`): a key
/// pressed this frame starts its note; a key held until now and no longer down releases it.
fn readComputerKeyboard(f: *z.Frame, s: *State) void {
    for (note_keys, 0..) |note_key, note_index| {
        if (z.isKeyPressed(f.input, note_key)) {
            s.held_by_keyboard[note_index] = true;
            sendNote(f, s, note_index, true, z.getKeyPressTime(f.input, note_key));
        } else if (s.held_by_keyboard[note_index] and !z.isKeyDown(f.input, note_key)) {
            s.held_by_keyboard[note_index] = false;
            sendNote(f, s, note_index, false, 0);
        }
    }
}

/// The pointer: pressed on a key, it starts the key's note; moved onto another key while down, it releases the first
/// and starts the second, as a finger sliding along a keyboard; let go, it releases its note.
fn readPointer(f: *z.Frame, s: *State, layout: Layout) void {
    const pointer: Vec2 = z.getMousePosition(f.input);
    const is_down: bool = z.isMouseButtonDown(f.input, .left);
    const note_now: ?usize = if (is_down) noteUnderPointer(layout, pointer) else null;
    if (note_now == s.held_by_pointer) {
        return;
    }
    if (s.held_by_pointer) |released_note| {
        sendNote(f, s, released_note, false, 0);
    }
    if (note_now) |started_note| {
        // A note started by the press itself carries its time; one a finger slides onto has no press behind it.
        const is_new_press: bool = z.isMouseButtonPressed(f.input, .left);
        const pressed_at_ms: f64 = if (is_new_press) z.getLastPressTime(f.input) else 0;
        sendNote(f, s, started_note, true, pressed_at_ms);
    }
    s.held_by_pointer = note_now;
}

/// The note `key` plays, or null for a key that plays none.
fn noteOfKey(key: z.KeyboardKey) ?usize {
    return indexOfScalar(z.KeyboardKey, &note_keys, key);
}

/// A press or release, the moment it arrives (`AppSpec.on_input`): a note key's press starts its note and its release
/// ends it, and the pointer's press or release does the same for the key under it - the sound asked for now, not at
/// the next frame. The pointer gliding onto another key while held is read each frame (`readPointer`).
fn onInput(f: *z.Frame, s: *State, event: z.InputEvent) void {
    s.is_input_from_events = true;
    switch (event) {
        .key_down => |down| {
            const note_index: usize = noteOfKey(down.key) orelse return;
            if (down.repeat or s.held_by_keyboard[note_index]) {
                return;
            }
            s.held_by_keyboard[note_index] = true;
            sendNote(f, s, note_index, true, z.getKeyPressTime(f.input, down.key));
        },
        .key_up => |up| {
            const note_index: usize = noteOfKey(up.key) orelse return;
            if (!s.held_by_keyboard[note_index]) {
                return;
            }
            s.held_by_keyboard[note_index] = false;
            sendNote(f, s, note_index, false, 0);
        },
        .mouse_button_down, .mouse_button_up, .touch_begin, .touch_end => readPointer(f, s, .ofWindow(f)),
        else => {},
    }
}

fn drawKey(f: *z.Frame, s: *State, layout: Layout, note_index: usize) void {
    const is_held: bool = s.held_by_keyboard[note_index] or s.held_by_pointer == note_index;
    const resting_color: Color = if (key_places[note_index].is_black) black_key_color else white_key_color;
    const fill: Color = if (is_held) held_key_color else resting_color;
    const rect: z.Rectangle = layout.keyRect(note_index);
    f.gl.rect(rect, .{ .color = fill });
    f.gl.rect(rect, .{ .color = key_outline_color, .outline = 1.0 });
}

/// The latency readout: the output that plays, then the last five starts the mixer measured, newest first - the wait
/// for the renderer, the sound queued ahead of the note, what lies past the output, and their sum
/// (`z.mixer.Mixer.formatLatencyLine`). Its lines start at `top`.
fn drawLatencyReadout(f: *z.Frame, s: *State, top: f32) void {
    f.gl.textf(
        .{ 24, top },
        "output: {s}",
        .{f.mixer.outputName()},
        .{ .size = 15, .color = text_color, .font = &s.font },
    );
    const readout_header: []const u8 = z.mixer.Mixer.latency_readout_header;
    f.gl.text(.{ 24, top + 22 }, readout_header, .{ .size = 15, .color = text_color, .font = &s.font });
    var recent: [z.mixer.recent_start_capacity]z.mixer.LatencySample = undefined;
    const measured: []z.mixer.LatencySample = f.mixer.recentStarts(&recent);
    const past_output_ms: f64 = f.mixer.outputLatencyMilliseconds();
    const shown_count: usize = @min(measured.len, 5);
    for (measured[0..shown_count], 0..) |latency_sample, line_index| {
        var line_buffer: [96]u8 = undefined;
        const line: []const u8 = z.mixer.Mixer.formatLatencyLine(latency_sample, past_output_ms, &line_buffer);
        const line_top: f32 = top + 44 + float(line_index) * 22;
        f.gl.text(.{ 24, line_top }, line, .{ .size = 15, .color = text_color, .font = &s.font });
    }
}

fn draw(f: *z.Frame, s: *State, layout: Layout) void {
    z.clearViewport(f, background);
    const instructions: []const u8 = "A S D F G H J K L ; and W E T Y U O P, or the pointer, play the keys";
    f.gl.text(.{ 24, 24 }, instructions, .{ .size = 18, .color = text_color, .font = &s.font });
    f.gl.textf(
        .{ 24, 56 },
        "notes played {d}",
        .{s.notes_started},
        .{ .size = 16, .color = text_color, .font = &s.font },
    );
    // White keys first, then the black ones over them.
    for (0..note_count) |note_index| {
        if (!key_places[note_index].is_black) {
            drawKey(f, s, layout, note_index);
        }
    }
    for (0..note_count) |note_index| {
        if (key_places[note_index].is_black) {
            drawKey(f, s, layout, note_index);
        }
    }
    drawLatencyReadout(f, s, layout.top + layout.white_height + 24);
}

fn update(f: *z.Frame, s: *State) void {
    // A black screen with a start button, until it is pressed and the audio runs (`z.showAudioStartScreen`).
    if (z.showAudioStartScreen(f, &s.font)) {
        return;
    }
    const layout: Layout = .ofWindow(f);
    if (!s.is_input_from_events) {
        readComputerKeyboard(f, s);
    }
    readPointer(f, s, layout);
    draw(f, s, layout);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - keyboard",
            .width = 760,
            .height = 520,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
    .on_input = onInput,
};
