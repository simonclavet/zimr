//! examples/magic_isomorphic_keyboard - the computer keyboard as an instrument, its keys laid out so that every
//! interval has one shape: the key to the right is a fifth up, the key below on the right a major third up, the key
//! above on the right a minor third up (the drawn layout). Each row is the circle of fifths - F C G D A E B,
//! then the sharps - so a major scale is seven keys in a row; a major chord is a downward triangle, its root, the key
//! to its right and the key below between them, and a minor chord an upward one, its root, the key above on the right
//! and the key to the right - in every key. It is the Tonnetz, the lattice of fifths and thirds, on a laptop's keys.
//!
//!     `  1  2  3  4  5  6  7  8  9  0  -  =           a key's six neighbours:
//!       Q  W  E  R  T  Y  U  I  O  P  [  ]  \
//!        A  S  D  F  G  H  J  K  L  ;  '                   up-left -4    up-right +3
//!          Z  X  C  V  B  N  M  ,  .  /                left -7     (key)     right +7
//!                                                         down-left -3  down-right +4
//!
//! The tonic sits on F, the home row's key under the left index finger, the one with the bump: in C major the home row
//! from D to L is F C G D A E B, the tonic under the index finger and its fifth under the next.
//!
//! The first layout, the stickers' in the photo - a minor third down to the right, a major third up to the upper
//! right - is kept as `thirds_layout`, for the layouts the options will offer.
//!
//! A key is named by its place, not by what it types (`z.KeyboardKey` is the physical key), so the layout is the same
//! on QWERTY, AZERTY and Dvorak. A key sounds while it is held: its press arrives through `on_input` and starts its
//! note at once, as in `audio_keyboard`, or is read each frame where the launcher does not call it. A key of the drawn
//! keyboard sounds under a finger or the mouse, several fingers at once, each sliding from key to key. The notes are
//! Shepard tones (`z.mixer.shepard_instrument`), as on the scale stars: each sounds its pitch class in every octave at
//! once, so keys playing the same note an octave or more apart - F and I, both C in C major - sound the same note, and
//! light up together.
//!
//! The keyboard's left side plays chords: the keys up to the column of 5, T, G and B whose note is one of the scale's
//! play the scale's triad on that note - in C major a major chord on C, F and G, a minor one on D, E and A, the
//! diminished one on B. One key, three notes: a laptop's keyboard often cannot report the three keys of a triangle held
//! together (the plan's risk R1, measured). A chord starts note by note - root, third, fifth, a strum's delay apart -
//! as on the two-handed star - and softly, at the chords' volume, so that what the right hand plays is heard over
//! it. The left side's other keys, the sharps in C major, play their own note.
//!
//!     `  1  2  3  4  5 |              the left side's chords in C major, the tonic on F:
//!       Q  W  E  R  T |
//!        A  S  D  F  G |                  `  C    1  G    2  Dm   3  Am   4  Em   5  B dim
//!          Z  X  C  V  B |                Q  B dim                  D  F    F  C    G  G
//!                                         Z  G    X  Dm   C  Am   V  Em   B  B dim
//!
//! The header holds the scale - its tonic's dropdown and its mode's, as the two-handed star's - and the chords'
//! volume. The tonic stays on F whatever the scale: every key then plays its note in the new scale, and the left
//! side's chords are the new scale's.
//!
//! The plan, its decisions and its stages: `src/notes/magic_isomorphic_keyboard_plan.md`. This is its stage S1, the
//! grid playing, with the left side's chord keys, the scale's dropdowns and the chords' volume (Simon, Nov 11); the
//! scale's colours, the triangles' chords and the progressions come in the stages after.
const std = @import("std");
const Allocator = std.mem.Allocator;
const bufPrint = std.fmt.bufPrint;
const eql = std.mem.eql;
const indexOfScalar = std.mem.indexOfScalar;
const splitScalar = std.mem.splitScalar;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const Vec2 = zm.Vec2;
const float = zm.float;
const length = zm.length;
const assert = zm.assert;
const inf = zm.inf;
const splat2 = zm.splat2;
const music_theory = @import("music_theory");
const Scale = music_theory.Scale;
const ScaleChord = music_theory.ScaleChord;
const Mode = music_theory.Mode;
const ListedTonic = music_theory.ListedTonic;
const listed_tonics = music_theory.listed_tonics;
const listed_tonic_names = music_theory.listed_tonic_names;
const mode_count = music_theory.mode_count;
const mode_label_capacity = music_theory.mode_label_capacity;
const mode_label_columns = music_theory.mode_label_columns;
const writeModeLabel = music_theory.writeModeLabel;
const chordLetterName = music_theory.chordLetterName;
const c_major = music_theory.c_major;

/// The font every text is drawn in: Atkinson Hyperlegible Mono, embedded in the app.
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

// ---- The params ----

/// The app's tunable values in one place, grouped by topic, each read where it is needed - `params.colors.background`.
const params = struct {
    /// The colors.
    const colors = struct {
        /// The window's background: the scale stars' near-black blue-grey.
        const background: Color = .{ .r = 16, .g = 17, .b = 22, .a = 255 };
        /// Text: a soft white.
        const text: Color = .{ .r = 235, .g = 235, .b = 240, .a = 255 };
        /// Text that matters less: a mid grey.
        const dim_text: Color = .{ .r = 150, .g = 156, .b = 170, .a = 255 };
        /// A key playing a natural note, as the photo's stickers are: white.
        const natural_key: Color = .{ .r = 236, .g = 236, .b = 240, .a = 255 };
        /// A key playing a sharp: the stickers' lilac.
        const sharp_key: Color = .{ .r = 212, .g = 194, .b = 232, .a = 255 };
        /// A key playing a chord, on the keyboard's left side (`chordOfKey`): a pale green, apart from the stickers'
        /// two colours.
        const chord_key: Color = .{ .r = 190, .g = 226, .b = 208, .a = 255 };
        /// A key while its note sounds: orange, as `audio_keyboard` lights a key held.
        const sounding_key: Color = .{ .r = 255, .g = 170, .b = 60, .a = 255 };
        /// The note's name on a key: near-black, on the light keys.
        const note_name: Color = .{ .r = 24, .g = 26, .b = 34, .a = 255 };
        /// A key's own letter, small in its corner: grey.
        const key_letter: Color = .{ .r = 110, .g = 114, .b = 128, .a = 255 };
        /// The keys that play nothing - Tab, Caps Lock, Shift, Enter, Backspace - a little lighter than the
        /// background, so that the shape reads as a keyboard.
        const other_key: Color = .{ .r = 40, .g = 43, .b = 54, .a = 255 };
    };

    /// Playing.
    const playing = struct {
        /// How hard every note is struck: half the instrument's full level, as the scale stars strike theirs, so that
        /// a chord of three stays clear of clipping. Six or more at once may not (the plan's risk R4).
        const note_velocity: f32 = 0.5;
        /// The last column of the keys that play chords, as an index along a row: 4, the column of 5, T, G and B. The
        /// keys up to it - the left hand's - play chords (`chordOfKey`).
        const last_chord_index_in_row: i8 = 4;
        /// The delay between a chord's notes as it starts - root, third, fifth: 0.1 s, the two-handed star's strum.
        const chord_strum_seconds: f32 = 0.1;
        /// How strongly a chord's key strikes its notes at the start, as a share of the other notes' strength
        /// (`State.chord_volume`, set in the header): half, so that what the right hand plays is heard over the
        /// chord.
        const chord_volume: f32 = 0.5;
        /// How far a pointer must move from where it took its key before it takes another: 6 pixels, as on the
        /// two-handed star. A finger resting on the line between two keys moves a pixel or two back and forth; each
        /// crossing would let one note go and strike the other, heard as crackle.
        const target_switch_distance: f32 = 6;
        /// How far from a key's centre a pointer still finds it, on each axis, as a share of a key's size: more than
        /// half, so that the gaps between keys belong to the nearest key and a finger sliding along a row never falls
        /// silent between two.
        const key_reach_share: f32 = 0.7;
    };

    /// The keyboard's drawing.
    const keyboard = struct {
        /// The keyboard's width, in keys: 15, from the backquote's left edge to Backspace's right.
        const width_in_keys: f32 = 15;
        /// Its height, in rows: the four rows of characters.
        const height_in_rows: f32 = 4;
        /// The gap between two keys, as a share of a key's size.
        const key_gap_share: f32 = 0.08;
        /// The key caps' corners (`rectRoundedXYWH`): how round, and in how many segments each.
        const corner_roundness: f32 = 0.3;
        const corner_segments: u32 = 6;
        /// The note's name on a key and the key's own letter, as shares of a key's size.
        const note_name_share: f32 = 0.36;
        const key_letter_share: f32 = 0.2;
    };

    /// The window's parts.
    const window = struct {
        /// The margin along the window's sides, and the heights of the header above the keyboard and the footer
        /// below it, in pixels.
        const margin: f32 = 16;
        const header_height: f32 = 60;
        const footer_height: f32 = 96;
        /// The header's controls - the scale's two dropdowns and the chords' volume (`buildHeader`): their window's
        /// top and its height, as the two-handed star's header has them; and the slider's width.
        const toolbar_top: f32 = 2;
        const toolbar_height: f32 = 34;
        const volume_slider_width: f32 = 160;
        /// The legend's top, under the controls.
        const legend_top: f32 = 38;
        /// The lines of text: the header's legend, and the footer's lines.
        const line_size: f32 = 14;
        const line_spacing: f32 = 22;
    };

    /// How many of each the state has room for.
    const limits = struct {
        /// The most pointers held at once: the ten touches the engine tracks, and the mouse.
        const most_pointers: usize = 11;
        /// The room for the footer's line of keys held: its words, and every key's letter.
        const held_keys_line_capacity: usize = 160;
    };
};

// ---- The keys ----

/// A key of the computer keyboard's four rows of characters: the engine's name for it (`z.KeyboardKey`'s), the label a
/// US keyboard prints on it, its row - 0 the digits, 3 the bottom letters - its index along the row, 0 at 1, Q, A and Z
/// (-1 for the backquote, left of 1), and its width in keys. The index is what makes a layout work whatever the rows'
/// offsets: a key's two upper neighbours are the keys of the row above at its own index (up-left) and at the next
/// (up-right).
const PlayingKey = struct {
    engine_name: []const u8,
    us_label: []const u8,
    row: u8,
    index_in_row: i8,
    width_in_keys: f32 = 1,
};

/// The 47 keys of the four rows - 13, 13, 11 and 10 - in rows from the top, each left to right.
const playing_keys = [_]PlayingKey{
    .{ .engine_name = "grave", .us_label = "`", .row = 0, .index_in_row = -1 },
    .{ .engine_name = "one", .us_label = "1", .row = 0, .index_in_row = 0 },
    .{ .engine_name = "two", .us_label = "2", .row = 0, .index_in_row = 1 },
    .{ .engine_name = "three", .us_label = "3", .row = 0, .index_in_row = 2 },
    .{ .engine_name = "four", .us_label = "4", .row = 0, .index_in_row = 3 },
    .{ .engine_name = "five", .us_label = "5", .row = 0, .index_in_row = 4 },
    .{ .engine_name = "six", .us_label = "6", .row = 0, .index_in_row = 5 },
    .{ .engine_name = "seven", .us_label = "7", .row = 0, .index_in_row = 6 },
    .{ .engine_name = "eight", .us_label = "8", .row = 0, .index_in_row = 7 },
    .{ .engine_name = "nine", .us_label = "9", .row = 0, .index_in_row = 8 },
    .{ .engine_name = "zero", .us_label = "0", .row = 0, .index_in_row = 9 },
    .{ .engine_name = "minus", .us_label = "-", .row = 0, .index_in_row = 10 },
    .{ .engine_name = "equal", .us_label = "=", .row = 0, .index_in_row = 11 },
    .{ .engine_name = "q", .us_label = "Q", .row = 1, .index_in_row = 0 },
    .{ .engine_name = "w", .us_label = "W", .row = 1, .index_in_row = 1 },
    .{ .engine_name = "e", .us_label = "E", .row = 1, .index_in_row = 2 },
    .{ .engine_name = "r", .us_label = "R", .row = 1, .index_in_row = 3 },
    .{ .engine_name = "t", .us_label = "T", .row = 1, .index_in_row = 4 },
    .{ .engine_name = "y", .us_label = "Y", .row = 1, .index_in_row = 5 },
    .{ .engine_name = "u", .us_label = "U", .row = 1, .index_in_row = 6 },
    .{ .engine_name = "i", .us_label = "I", .row = 1, .index_in_row = 7 },
    .{ .engine_name = "o", .us_label = "O", .row = 1, .index_in_row = 8 },
    .{ .engine_name = "p", .us_label = "P", .row = 1, .index_in_row = 9 },
    .{ .engine_name = "left_bracket", .us_label = "[", .row = 1, .index_in_row = 10 },
    .{ .engine_name = "right_bracket", .us_label = "]", .row = 1, .index_in_row = 11 },
    .{ .engine_name = "backslash", .us_label = "\\", .row = 1, .index_in_row = 12, .width_in_keys = 1.5 },
    .{ .engine_name = "a", .us_label = "A", .row = 2, .index_in_row = 0 },
    .{ .engine_name = "s", .us_label = "S", .row = 2, .index_in_row = 1 },
    .{ .engine_name = "d", .us_label = "D", .row = 2, .index_in_row = 2 },
    .{ .engine_name = "f", .us_label = "F", .row = 2, .index_in_row = 3 },
    .{ .engine_name = "g", .us_label = "G", .row = 2, .index_in_row = 4 },
    .{ .engine_name = "h", .us_label = "H", .row = 2, .index_in_row = 5 },
    .{ .engine_name = "j", .us_label = "J", .row = 2, .index_in_row = 6 },
    .{ .engine_name = "k", .us_label = "K", .row = 2, .index_in_row = 7 },
    .{ .engine_name = "l", .us_label = "L", .row = 2, .index_in_row = 8 },
    .{ .engine_name = "semicolon", .us_label = ";", .row = 2, .index_in_row = 9 },
    .{ .engine_name = "apostrophe", .us_label = "'", .row = 2, .index_in_row = 10 },
    .{ .engine_name = "z", .us_label = "Z", .row = 3, .index_in_row = 0 },
    .{ .engine_name = "x", .us_label = "X", .row = 3, .index_in_row = 1 },
    .{ .engine_name = "c", .us_label = "C", .row = 3, .index_in_row = 2 },
    .{ .engine_name = "v", .us_label = "V", .row = 3, .index_in_row = 3 },
    .{ .engine_name = "b", .us_label = "B", .row = 3, .index_in_row = 4 },
    .{ .engine_name = "n", .us_label = "N", .row = 3, .index_in_row = 5 },
    .{ .engine_name = "m", .us_label = "M", .row = 3, .index_in_row = 6 },
    .{ .engine_name = "comma", .us_label = ",", .row = 3, .index_in_row = 7 },
    .{ .engine_name = "period", .us_label = ".", .row = 3, .index_in_row = 8 },
    .{ .engine_name = "slash", .us_label = "/", .row = 3, .index_in_row = 9 },
};

/// Where index 0 of each row starts, in key widths from the keyboard's left edge, on an ANSI keyboard: 1 after the
/// backquote, Q after Tab's 1.5, A after Caps Lock's 1.75, Z after the left Shift's 2.25.
const row_start_in_keys: [4]f32 = .{ 1.0, 1.5, 1.75, 2.25 };

/// A key that plays nothing, drawn so that the playing keys read as a keyboard: its name, its row, where it starts and
/// its width, in keys.
const OtherKey = struct {
    label: []const u8,
    row: u8,
    left_in_keys: f32,
    width_in_keys: f32,
};

/// The keys at the four rows' ends: Backspace, Tab, Caps Lock, Enter and the two Shifts.
const other_keys = [_]OtherKey{
    .{ .label = "backspace", .row = 0, .left_in_keys = 13, .width_in_keys = 2 },
    .{ .label = "tab", .row = 1, .left_in_keys = 0, .width_in_keys = 1.5 },
    .{ .label = "caps lock", .row = 2, .left_in_keys = 0, .width_in_keys = 1.75 },
    .{ .label = "enter", .row = 2, .left_in_keys = 12.75, .width_in_keys = 2.25 },
    .{ .label = "shift", .row = 3, .left_in_keys = 0, .width_in_keys = 2.25 },
    .{ .label = "shift", .row = 3, .left_in_keys = 12.25, .width_in_keys = 2.75 },
};

/// The index in `playing_keys` of the key the engine names `engine_name`, or null.
fn keyIndexNamed(engine_name: []const u8) ?usize {
    for (playing_keys, 0..) |key, key_index| {
        if (eql(u8, key.engine_name, engine_name)) {
            return key_index;
        }
    }
    return null;
}

/// The index in `playing_keys` of the key a US keyboard labels `us_label`, or null.
fn keyIndexLabelled(us_label: []const u8) ?usize {
    for (playing_keys, 0..) |key, key_index| {
        if (eql(u8, key.us_label, us_label)) {
            return key_index;
        }
    }
    return null;
}

/// The index in `playing_keys` of the key at `index_in_row` along `row`, or null where the keyboard has none.
fn keyIndexAt(row: i16, index_in_row: i16) ?usize {
    for (playing_keys, 0..) |key, key_index| {
        const is_at_place: bool = key.row == row and key.index_in_row == index_in_row;
        if (is_at_place) {
            return key_index;
        }
    }
    return null;
}

/// Each playing key's engine key, in `playing_keys`' order, read from its name when compiling - so the two cannot
/// drift apart. Kept out of `playing_keys` itself, so that the layouts, which need no engine, are tested without one
/// (`zig build test-magic-isomorphic-keyboard`).
const engine_keys: [playing_keys.len]z.KeyboardKey = engine_keys_of_names: {
    var keys: [playing_keys.len]z.KeyboardKey = undefined;
    for (&keys, playing_keys) |*key, playing_key| {
        key.* = @field(z.KeyboardKey, playing_key.engine_name);
    }
    break :engine_keys_of_names keys;
};

/// The index in `playing_keys` of the engine's key `key`, or null for a key that plays nothing.
fn keyIndexOfEngineKey(key: z.KeyboardKey) ?usize {
    return indexOfScalar(z.KeyboardKey, &engine_keys, key);
}

// ---- The layout ----

/// A layout where every interval has one shape - an isomorphic layout: the semitones from a key up to its right
/// neighbour, and up to its upper right one. The upper left neighbour is their difference away, and the key a row down
/// at the same index - the lower right one - the opposite of that.
const Isomorphic = struct {
    step_right: i8,
    step_up_right: i8,

    /// The semitones from key `from` up to key `to`: a `step_right` for each key to the right, and for each row down,
    /// the step to the lower right neighbour, `step_right - step_up_right`.
    fn semitonesBetween(layout: Isomorphic, from: PlayingKey, to: PlayingKey) i16 {
        const keys_right: i16 = @as(i16, to.index_in_row) - from.index_in_row;
        const rows_down: i16 = @as(i16, to.row) - from.row;
        const step_down_right: i16 = @as(i16, layout.step_right) - layout.step_up_right;
        return keys_right * layout.step_right + rows_down * step_down_right;
    }
};

/// The drawn layout, the one played: a fifth up to the right, a minor third up to the upper right - so a
/// major third up to the lower right. The Tonnetz, with the circle of fifths along the rows.
const fifths_layout: Isomorphic = .{ .step_right = 7, .step_up_right = 3 };

/// The photo's layout, the first: a minor third down to the right, a major third up to the upper right - so a fifth up
/// to the upper left. The Tonnetz, with minor thirds along the rows; kept for the layouts the options will offer.
const thirds_layout: Isomorphic = .{ .step_right = -3, .step_up_right = 4 };

/// A fixed anchor: the key, by its index in `playing_keys`, and the MIDI key it plays.
const FixedAnchor = struct {
    key_index: usize,
    midi_key: u8,
};

/// Which key plays which note: the scale's tonic on a key, in middle C's octave - the grid moving with the scale, each
/// degree keeping its key in every key - or a fixed note on a key, whatever the scale, as the stickers fix C.
const Anchoring = union(enum) {
    /// The tonic on the key at this index in `playing_keys`.
    tonic_on_key: usize,
    /// A fixed note on a key.
    fixed: FixedAnchor,
};

/// The tonic on the F key, under the left index finger (the second picture).
const tonic_on_f: Anchoring = .{ .tonic_on_key = keyIndexNamed("f").? };

/// The photo's stickers' anchoring, under `thirds_layout`: C6 on 1, and so C on 5, 9 and X as well.
const stickers_anchoring: Anchoring = .{ .fixed = .{ .key_index = keyIndexNamed("one").?, .midi_key = 84 } };

/// The drawn layout's anchoring, under `fifths_layout`: F1 on 1, each row's naturals F C G D A E B. Low enough that
/// every key's note, up to the backslash's more than seven octaves higher, stays within MIDI's range.
const drawing_anchoring: Anchoring = .{ .fixed = .{ .key_index = keyIndexNamed("one").?, .midi_key = 29 } };

/// The MIDI key the key at `key_index` plays under `layout` and `anchoring`, the scale's tonic being at
/// `tonic_pitch_class` (C as 0) - or null for a key whose note falls outside MIDI's 0 to 127. With fifths along the
/// rows the grid is wide in pitch: with the tonic on F in C major it runs from C1 at the backquote to B8 at the
/// backslash. The Shepard instrument hears only pitch classes; real octaves will need their own choice (the plan's D9).
fn midiKeyOf(
    layout: Isomorphic,
    anchoring: Anchoring,
    tonic_pitch_class: u8,
    key_index: usize,
) ?u8 {
    const anchor_index: usize = switch (anchoring) {
        .tonic_on_key => |tonic_key_index| tonic_key_index,
        .fixed => |fixed| fixed.key_index,
    };
    const anchor_midi_key: i16 = switch (anchoring) {
        .tonic_on_key => 60 + @as(i16, tonic_pitch_class),
        .fixed => |fixed| fixed.midi_key,
    };
    const semitones_from_anchor: i16 = layout.semitonesBetween(playing_keys[anchor_index], playing_keys[key_index]);
    const midi_key: i16 = anchor_midi_key + semitones_from_anchor;
    const is_in_range: bool = midi_key >= 0 and midi_key <= 127;
    if (!is_in_range) {
        return null;
    }
    const midi_key_in_range: u8 = @intCast(midi_key);
    return midi_key_in_range;
}

/// The key the instrument is sent for a MIDI key: its pitch class in middle C's octave. The Shepard instrument sounds
/// a pitch class in every octave at once, so two keys an octave apart would sound alike - sent as one key, they sound
/// once, held as long as either is.
fn soundKeyOf(midi_key: u8) u8 {
    return 60 + midi_key % 12;
}

/// How strongly a key holds its notes: a chord's key softly - at the chords' volume (`State.chord_volume`), so that
/// what the right hand plays is heard over the chord - any other key fully.
const HoldLayer = enum { chord, full };

/// The most notes a key plays: a chord's three.
const most_notes_of_key: usize = 3;

/// What a key plays: the sound keys (`soundKeyOf`) of its notes, in the order they start - one for a note; a chord's
/// root, third and fifth - and how strongly it holds them.
const KeyNotes = struct {
    /// The sound keys: the first `count` are the key's notes.
    sound_keys: [most_notes_of_key]u8,
    count: usize,
    /// How strongly the notes are held: a chord's softly, a note's own key fully.
    layer: HoldLayer,

    /// One note, held fully.
    fn single(sound_key: u8) KeyNotes {
        return .{ .sound_keys = .{ sound_key, 0, 0 }, .count = 1, .layer = .full };
    }

    /// The notes' sound keys, in the order they start.
    fn slice(notes: *const KeyNotes) []const u8 {
        return notes.sound_keys[0..notes.count];
    }
};

/// The chord the key at `key_index` plays under `layout` and `anchoring` in `scale`: a key of the keyboard's left side
/// - up to the column of 5, T, G and B (`params.playing.last_chord_index_in_row`) - whose note is one of the scale's
/// plays the scale's triad on that note: in C major a major chord on C, F and G, a minor one on D, E and A, the
/// diminished one on B. Null for a key of the right side, for one whose note is outside the scale - a sharp, in C
/// major - and for one whose note falls outside MIDI's range.
fn chordOfKey(
    layout: Isomorphic,
    anchoring: Anchoring,
    scale: *const Scale,
    key_index: usize,
) ?ScaleChord {
    const is_on_chord_side: bool = playing_keys[key_index].index_in_row <= params.playing.last_chord_index_in_row;
    if (!is_on_chord_side) {
        return null;
    }
    const midi_key: u8 = midiKeyOf(layout, anchoring, scale.tonicPitchClass(), key_index) orelse return null;
    const pitch_class: u4 = @intCast(midi_key % 12);
    const degree: u8 = scale.degreeOfPitchClass(pitch_class) orelse return null;
    return scale.chordOf(degree);
}

/// What the key at `key_index` plays under `layout` and `anchoring` in `scale`: a chord's key (`chordOfKey`), the
/// chord's three notes - root, third, fifth - held softly (`HoldLayer.chord`); any other key, its own note, held
/// fully. Null for a key whose note falls outside MIDI's range.
fn notesOfKey(
    layout: Isomorphic,
    anchoring: Anchoring,
    scale: *const Scale,
    key_index: usize,
) ?KeyNotes {
    const midi_key: u8 = midiKeyOf(layout, anchoring, scale.tonicPitchClass(), key_index) orelse return null;
    const chord: ScaleChord = chordOfKey(layout, anchoring, scale, key_index) orelse
        return KeyNotes.single(soundKeyOf(midi_key));
    var notes: KeyNotes = .{ .sound_keys = undefined, .count = most_notes_of_key, .layer = .chord };
    for (&notes.sound_keys, chord.degrees()) |*sound_key, degree| {
        sound_key.* = soundKeyOf(scale.pitchClassOfDegree(degree));
    }
    return notes;
}

/// The twelve notes' names as the stickers write them, by pitch class from C: sharps for the black keys.
const sharp_note_names: [12][]const u8 = .{ "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" };

/// The name of the note at `pitch_class` in `scale`: one of the scale's notes as the scale spells it - Bb in F major,
/// F# in D major; any other as the stickers do, with a sharp.
fn noteNameIn(scale: *const Scale, pitch_class: u8) []const u8 {
    const scale_pitch_class: u4 = @intCast(pitch_class);
    const degree: u8 = scale.degreeOfPitchClass(scale_pitch_class) orelse return sharp_note_names[pitch_class];
    return scale.noteName(degree);
}

/// Whether each pitch class from C is a sharp - a black key on a piano, a lilac sticker.
const is_sharp_pitch_class: [12]bool = .{
    false, true,  false, true,  false, false,
    true,  false, true,  false, true,  false,
};

// ---- The app's state ----

/// What a key or a pointer holds: its notes; how many of them have started - a chord's start one after another, a
/// strum's delay apart (`startDueNotes`), so the first `started_count` sound and the others wait; and when the hold
/// began, on the frame's clock.
const HeldNotes = struct {
    notes: KeyNotes,
    started_count: usize,
    began_seconds: f32,
};

/// A pointer holding a key: a finger, by the identifier the platform gives it for as long as it touches - the same
/// from frame to frame, wherever it moves - or the mouse (`mouse_pointer_id`); the key it holds, the notes it holds
/// there, and where the pointer stood when it took the key.
const PointerHold = struct {
    pointer_id: i32,
    key_index: usize,
    held: HeldNotes,
    anchor: Vec2,
};

/// The mouse's identifier among the pointers: one no touch is given, touches being numbered up from 0.
const mouse_pointer_id: i32 = -1;

/// A pointer down this frame: its identifier and where it is.
const PointerDown = struct {
    pointer_id: i32,
    position: Vec2,
};

/// How many things hold a sound key down, in each of the two ways (`HoldLayer`): the chords' keys that play its
/// note, softly; the computer keys, the fingers and the mouse on a note's own key, fully.
const SoundKeyHolds = struct {
    chord: u8 = 0,
    full: u8 = 0,
};

/// How a note sounds: not at all; softly, held by chords alone; or fully, held by a note's own key.
const NoteStrength = enum { silent, chord, full };

/// Everything the app keeps from one frame to the next.
const State = struct {
    /// The font every text is drawn in (`atkinson_mono_ttf`).
    font: z.Font,
    /// The engine's UI: the header's controls - the scale's dropdowns and the chords' volume (`buildHeader`).
    ui_host: z.UiHost,
    /// How many things hold each sound key down, in each of the two ways (`SoundKeyHolds`). A note sounds once
    /// however many hold it, at the strength the holds call for (`strengthOfSoundKey`), and stops only when all let
    /// go.
    holds: [128]SoundKeyHolds,
    /// How strongly a chord's key strikes its notes, as a share of the other notes' strength
    /// (`soundStrengthChange`): set in the header, from `params.playing.chord_volume`. A chord struck takes the
    /// volume of that moment.
    chord_volume: f32,
    /// The header's mode list, its labels written each frame for the tonic chosen (`writeModeLabels`): each mode's
    /// name and the notes it alters from the major scale, then its seven chords on the tonic.
    mode_label_buffers: [mode_count][mode_label_capacity]u8,
    mode_labels: [mode_count][]const u8,
    /// Whether one of the header's lists was open at the last frame (`buildHeader`): the press that closes a list,
    /// beside it, is the list's, though the list is gone by the frame that reads the pointers.
    was_list_open: bool,
    /// The notes each computer key holds, while it is down: its release lets go of those, whatever the key plays by
    /// then.
    key_holds: [playing_keys.len]?HeldNotes,
    /// What each pointer holds, while it is down: a slot each, free when null.
    pointer_holds: [params.limits.most_pointers]?PointerHold,
    /// The layout played: the drawn one, fifths along the rows, until the options can choose another.
    layout: Isomorphic,
    /// The scale, whose tonic the F key plays: C major at the start, chosen in the header (`buildHeader`).
    scale: Scale,
    /// Whether presses and releases arrive through `onInput` (`AppSpec.on_input`): set at its first call. Until then
    /// - and in a launcher that does not call it - each frame reads the computer keyboard instead.
    is_input_from_events: bool,
    /// Whether the pointers play nothing until they are lifted: at the start, so that the press on the start
    /// screen's button, still down as the keyboard appears under it, plays nothing; and after Escape.
    are_pointers_waiting_for_release: bool,
    /// Whether the screen has reported a touch. A browser also turns a touch into the mouse's press and movement;
    /// once a touch has been seen, the mouse is ignored, and each finger counts once, as itself.
    has_seen_touch: bool,
};

/// The app's start: its font and its UI, nothing held, C major; the sound started, with the Shepard instrument.
fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 32);
    s.* = .{
        .font = font,
        .ui_host = z.UiHost.init(gpa, font),
        .holds = @splat(.{}),
        .chord_volume = params.playing.chord_volume,
        .mode_label_buffers = undefined,
        .mode_labels = @splat(""),
        .was_list_open = false,
        .key_holds = @splat(null),
        .pointer_holds = @splat(null),
        .layout = fifths_layout,
        .scale = c_major,
        .is_input_from_events = false,
        .are_pointers_waiting_for_release = true,
        .has_seen_touch = false,
    };
    z.audio_device.init(f.audio_device);
    f.mixer.setInstrument(z.mixer.shepard_instrument);
}

/// The app's end: its UI and its font freed.
fn deinit(gpa: Allocator, s: *State) void {
    s.ui_host.deinit();
    z.unloadFont(gpa, s.font);
}

// ---- The window ----

/// Where the keyboard is drawn: the left edge and the top of its first row, and a key's size - a key's width, which is
/// also a row's height.
const KeyboardLayout = struct {
    left: f32,
    top: f32,
    key_size: f32,

    /// The keyboard as large as the window allows between its header and its footer - 15 keys wide, 4 rows tall -
    /// and centred there.
    fn ofWindow(f: *z.Frame) KeyboardLayout {
        const margin: f32 = params.window.margin;
        const room_width: f32 = f.window.widthf() - 2 * margin;
        const room_height: f32 = f.window.heightf() - params.window.header_height - params.window.footer_height;
        const size_by_width: f32 = room_width / params.keyboard.width_in_keys;
        const size_by_height: f32 = room_height / params.keyboard.height_in_rows;
        const fitting_size: f32 = @min(size_by_width, size_by_height);
        const key_size: f32 = @max(1, fitting_size);
        const keyboard_width: f32 = key_size * params.keyboard.width_in_keys;
        const keyboard_height: f32 = key_size * params.keyboard.height_in_rows;
        return .{
            .left = margin + (room_width - keyboard_width) / 2,
            .top = params.window.header_height + @max(0, room_height - keyboard_height) / 2,
            .key_size = key_size,
        };
    }

    /// The rectangle a key fills: `left_in_keys` from the keyboard's left edge on `row`, `width_in_keys` wide, less
    /// half the gap between keys on each side.
    fn keyRect(
        layout: KeyboardLayout,
        row: u8,
        left_in_keys: f32,
        width_in_keys: f32,
    ) z.Rectangle {
        const gap: f32 = params.keyboard.key_gap_share * layout.key_size;
        return .{
            .x = layout.left + left_in_keys * layout.key_size + gap / 2,
            .y = layout.top + float(row) * layout.key_size + gap / 2,
            .width = width_in_keys * layout.key_size - gap,
            .height = layout.key_size - gap,
        };
    }

    /// The rectangle the playing key at `key_index` fills.
    fn playingKeyRect(layout: KeyboardLayout, key_index: usize) z.Rectangle {
        const key: PlayingKey = playing_keys[key_index];
        const left_in_keys: f32 = row_start_in_keys[key.row] + float(key.index_in_row);
        return layout.keyRect(key.row, left_in_keys, key.width_in_keys);
    }

    /// The centre of the playing key at `key_index`.
    fn playingKeyCentre(layout: KeyboardLayout, key_index: usize) Vec2 {
        const rect: z.Rectangle = layout.playingKeyRect(key_index);
        return .{ rect.x + rect.width / 2, rect.y + rect.height / 2 };
    }
};

/// The key a pointer at `point` plays: the playing key whose centre is nearest, if it is within reach
/// (`params.playing.key_reach_share` of a key on each axis); none for a point off the keyboard.
fn keyAt(layout: KeyboardLayout, point: Vec2) ?usize {
    var nearest_key_index: ?usize = null;
    var nearest_distance: f32 = inf(f32);
    const reach: f32 = params.playing.key_reach_share * layout.key_size;
    for (playing_keys, 0..) |key, key_index| {
        const offset: Vec2 = point - layout.playingKeyCentre(key_index);
        const is_within_reach_across: bool = @abs(offset[0]) <= reach * key.width_in_keys;
        const is_within_reach: bool = is_within_reach_across and @abs(offset[1]) <= reach;
        const distance_to_centre: f32 = length(offset);
        if (is_within_reach and distance_to_centre < nearest_distance) {
            nearest_key_index = key_index;
            nearest_distance = distance_to_centre;
        }
    }
    return nearest_key_index;
}

// ---- Playing ----

/// What the key at `key_index` plays now (`notesOfKey`) - the layout played, the tonic on F, the scale - or null for a
/// key whose note falls outside MIDI's range.
fn notesOfKeyNow(s: *const State, key_index: usize) ?KeyNotes {
    return notesOfKey(s.layout, tonic_on_f, &s.scale, key_index);
}

/// How a sound key's note sounds now: fully if a note's own key holds it, softly if only chords do, silent if nothing
/// does.
fn strengthOfSoundKey(s: *const State, sound_key: u8) NoteStrength {
    const sound_key_holds: SoundKeyHolds = s.holds[sound_key];
    if (sound_key_holds.full > 0) {
        return .full;
    }
    return if (sound_key_holds.chord > 0) .chord else .silent;
}

/// Makes a sound key's note sound at its new strength, as the two-handed star does: let go if it falls silent, struck
/// again at the new strength if that rises - the instrument lets a held note go when its key is struck again, so the
/// note sounds once. So a note a chord holds softly is struck again fully when the right hand presses it too. A strike
/// carries the press's time for the latency readout - 0 for a note that no press started.
fn soundStrengthChange(
    f: *z.Frame,
    s: *const State,
    sound_key: u8,
    before: NoteStrength,
    after: NoteStrength,
    pressed_at_ms: f64,
) void {
    if (before == after) {
        return;
    }
    // From full to a chord's strength - the right hand lifting a note the chord still holds - the note rings on as it
    // is, as a piano's string rings on while another finger keeps its key down: striking it again, softer, would put
    // a new attack where a finger was lifted.
    if (before == .full and after == .chord) {
        return;
    }
    const full_velocity: f32 = params.playing.note_velocity;
    const chord_velocity: f32 = s.chord_volume * full_velocity;
    switch (after) {
        .silent => _ = f.mixer.sendNote(.{ .key = sound_key, .is_down = false }),
        .chord => _ = f.mixer.sendNote(.{
            .key = sound_key,
            .is_down = true,
            .velocity = chord_velocity,
            .pressed_at_ms = pressed_at_ms,
        }),
        .full => _ = f.mixer.sendNote(.{
            .key = sound_key,
            .is_down = true,
            .velocity = full_velocity,
            .pressed_at_ms = pressed_at_ms,
        }),
    }
}

/// One more hold on a sound key, in `layer`: its note starts, or sounds more strongly, if that changes how it sounds
/// (`soundStrengthChange`).
fn holdSoundKey(
    f: *z.Frame,
    s: *State,
    sound_key: u8,
    layer: HoldLayer,
    pressed_at_ms: f64,
) void {
    const before: NoteStrength = strengthOfSoundKey(s, sound_key);
    const sound_key_holds: *SoundKeyHolds = &s.holds[sound_key];
    switch (layer) {
        .chord => sound_key_holds.chord += 1,
        .full => sound_key_holds.full += 1,
    }
    soundStrengthChange(f, s, sound_key, before, strengthOfSoundKey(s, sound_key), pressed_at_ms);
}

/// One hold fewer on a sound key, in `layer`: its note stops when the last lets go.
fn releaseSoundKey(f: *z.Frame, s: *State, sound_key: u8, layer: HoldLayer) void {
    const before: NoteStrength = strengthOfSoundKey(s, sound_key);
    const sound_key_holds: *SoundKeyHolds = &s.holds[sound_key];
    switch (layer) {
        .chord => {
            assert(sound_key_holds.chord > 0, @src());
            sound_key_holds.chord -= 1;
        },
        .full => {
            assert(sound_key_holds.full > 0, @src());
            sound_key_holds.full -= 1;
        },
    }
    soundStrengthChange(f, s, sound_key, before, strengthOfSoundKey(s, sound_key), 0);
}

/// Begins a hold of `notes`: the first starts now, carrying the press's time (`holdSoundKey`); a chord's others wait
/// their turn, each a strum's delay after the one before (`startDueNotes`).
fn beginHold(f: *z.Frame, s: *State, notes: KeyNotes, pressed_at_ms: f64) HeldNotes {
    holdSoundKey(f, s, notes.sound_keys[0], notes.layer, pressed_at_ms);
    return .{ .notes = notes, .started_count = 1, .began_seconds = f.time.time };
}

/// Starts each note of a hold whose time has come: note `n` - the root 0, the third 1, the fifth 2 - starts `n`
/// strums (`params.playing.chord_strum_seconds`) after the hold began.
fn startDueNotes(f: *z.Frame, s: *State, held: *HeldNotes) void {
    while (held.started_count < held.notes.count) {
        const delay_seconds: f32 = float(held.started_count) * params.playing.chord_strum_seconds;
        const is_due: bool = f.time.time >= held.began_seconds + delay_seconds;
        if (!is_due) {
            return;
        }
        holdSoundKey(f, s, held.notes.sound_keys[held.started_count], held.notes.layer, 0);
        held.started_count += 1;
    }
}

/// Starts the due notes of every hold, the keys' and the pointers' (`startDueNotes`): called once a frame, so that a
/// chord's third and fifth each start within a frame of their time.
fn startDueNotesOfHolds(f: *z.Frame, s: *State) void {
    for (&s.key_holds) |*hold_slot| {
        if (hold_slot.*) |*held| {
            startDueNotes(f, s, held);
        }
    }
    for (&s.pointer_holds) |*hold_slot| {
        if (hold_slot.*) |*hold| {
            startDueNotes(f, s, &hold.held);
        }
    }
}

/// Ends a hold: the notes that started are let go; a chord's notes still waiting never start.
fn endHold(f: *z.Frame, s: *State, held: HeldNotes) void {
    for (held.notes.sound_keys[0..held.started_count]) |sound_key| {
        releaseSoundKey(f, s, sound_key, held.notes.layer);
    }
}

/// A computer key goes down: it holds its notes - its note, or its chord's three - unless it already does.
fn pressKey(f: *z.Frame, s: *State, key_index: usize, pressed_at_ms: f64) void {
    if (s.key_holds[key_index] != null) {
        return;
    }
    const notes: KeyNotes = notesOfKeyNow(s, key_index) orelse return;
    s.key_holds[key_index] = beginHold(f, s, notes, pressed_at_ms);
}

/// A computer key comes up: it lets go of the notes it holds.
fn releaseKey(f: *z.Frame, s: *State, key_index: usize) void {
    const held: HeldNotes = s.key_holds[key_index] orelse return;
    s.key_holds[key_index] = null;
    endHold(f, s, held);
}

/// Lets go of everything the pointers hold; they then play nothing until they are lifted.
fn releasePointers(f: *z.Frame, s: *State) void {
    for (&s.pointer_holds) |*hold_slot| {
        const hold: PointerHold = hold_slot.* orelse continue;
        endHold(f, s, hold.held);
        hold_slot.* = null;
    }
    s.are_pointers_waiting_for_release = true;
}

/// Lets go of everything the keys and the pointers hold - Escape, the panic button, or the window losing the
/// keyboard's focus, whose releases it will not see. The pointers then play nothing until they are lifted.
fn releaseEverything(f: *z.Frame, s: *State) void {
    for (0..playing_keys.len) |key_index| {
        releaseKey(f, s, key_index);
    }
    releasePointers(f, s);
}

// ---- Reading the input ----

/// The computer keyboard, read each frame while presses do not arrive as events (`is_input_from_events`): a key
/// pressed this frame plays; a key held until now and no longer down lets go; Escape lets go of everything.
fn readComputerKeyboard(f: *z.Frame, s: *State) void {
    if (z.isKeyPressed(f.input, .escape)) {
        releaseEverything(f, s);
    }
    for (engine_keys, 0..) |engine_key, key_index| {
        const is_released: bool = s.key_holds[key_index] != null and !z.isKeyDown(f.input, engine_key);
        if (z.isKeyPressed(f.input, engine_key)) {
            pressKey(f, s, key_index, z.getKeyPressTime(f.input, engine_key));
        } else if (is_released) {
            releaseKey(f, s, key_index);
        }
    }
}

/// A press or release, the moment it arrives (`AppSpec.on_input`): a playing key's press starts its note and its
/// release ends it - the sound asked for now, not at the next frame. A key the system repeats while held plays
/// nothing more; Escape, and the window losing the keyboard's focus, let go of everything.
fn onInput(f: *z.Frame, s: *State, event: z.InputEvent) void {
    s.is_input_from_events = true;
    switch (event) {
        .key_down => |down| {
            if (down.key == .escape) {
                releaseEverything(f, s);
                return;
            }
            const key_index: usize = keyIndexOfEngineKey(down.key) orelse return;
            if (down.repeat) {
                return;
            }
            pressKey(f, s, key_index, z.getKeyPressTime(f.input, down.key));
        },
        .key_up => |up| {
            const key_index: usize = keyIndexOfEngineKey(up.key) orelse return;
            releaseKey(f, s, key_index);
        },
        .focus_lost => releaseEverything(f, s),
        else => {},
    }
}

/// The pointers down this frame: every finger on the screen, or - on a device that has never reported a touch - the
/// mouse while its button is down.
fn pointersDown(
    f: *z.Frame,
    s: *State,
    pointers: *[params.limits.most_pointers]PointerDown,
) []const PointerDown {
    const touch_count: usize = @intCast(z.getTouchPointCount(f.input));
    if (touch_count > 0) {
        s.has_seen_touch = true;
    }
    var pointer_count: usize = 0;
    for (0..@min(touch_count, pointers.len)) |touch_index| {
        const touch_slot: i32 = @intCast(touch_index);
        pointers[pointer_count] = .{
            .pointer_id = z.getTouchPointId(f.input, touch_slot),
            .position = z.getTouchPosition(f.input, touch_slot),
        };
        pointer_count += 1;
    }
    const is_mouse_down: bool = z.isMouseButtonDown(f.input, .left);
    const is_mouse_counted: bool = !s.has_seen_touch and is_mouse_down and pointer_count < pointers.len;
    if (is_mouse_counted) {
        pointers[pointer_count] = .{ .pointer_id = mouse_pointer_id, .position = z.getMousePosition(f.input) };
        pointer_count += 1;
    }
    return pointers[0..pointer_count];
}

/// The pointer `pointer`, over the key at `key_now` (null off the keyboard). A pointer holding nothing takes the key
/// under it - its note, or its chord (`notesOfKeyNow`). One holding a key keeps it until it has moved
/// `params.playing.target_switch_distance` from where it took it, then lets it go and takes the key under it, as a
/// finger sliding along the keys - and keeps it over no key, so that a finger slipping past the keyboard's edge does
/// not cut its note.
fn holdWithPointer(
    f: *z.Frame,
    s: *State,
    pointer: PointerDown,
    key_now: ?usize,
) void {
    const key_index: usize = key_now orelse return;
    const held_slot: ?*?PointerHold = for (&s.pointer_holds) |*hold_slot| {
        const hold: PointerHold = hold_slot.* orelse continue;
        if (hold.pointer_id == pointer.pointer_id) {
            break hold_slot;
        }
    } else null;
    if (held_slot) |hold_slot| {
        const hold: PointerHold = hold_slot.*.?;
        const has_moved_away: bool = length(pointer.position - hold.anchor) >= params.playing.target_switch_distance;
        const keeps_its_key: bool = hold.key_index == key_index or !has_moved_away;
        if (keeps_its_key) {
            return;
        }
        const notes: KeyNotes = notesOfKeyNow(s, key_index) orelse return;
        endHold(f, s, hold.held);
        const held: HeldNotes = beginHold(f, s, notes, 0);
        hold_slot.* = .{
            .pointer_id = pointer.pointer_id,
            .key_index = key_index,
            .held = held,
            .anchor = pointer.position,
        };
        return;
    }
    const free_slot: *?PointerHold = for (&s.pointer_holds) |*hold_slot| {
        if (hold_slot.* == null) {
            break hold_slot;
        }
    } else return;
    const notes: KeyNotes = notesOfKeyNow(s, key_index) orelse return;
    const held: HeldNotes = beginHold(f, s, notes, z.getLastPressTime(f.input));
    free_slot.* = .{
        .pointer_id = pointer.pointer_id,
        .key_index = key_index,
        .held = held,
        .anchor = pointer.position,
    };
}

/// Whether a pointer holds a key.
fn isPointerHolding(s: *const State, pointer_id: i32) bool {
    for (s.pointer_holds) |hold_slot| {
        const hold: PointerHold = hold_slot orelse continue;
        if (hold.pointer_id == pointer_id) {
            return true;
        }
    }
    return false;
}

/// The pointers, each on its own - several fingers play several keys at once. A pointer lifted lets go of its key; one
/// down holds the key under it (`holdWithPointer`). While they wait to be lifted (`are_pointers_waiting_for_release`),
/// they play nothing. A pointer the header's controls have - one of their lists is open (`is_ui_capturing`), or the
/// pointer came down in the header, on a dropdown or the slider - lets go of what the pointers hold and makes them
/// wait: the slider's handle dragged down over the keys plays none of them.
fn readPointers(
    f: *z.Frame,
    s: *State,
    layout: KeyboardLayout,
    is_ui_capturing: bool,
) void {
    var pointers_buffer: [params.limits.most_pointers]PointerDown = undefined;
    const pointers: []const PointerDown = pointersDown(f, s, &pointers_buffer);
    if (s.are_pointers_waiting_for_release) {
        s.are_pointers_waiting_for_release = pointers.len > 0;
        return;
    }
    const has_pointer_come_down_in_header: bool = for (pointers) |pointer| {
        const is_in_header: bool = pointer.position[1] < params.window.header_height;
        if (is_in_header and !isPointerHolding(s, pointer.pointer_id)) {
            break true;
        }
    } else false;
    const is_pointer_for_controls: bool = pointers.len > 0 and (is_ui_capturing or has_pointer_come_down_in_header);
    if (is_pointer_for_controls) {
        releasePointers(f, s);
        return;
    }
    for (&s.pointer_holds) |*hold_slot| {
        const hold: PointerHold = hold_slot.* orelse continue;
        const is_still_down: bool = for (pointers) |pointer| {
            if (pointer.pointer_id == hold.pointer_id) {
                break true;
            }
        } else false;
        if (!is_still_down) {
            endHold(f, s, hold.held);
            hold_slot.* = null;
        }
    }
    for (pointers) |pointer| {
        holdWithPointer(f, s, pointer, keyAt(layout, pointer.position));
    }
}

// ---- Drawing ----

/// Draws `text` from `top_left`, at `size`.
fn drawText(
    f: *z.Frame,
    s: *State,
    top_left: Vec2,
    text: []const u8,
    size: f32,
    color: Color,
) void {
    f.gl.text(top_left, text, .{ .size = size, .color = color, .font = &s.font });
}

/// Draws `text` centred on `centre`, at `size`.
fn drawCentredText(
    f: *z.Frame,
    s: *State,
    centre: Vec2,
    text: []const u8,
    size: f32,
    color: Color,
) void {
    const text_size: Vec2 = z.measureText(s.font, text, size);
    const top_left: Vec2 = centre - text_size / splat2(2);
    drawText(f, s, top_left, text, size, color);
}

/// Whether a computer key or a pointer holds the key at `key_index`.
fn isKeyHeld(s: *const State, key_index: usize) bool {
    if (s.key_holds[key_index] != null) {
        return true;
    }
    for (s.pointer_holds) |hold_slot| {
        const hold: PointerHold = hold_slot orelse continue;
        if (hold.key_index == key_index) {
            return true;
        }
    }
    return false;
}

/// Whether the key at `key_index` is lit: while it is held, or while every note it plays now sounds, whatever holds
/// them. So every key playing a sounding note lights with it, wherever it is on the keyboard; and a chord's key
/// lights at its press - before its third and fifth have started - and whenever its chord's three notes all sound,
/// as when the right hand plays the chord's triangle.
fn isKeyLit(s: *const State, key_index: usize) bool {
    if (isKeyHeld(s, key_index)) {
        return true;
    }
    const notes: KeyNotes = notesOfKeyNow(s, key_index) orelse return false;
    for (notes.slice()) |sound_key| {
        if (strengthOfSoundKey(s, sound_key) == .silent) {
            return false;
        }
    }
    return true;
}

/// A rounded key cap filling `rect`, in `fill`.
fn drawKeyCap(f: *z.Frame, rect: z.Rectangle, fill: Color) void {
    f.gl.rectRoundedXYWH(
        rect.x,
        rect.y,
        rect.width,
        rect.height,
        params.keyboard.corner_roundness,
        params.keyboard.corner_segments,
        .{ .color = fill },
    );
}

/// A playing key: its cap in the stickers' colours - white for a natural note, lilac for a sharp - or green for a
/// chord's key, and orange while it is lit (`isKeyLit`); in the middle its note's name, spelled as the scale spells it
/// (`noteNameIn`), or its chord's - C, Dm, B with the degree sign (`chordLetterName`); and its own US letter small in
/// the top left corner.
fn drawPlayingKey(
    f: *z.Frame,
    s: *State,
    layout: KeyboardLayout,
    key_index: usize,
) void {
    const rect: z.Rectangle = layout.playingKeyRect(key_index);
    const tonic_pitch_class: u8 = s.scale.tonicPitchClass();
    const midi_key: ?u8 = midiKeyOf(s.layout, tonic_on_f, tonic_pitch_class, key_index);
    const key_size: f32 = layout.key_size;
    if (midi_key) |playing_midi_key| {
        const pitch_class: u8 = playing_midi_key % 12;
        const chord: ?ScaleChord = chordOfKey(s.layout, tonic_on_f, &s.scale, key_index);
        const note_fill: Color = if (is_sharp_pitch_class[pitch_class])
            params.colors.sharp_key
        else
            params.colors.natural_key;
        const resting_fill: Color = if (chord != null) params.colors.chord_key else note_fill;
        const fill: Color = if (isKeyLit(s, key_index)) params.colors.sounding_key else resting_fill;
        drawKeyCap(f, rect, fill);
        var chord_name_buffer: [8]u8 = undefined;
        const name: []const u8 = if (chord) |key_chord|
            chordLetterName(&chord_name_buffer, &s.scale, key_chord)
        else
            noteNameIn(&s.scale, pitch_class);
        const name_centre: Vec2 = .{ rect.x + rect.width / 2, rect.y + rect.height * 0.56 };
        const name_size: f32 = params.keyboard.note_name_share * key_size;
        drawCentredText(f, s, name_centre, name, name_size, params.colors.note_name);
    } else {
        drawKeyCap(f, rect, params.colors.other_key);
    }
    const letter_position: Vec2 = .{ rect.x + 0.08 * key_size, rect.y + 0.04 * key_size };
    const letter_size: f32 = params.keyboard.key_letter_share * key_size;
    drawText(f, s, letter_position, playing_keys[key_index].us_label, letter_size, params.colors.key_letter);
}

/// A key that plays nothing: a dark cap and its name, small.
fn drawOtherKey(
    f: *z.Frame,
    s: *State,
    layout: KeyboardLayout,
    key: OtherKey,
) void {
    const rect: z.Rectangle = layout.keyRect(key.row, key.left_in_keys, key.width_in_keys);
    drawKeyCap(f, rect, params.colors.other_key);
    const label_centre: Vec2 = .{ rect.x + rect.width / 2, rect.y + rect.height / 2 };
    const label_size: f32 = params.keyboard.key_letter_share * layout.key_size;
    drawCentredText(f, s, label_centre, key.label, label_size, params.colors.dim_text);
}

/// The footer's first line: the computer keys held, by their US letters - for finding which combinations a keyboard
/// cannot report together (the plan's risk R1, key rollover).
fn drawHeldKeys(f: *z.Frame, s: *State, top: f32) void {
    var line_buffer: [params.limits.held_keys_line_capacity]u8 = undefined;
    var line_length: usize = 0;
    const words: []const u8 = bufPrint(&line_buffer, "keys held:", .{}) catch "";
    line_length += words.len;
    for (s.key_holds, playing_keys) |key_hold, key| {
        if (key_hold == null) {
            continue;
        }
        const written: []const u8 = bufPrint(line_buffer[line_length..], " {s}", .{key.us_label}) catch break;
        line_length += written.len;
    }
    const line_position: Vec2 = .{ params.window.margin, top };
    drawText(f, s, line_position, line_buffer[0..line_length], params.window.line_size, params.colors.text);
}

/// The latency readout, under the keys held: the output that plays, then the latest start the mixer measured - the
/// wait for the renderer, the sound queued ahead of the note, what lies past the output, and their sum
/// (`z.mixer.Mixer.formatLatencyLine`), as `audio_keyboard` shows it, so the two can be compared.
fn drawLatencyReadout(f: *z.Frame, s: *State, top: f32) void {
    const margin: f32 = params.window.margin;
    const line_spacing: f32 = params.window.line_spacing;
    const line_size: f32 = params.window.line_size;
    const color: Color = params.colors.dim_text;
    var output_buffer: [96]u8 = undefined;
    const output_line: []const u8 = bufPrint(&output_buffer, "output: {s}", .{f.mixer.outputName()}) catch "";
    drawText(f, s, .{ margin, top }, output_line, line_size, color);
    drawText(f, s, .{ margin, top + line_spacing }, z.mixer.Mixer.latency_readout_header, line_size, color);
    var recent: [z.mixer.recent_start_capacity]z.mixer.LatencySample = undefined;
    const measured: []z.mixer.LatencySample = f.mixer.recentStarts(&recent);
    if (measured.len == 0) {
        return;
    }
    var line_buffer: [96]u8 = undefined;
    const past_output_ms: f64 = f.mixer.outputLatencyMilliseconds();
    const line: []const u8 = z.mixer.Mixer.formatLatencyLine(measured[0], past_output_ms, &line_buffer);
    drawText(f, s, .{ margin, top + 2 * line_spacing }, line, line_size, color);
}

/// The window, cleared already: under the header's controls (`buildHeader`), the legend - what the keys do; the
/// keyboard; and the footer - the keys held and the latency.
fn draw(f: *z.Frame, s: *State, layout: KeyboardLayout) void {
    const margin: f32 = params.window.margin;
    const legend: []const u8 =
        "right: a fifth up   down-right: a major third up   up-right: a minor third up   green keys: chords";
    drawText(f, s, .{ margin, params.window.legend_top }, legend, params.window.line_size, params.colors.dim_text);
    for (other_keys) |other_key| {
        drawOtherKey(f, s, layout, other_key);
    }
    for (0..playing_keys.len) |key_index| {
        drawPlayingKey(f, s, layout, key_index);
    }
    const footer_top: f32 = f.window.heightf() - params.window.footer_height + 8;
    drawHeldKeys(f, s, footer_top);
    drawLatencyReadout(f, s, footer_top + params.window.line_spacing);
}

// ---- The header's controls ----

/// Writes the header's mode list for the tonic chosen (`State.mode_labels`), each label two lines: the mode's name
/// with the notes it alters from the major scale, then its seven chords on that tonic
/// (`music_theory.writeModeLabel`, as the two-handed star's header lists them).
fn writeModeLabels(s: *State) void {
    for (&s.mode_label_buffers, &s.mode_labels, 0..) |*buffer, *label, mode_index| {
        const mode: Mode = @fromBackingInt(@intCast(mode_index));
        label.* = writeModeLabel(buffer, s.scale.tonic_letter, s.scale.tonic_accidental, mode, mode_label_columns);
    }
}

/// The widest line of the header's mode list (`State.mode_labels`), and room for the list's padding and its scroll
/// bar: the list's width, so that every mode's chords fit on their line.
fn modeListWidth(s: *const State, ui: z.ui_real.Ui) f32 {
    var widest: f32 = 0;
    for (s.mode_labels) |label| {
        var lines = splitScalar(u8, label, '\n');
        while (lines.next()) |line| {
            widest = @max(widest, ui.calcTextSize(line)[0]);
        }
    }
    return widest + ui.calcTextSize("MMM")[0];
}

/// The header's controls, built with the engine's UI along the window's top, in a window without title, border or
/// background, as the two-handed star's header: the scale - the tonic's dropdown, A to G#, and the mode's, whose list
/// shows each mode in two lines, its name with the notes it alters from the major scale, then its seven chords on the
/// tonic (`writeModeLabels`) - and the chords' volume, as a share of the other notes' strength (`State.chord_volume`).
/// A scale picked is taken at once: the tonic stays on F, every key plays its note in the new scale, and the left
/// side's chords are the new scale's. What is held sounds on as it was struck, until it is let go. Returns whether the
/// lists have the pointers: one is open, or was at the last frame - the press that closes a list is the list's.
fn buildHeader(f: *z.Frame, s: *State, ui: z.ui_real.Ui) bool {
    const margin: f32 = params.window.margin;
    ui.setNextWindowPos(.{ margin, params.window.toolbar_top }, .{});
    ui.setNextWindowSize(.{ f.window.widthf() - 2 * margin, params.window.toolbar_height }, .{});
    const toolbar_flags: z.ui_real.WindowFlags = .{
        .no_title_bar = true,
        .no_resize = true,
        .no_move = true,
        .no_background = true,
        .no_scrollbar = true,
    };
    var picked_scale: Scale = s.scale;
    if (ui.window("scale and chords", .{ .flags = toolbar_flags })) |toolbar| {
        defer toolbar.close();
        // The tonic's place in the list, A to G#, differs from its letter's number, C to B. Each dropdown's label is
        // hidden (`##`): the box shows the choice itself.
        var tonic_index: i32 = 0;
        for (listed_tonics, 0..) |tonic, listed_index| {
            const is_scale_tonic: bool = tonic.letter == s.scale.tonic_letter and
                tonic.accidental == s.scale.tonic_accidental;
            if (is_scale_tonic) {
                tonic_index = @intCast(listed_index);
            }
        }
        const arrow_room: f32 = ui.calcTextSize("MMM")[0];
        const tonic_opts: z.ui_real.ComboOpts = .{
            .width = ui.calcTextSize("G#")[0] + arrow_room,
            .max_visible_items = 7,
        };
        if (ui.combo("##tonic", &tonic_index, &listed_tonic_names, tonic_opts)) {
            const picked_tonic: ListedTonic = listed_tonics[@intCast(tonic_index)];
            picked_scale = .ofTonic(picked_tonic.letter, picked_tonic.accidental, s.scale.mode);
        }
        ui.sameLine(.{});
        writeModeLabels(s);
        var mode_index: i32 = @backingInt(s.scale.mode);
        const mode_opts: z.ui_real.ComboOpts = .{
            .width = ui.calcTextSize("Phrygian dominant")[0] + arrow_room,
            .max_visible_items = 5,
            .lines_per_item = 2,
            .list_width = modeListWidth(s, ui),
        };
        if (ui.combo("##mode", &mode_index, &s.mode_labels, mode_opts)) {
            const picked_mode: Mode = @fromBackingInt(@intCast(mode_index));
            picked_scale = .ofTonic(picked_scale.tonic_letter, picked_scale.tonic_accidental, picked_mode);
        }
        ui.sameLine(.{});
        // The chords' volume: how strongly a chord's key strikes its notes, as a share of the other notes' strength.
        const volume_opts: z.ui_real.SliderOpts = .{
            .min = 0,
            .max = 1,
            .fmt = "{d:.2}",
            .width = params.window.volume_slider_width,
        };
        _ = ui.slider("chords", &s.chord_volume, volume_opts);
    }
    s.scale = picked_scale;
    const is_list_open: bool = ui.isComboOpen();
    const is_ui_capturing: bool = is_list_open or s.was_list_open;
    s.was_list_open = is_list_open;
    return is_ui_capturing;
}

// ---- The frame ----

/// A frame: the start screen until the sound runs; then the window cleared; the header's controls built first, so
/// that a scale picked is the scale before anything reads it, and the pointers know whether a list is open; the keys
/// and pointers read - the keys only where `onInput` does not deliver them; the chords' notes whose time has come
/// started (`startDueNotesOfHolds`); the window drawn; and the controls rendered last, over it.
fn update(f: *z.Frame, s: *State) void {
    // A black screen with a start button, until it is pressed and the audio runs (`z.showAudioStartScreen`).
    if (z.showAudioStartScreen(f, &s.font)) {
        return;
    }
    z.clearViewport(f, params.colors.background);
    const ui: z.ui_real.Ui = s.ui_host.begin(f);
    const is_ui_capturing: bool = buildHeader(f, s, ui);
    const layout: KeyboardLayout = .ofWindow(f);
    if (!s.is_input_from_events) {
        readComputerKeyboard(f, s);
    }
    readPointers(f, s, layout, is_ui_capturing);
    startDueNotesOfHolds(f, s);
    draw(f, s, layout);
    s.ui_host.render(f);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - magic isomorphic keyboard",
            .width = 1000,
            .height = 560,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
    .on_input = onInput,
};

// ---- Tests ----
//
// `zig build test-magic-isomorphic-keyboard`: the layouts' arithmetic, which needs no engine. Each expectation is
// written out by hand - from the drawn layout, the photo's stickers and the second picture - not from what the code
// computes.

/// A key and the note it plays, as a picture shows it: the key's US letter, and the note's name as the stickers write
/// it.
const KeyNote = struct {
    us_label: []const u8,
    note: []const u8,
};

/// The pitch class a note's name names, as the stickers write it (`sharp_note_names`): C as 0 to B as 11, or null.
fn pitchClassNamed(note: []const u8) ?u8 {
    for (sharp_note_names, 0..) |name, pitch_class| {
        if (eql(u8, name, note)) {
            const named_pitch_class: u8 = @intCast(pitch_class);
            return named_pitch_class;
        }
    }
    return null;
}

/// Checks that each of `key_notes` plays its note under `layout` and `anchoring`, the tonic at `tonic_pitch_class`.
fn expectKeyNotes(
    key_notes: []const KeyNote,
    layout: Isomorphic,
    anchoring: Anchoring,
    tonic_pitch_class: u8,
) !void {
    for (key_notes) |key_note| {
        const key_index: usize = keyIndexLabelled(key_note.us_label) orelse return error.TestUnexpectedResult;
        const expected_pitch_class: u8 = pitchClassNamed(key_note.note) orelse return error.TestUnexpectedResult;
        const midi_key: u8 = midiKeyOf(layout, anchoring, tonic_pitch_class, key_index) orelse
            return error.TestUnexpectedResult;
        try expectEqual(expected_pitch_class, midi_key % 12);
    }
}

/// Where a triangle's third and fifth are, from its root: rows down, then keys right.
const TriangleShape = struct {
    third: [2]i16,
    fifth: [2]i16,
};

/// Checks the triangle on the key at `root_key` shaped as `shape`, if the keyboard has its other two keys: they play
/// the note `third_semitones` above the root's and the fifth above it, 7 semitones. Whether the keyboard has them.
fn expectTriangle(
    layout: Isomorphic,
    root_key: usize,
    shape: TriangleShape,
    third_semitones: u8,
) !bool {
    const root: PlayingKey = playing_keys[root_key];
    const third_key: usize = keyIndexAt(root.row + shape.third[0], root.index_in_row + shape.third[1]) orelse
        return false;
    const fifth_key: usize = keyIndexAt(root.row + shape.fifth[0], root.index_in_row + shape.fifth[1]) orelse
        return false;
    const root_midi_key: u8 = midiKeyOf(layout, tonic_on_f, 0, root_key).?;
    try expectEqual(@as(?u8, root_midi_key + third_semitones), midiKeyOf(layout, tonic_on_f, 0, third_key));
    try expectEqual(@as(?u8, root_midi_key + 7), midiKeyOf(layout, tonic_on_f, 0, fifth_key));
    return true;
}

/// Checks every triangle on `layout` shaped as a major triad is said to be and every one shaped as a minor triad, and
/// that all 24 triads are among them.
fn expectAllTriads(layout: Isomorphic, major: TriangleShape, minor: TriangleShape) !void {
    var is_major_triad_found: [12]bool = @splat(false);
    var is_minor_triad_found: [12]bool = @splat(false);
    for (0..playing_keys.len) |root_key| {
        const root_pitch_class: u8 = midiKeyOf(layout, tonic_on_f, 0, root_key).? % 12;
        if (try expectTriangle(layout, root_key, major, 4)) {
            is_major_triad_found[root_pitch_class] = true;
        }
        if (try expectTriangle(layout, root_key, minor, 3)) {
            is_minor_triad_found[root_pitch_class] = true;
        }
    }
    for (is_major_triad_found, is_minor_triad_found) |is_major_found, is_minor_found| {
        try expect(is_major_found and is_minor_found);
    }
}

test "the drawn layout: every natural note it shows, under its anchoring" {
    // Transcribed from the drawing, row by row, left to right: it writes the naturals only.
    const naturals: [29]KeyNote = .{
        .{ .us_label = "1", .note = "F" }, .{ .us_label = "2", .note = "C" }, .{ .us_label = "3", .note = "G" },
        .{ .us_label = "4", .note = "D" }, .{ .us_label = "5", .note = "A" }, .{ .us_label = "6", .note = "E" },
        .{ .us_label = "7", .note = "B" }, .{ .us_label = "Q", .note = "A" }, .{ .us_label = "W", .note = "E" },
        .{ .us_label = "E", .note = "B" }, .{ .us_label = "O", .note = "F" }, .{ .us_label = "P", .note = "C" },
        .{ .us_label = "[", .note = "G" }, .{ .us_label = "]", .note = "D" }, .{ .us_label = "\\", .note = "A" },
        .{ .us_label = "G", .note = "F" }, .{ .us_label = "H", .note = "C" }, .{ .us_label = "J", .note = "G" },
        .{ .us_label = "K", .note = "D" }, .{ .us_label = "L", .note = "A" }, .{ .us_label = ";", .note = "E" },
        .{ .us_label = "'", .note = "B" }, .{ .us_label = "Z", .note = "F" }, .{ .us_label = "X", .note = "C" },
        .{ .us_label = "C", .note = "G" }, .{ .us_label = "V", .note = "D" }, .{ .us_label = "B", .note = "A" },
        .{ .us_label = "N", .note = "E" }, .{ .us_label = "M", .note = "B" },
    };
    try expectKeyNotes(&naturals, fifths_layout, drawing_anchoring, 0);
}

test "the tonic on F, fifths along the rows: the home row's D to L is the major scale, in C and in G" {
    const c_major_home_row: [7]KeyNote = .{
        .{ .us_label = "D", .note = "F" }, .{ .us_label = "F", .note = "C" }, .{ .us_label = "G", .note = "G" },
        .{ .us_label = "H", .note = "D" }, .{ .us_label = "J", .note = "A" }, .{ .us_label = "K", .note = "E" },
        .{ .us_label = "L", .note = "B" },
    };
    const g_major_home_row: [7]KeyNote = .{
        .{ .us_label = "D", .note = "C" },  .{ .us_label = "F", .note = "G" }, .{ .us_label = "G", .note = "D" },
        .{ .us_label = "H", .note = "A" },  .{ .us_label = "J", .note = "E" }, .{ .us_label = "K", .note = "B" },
        .{ .us_label = "L", .note = "F#" },
    };
    try expectKeyNotes(&c_major_home_row, fifths_layout, tonic_on_f, 0);
    try expectKeyNotes(&g_major_home_row, fifths_layout, tonic_on_f, 7);
}

test "the tonic on F in C major, fifths along the rows: C4 on F, C1 at the backquote, B8 at the backslash" {
    const f_key: usize = keyIndexLabelled("F").?;
    const backquote_key: usize = keyIndexLabelled("`").?;
    const backslash_key: usize = keyIndexLabelled("\\").?;
    try expectEqual(@as(?u8, 60), midiKeyOf(fifths_layout, tonic_on_f, 0, f_key));
    try expectEqual(@as(?u8, 24), midiKeyOf(fifths_layout, tonic_on_f, 0, backquote_key));
    try expectEqual(@as(?u8, 119), midiKeyOf(fifths_layout, tonic_on_f, 0, backslash_key));
}

// Fifths along the rows: a major triad is a root, the key to its right and the key below between them; a minor
// triad, a root, the key above on its right and the key to its right.
test "fifths along the rows: every major and minor triangle, and all 24 triads" {
    const major: TriangleShape = .{ .third = .{ 1, 0 }, .fifth = .{ 0, 1 } };
    const minor: TriangleShape = .{ .third = .{ -1, 1 }, .fifth = .{ 0, 1 } };
    try expectAllTriads(fifths_layout, major, minor);
}

test "the photo: all 41 stickers, under the stickers' own anchoring" {
    // Transcribed from the photo, row by row, left to right.
    const stickers: [41]KeyNote = .{
        .{ .us_label = "1", .note = "C" },  .{ .us_label = "2", .note = "A" },  .{ .us_label = "3", .note = "F#" },
        .{ .us_label = "4", .note = "D#" }, .{ .us_label = "5", .note = "C" },  .{ .us_label = "6", .note = "A" },
        .{ .us_label = "7", .note = "F#" }, .{ .us_label = "8", .note = "D#" }, .{ .us_label = "9", .note = "C" },
        .{ .us_label = "0", .note = "A" },  .{ .us_label = "-", .note = "F#" }, .{ .us_label = "Q", .note = "F" },
        .{ .us_label = "W", .note = "D" },  .{ .us_label = "E", .note = "B" },  .{ .us_label = "R", .note = "G#" },
        .{ .us_label = "T", .note = "F" },  .{ .us_label = "Y", .note = "D" },  .{ .us_label = "U", .note = "B" },
        .{ .us_label = "I", .note = "G#" }, .{ .us_label = "O", .note = "F" },  .{ .us_label = "P", .note = "D" },
        .{ .us_label = "[", .note = "B" },  .{ .us_label = "A", .note = "A#" }, .{ .us_label = "S", .note = "G" },
        .{ .us_label = "D", .note = "E" },  .{ .us_label = "F", .note = "C#" }, .{ .us_label = "G", .note = "A#" },
        .{ .us_label = "H", .note = "G" },  .{ .us_label = "J", .note = "E" },  .{ .us_label = "K", .note = "C#" },
        .{ .us_label = "L", .note = "A#" }, .{ .us_label = ";", .note = "G" },  .{ .us_label = "Z", .note = "D#" },
        .{ .us_label = "X", .note = "C" },  .{ .us_label = "C", .note = "A" },  .{ .us_label = "V", .note = "F#" },
        .{ .us_label = "B", .note = "D#" }, .{ .us_label = "N", .note = "C" },  .{ .us_label = "M", .note = "A" },
        .{ .us_label = ",", .note = "F#" }, .{ .us_label = ".", .note = "D#" },
    };
    try expectKeyNotes(&stickers, thirds_layout, stickers_anchoring, 0);
}

test "the photo's layout with the tonic on F: C major and G major as the second picture lays them out" {
    const c_major_keys: [9]KeyNote = .{
        .{ .us_label = "F", .note = "C" }, .{ .us_label = "4", .note = "D" }, .{ .us_label = "B", .note = "D" },
        .{ .us_label = "T", .note = "E" }, .{ .us_label = "V", .note = "F" }, .{ .us_label = "R", .note = "G" },
        .{ .us_label = "G", .note = "A" }, .{ .us_label = "5", .note = "B" }, .{ .us_label = "X", .note = "B" },
    };
    const g_major_keys: [7]KeyNote = .{
        .{ .us_label = "F", .note = "G" },  .{ .us_label = "4", .note = "A" }, .{ .us_label = "T", .note = "B" },
        .{ .us_label = "V", .note = "C" },  .{ .us_label = "R", .note = "D" }, .{ .us_label = "G", .note = "E" },
        .{ .us_label = "5", .note = "F#" },
    };
    try expectKeyNotes(&c_major_keys, thirds_layout, tonic_on_f, 0);
    try expectKeyNotes(&g_major_keys, thirds_layout, tonic_on_f, 7);
}

// The photo's layout: a major triad is a root and the two keys above it; a minor triad, a root, the key to its left
// and the key above between them.
test "the photo's layout: every major and minor triangle, and all 24 triads" {
    const major: TriangleShape = .{ .third = .{ -1, 1 }, .fifth = .{ -1, 0 } };
    const minor: TriangleShape = .{ .third = .{ 0, -1 }, .fifth = .{ -1, 0 } };
    try expectAllTriads(thirds_layout, major, minor);
}

/// A key and the notes it plays, as a hand writes them: the key's US letter, and the notes' names in the order they
/// start - one for a note; a chord's root, third and fifth.
const KeyPlays = struct {
    us_label: []const u8,
    notes: []const []const u8,
};

/// Checks that each of `key_plays` plays its notes, in their order, under the layout played - fifths along the rows,
/// the tonic on F - in `scale`; and that it holds one note fully, a chord's three softly.
fn expectKeyPlays(key_plays: []const KeyPlays, scale: *const Scale) !void {
    for (key_plays) |key_play| {
        const key_index: usize = keyIndexLabelled(key_play.us_label) orelse return error.TestUnexpectedResult;
        const notes: KeyNotes = notesOfKey(fifths_layout, tonic_on_f, scale, key_index) orelse
            return error.TestUnexpectedResult;
        try expectEqual(key_play.notes.len, notes.count);
        const expected_layer: HoldLayer = if (key_play.notes.len == 1) .full else .chord;
        try expectEqual(expected_layer, notes.layer);
        for (key_play.notes, notes.slice()) |note, sound_key| {
            const expected_pitch_class: u8 = pitchClassNamed(note) orelse return error.TestUnexpectedResult;
            try expectEqual(60 + expected_pitch_class, sound_key);
        }
    }
}

test "the left side in C major: a major chord on C, F and G, a minor one on D, E and A, the diminished one on B" {
    // Each chord spelled by hand - root, third, fifth - on every left-side key that plays its root.
    const chord_keys: [15]KeyPlays = .{
        .{ .us_label = "F", .notes = &.{ "C", "E", "G" } }, .{ .us_label = "`", .notes = &.{ "C", "E", "G" } },
        .{ .us_label = "X", .notes = &.{ "D", "F", "A" } }, .{ .us_label = "2", .notes = &.{ "D", "F", "A" } },
        .{ .us_label = "V", .notes = &.{ "E", "G", "B" } }, .{ .us_label = "4", .notes = &.{ "E", "G", "B" } },
        .{ .us_label = "D", .notes = &.{ "F", "A", "C" } }, .{ .us_label = "G", .notes = &.{ "G", "B", "D" } },
        .{ .us_label = "1", .notes = &.{ "G", "B", "D" } }, .{ .us_label = "Z", .notes = &.{ "G", "B", "D" } },
        .{ .us_label = "C", .notes = &.{ "A", "C", "E" } }, .{ .us_label = "3", .notes = &.{ "A", "C", "E" } },
        .{ .us_label = "B", .notes = &.{ "B", "D", "F" } }, .{ .us_label = "5", .notes = &.{ "B", "D", "F" } },
        .{ .us_label = "Q", .notes = &.{ "B", "D", "F" } },
    };
    try expectKeyPlays(&chord_keys, &c_major);
    const f_key: usize = keyIndexLabelled("F").?;
    const x_key: usize = keyIndexLabelled("X").?;
    const b_key: usize = keyIndexLabelled("B").?;
    try expectEqual(music_theory.ChordQuality.major, chordOfKey(fifths_layout, tonic_on_f, &c_major, f_key).?.quality);
    try expectEqual(music_theory.ChordQuality.minor, chordOfKey(fifths_layout, tonic_on_f, &c_major, x_key).?.quality);
    try expectEqual(
        music_theory.ChordQuality.diminished,
        chordOfKey(fifths_layout, tonic_on_f, &c_major, b_key).?.quality,
    );
}

test "the left side's sharps in C major, and every key right of 5 T G B, play their own note" {
    const note_keys: [12]KeyPlays = .{
        .{ .us_label = "W", .notes = &.{"F#"} }, .{ .us_label = "E", .notes = &.{"C#"} },
        .{ .us_label = "R", .notes = &.{"G#"} }, .{ .us_label = "T", .notes = &.{"D#"} },
        .{ .us_label = "A", .notes = &.{"D#"} }, .{ .us_label = "S", .notes = &.{"A#"} },
        .{ .us_label = "6", .notes = &.{"F#"} }, .{ .us_label = "Y", .notes = &.{"A#"} },
        .{ .us_label = "H", .notes = &.{"D"} },  .{ .us_label = "N", .notes = &.{"F#"} },
        .{ .us_label = "I", .notes = &.{"C"} },  .{ .us_label = "K", .notes = &.{"E"} },
    };
    try expectKeyPlays(&note_keys, &c_major);
    const h_key: usize = keyIndexLabelled("H").?;
    const w_key: usize = keyIndexLabelled("W").?;
    try expectEqual(@as(?ScaleChord, null), chordOfKey(fifths_layout, tonic_on_f, &c_major, h_key));
    try expectEqual(@as(?ScaleChord, null), chordOfKey(fifths_layout, tonic_on_f, &c_major, w_key));
}

test "the left side in G major: the chords move with the scale, each on the same key" {
    // G major: G A B C D E F#. The tonic's chord stays on F, the fourth's on D, the fifth's on G.
    const g_major: Scale = .of(4, .ionian);
    const key_plays: [10]KeyPlays = .{
        .{ .us_label = "F", .notes = &.{ "G", "B", "D" } },  .{ .us_label = "D", .notes = &.{ "C", "E", "G" } },
        .{ .us_label = "G", .notes = &.{ "D", "F#", "A" } }, .{ .us_label = "X", .notes = &.{ "A", "C", "E" } },
        .{ .us_label = "V", .notes = &.{ "B", "D", "F#" } }, .{ .us_label = "C", .notes = &.{ "E", "G", "B" } },
        .{ .us_label = "B", .notes = &.{ "F#", "A", "C" } }, .{ .us_label = "S", .notes = &.{"F"} },
        .{ .us_label = "A", .notes = &.{"A#"} },             .{ .us_label = "W", .notes = &.{"C#"} },
    };
    try expectKeyPlays(&key_plays, &g_major);
}
