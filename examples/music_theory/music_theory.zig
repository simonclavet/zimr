//! lint:alias music_theory
//! examples/music_theory - the music theory the scale demos share, each piece in one place: the scales and how they
//! spell their notes, the chords on their degrees and their numerals, the progressions to learn and the songs' keys,
//! the tonics and modes the options offer, and the name of the chord a set of notes makes.
//!
//! It was `audio_scale_star_hands`' own until the magic isomorphic keyboard needed it too
//! (`src/notes/magic_isomorphic_keyboard_plan.md`, D2). It imports `std` alone - no engine, no math - so its tests run
//! on their own: `zig build test-music-theory`.
const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;
const endsWith = std.mem.endsWith;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectEqualStrings = std.testing.expectEqualStrings;

// ---- The scale ----

/// The degrees of a scale, 1 (its tonic) to 7, for walking through them.
pub const all_degrees = [7]u8{ 1, 2, 3, 4, 5, 6, 7 };

/// The degree `steps` scale steps above `degree`, within one octave: 6 and 2 steps up is 1.
pub fn degreeAbove(degree: u8, steps: u8) u8 {
    return (degree - 1 + steps) % 7 + 1;
}

/// The natural notes' pitch classes, C to B: C 0, D 2, E 4, F 5, G 7, A 9, B 11 - the white keys of a piano.
pub const natural_semitones = [7]u8{ 0, 2, 4, 5, 7, 9, 11 };

/// A note's name by its letter and its accidental: double flat, flat, natural, sharp or double sharp - two semitones
/// below the natural note to two above it. And its solfege syllable, fixed to the letter as French names notes - do
/// is always C - with the same accidental: re# is D sharp. A natural tonic's scales need no double accidental; a few
/// on a sharp tonic do - G# Ionian's seventh is F##.
pub const spelled_note_names = [7][5][]const u8{
    .{ "Cbb", "Cb", "C", "C#", "C##" },
    .{ "Dbb", "Db", "D", "D#", "D##" },
    .{ "Ebb", "Eb", "E", "E#", "E##" },
    .{ "Fbb", "Fb", "F", "F#", "F##" },
    .{ "Gbb", "Gb", "G", "G#", "G##" },
    .{ "Abb", "Ab", "A", "A#", "A##" },
    .{ "Bbb", "Bb", "B", "B#", "B##" },
};
/// The solfege syllables, by letter and accidental, as `spelled_note_names` gives the letters' names.
pub const spelled_solfege_names = [7][5][]const u8{
    .{ "dobb", "dob", "do", "do#", "do##" },
    .{ "rebb", "reb", "re", "re#", "re##" },
    .{ "mibb", "mib", "mi", "mi#", "mi##" },
    .{ "fabb", "fab", "fa", "fa#", "fa##" },
    .{ "solbb", "solb", "sol", "sol#", "sol##" },
    .{ "labb", "lab", "la", "la#", "la##" },
    .{ "sibb", "sib", "si", "si#", "si##" },
};

/// The scales to play in: the seven modes of the diatonic scale, and four other scales of seven notes. Each mode is the
/// same pattern of steps - five whole steps and two half steps, the half steps as far apart as they can be - begun on
/// another of its seven notes: Ionian from the first, the major scale (W W H W W W H); Dorian from the second (W H W
/// W W H W); and so on to Locrian from the seventh. Each has its own colour: where its half steps fall from its tonic
/// decides which of its triads are major and which minor. The other four each alter a mode by a semitone or two, and
/// bring in the chords that songs borrow most:
///
///     harmonic minor      Aeolian with its 7th raised - a leading tone, so its V is major
///                         (i, ii dim, III aug, iv, V, VI, vii dim)
///     melodic minor       Aeolian with its 6th and 7th raised - its IV and V major
///                         (i, ii, III aug, IV, V, vi dim, vii dim)
///     harmonic major      Ionian with its 6th lowered - the minor iv of the minor key
///                         (I, ii dim, iii, iv, V, VI aug, vii dim)
///     Phrygian dominant   harmonic minor from its 5th - Phrygian with its 3rd raised
///                         (I, II, iii dim, iv, v dim, VI aug, vii)
///
/// Every one still has seven notes, a letter each, so the star, the chooser and the key's window lay them out as
/// they do the modes; their raised notes bring augmented triads (`ChordQuality.augmented`), and two diminished ones.
pub const Mode = enum(u4) {
    ionian,
    dorian,
    phrygian,
    lydian,
    mixolydian,
    aeolian,
    locrian,
    harmonic_minor,
    melodic_minor,
    harmonic_major,
    phrygian_dominant,

    /// The mode's name, as the dropdown lists it.
    pub fn label(mode: Mode) []const u8 {
        return switch (mode) {
            .ionian => "Ionian",
            .dorian => "Dorian",
            .phrygian => "Phrygian",
            .lydian => "Lydian",
            .mixolydian => "Mixolydian",
            .aeolian => "Aeolian",
            .locrian => "Locrian",
            .harmonic_minor => "Harmonic minor",
            .melodic_minor => "Melodic minor",
            .harmonic_major => "Harmonic major",
            .phrygian_dominant => "Phrygian dominant",
        };
    }

    /// The semitones above the tonic of each degree: the major scale's (`natural_semitones`, C to B) read from the
    /// mode's own starting note, each counted from that note and wrapped into the octave. Dorian, from the second
    /// note: 2 4 5 7 9 11 0, less 2, is 0 2 3 5 7 9 10.
    /// The four other scales are given as their semitones directly: harmonic minor 0 2 3 5 7 8 11, melodic minor
    /// 0 2 3 5 7 9 11, harmonic major 0 2 4 5 7 8 11, Phrygian dominant 0 1 4 5 7 8 10.
    pub fn semitonesAboveTonic(mode: Mode) [7]u8 {
        switch (mode) {
            .harmonic_minor => return .{ 0, 2, 3, 5, 7, 8, 11 },
            .melodic_minor => return .{ 0, 2, 3, 5, 7, 9, 11 },
            .harmonic_major => return .{ 0, 2, 4, 5, 7, 8, 11 },
            .phrygian_dominant => return .{ 0, 1, 4, 5, 7, 8, 10 },
            .ionian, .dorian, .phrygian, .lydian, .mixolydian, .aeolian, .locrian => {},
        }
        const start: usize = @backingInt(mode);
        var semitones: [7]u8 = undefined;
        for (&semitones, 0..) |*semitone, degree_index| {
            const major_semitone: u8 = natural_semitones[(start + degree_index) % 7];
            semitone.* = (major_semitone + 12 - natural_semitones[start]) % 12;
        }
        return semitones;
    }
};

/// What a triad of the scale is: major (a major third, then a minor third above it), minor (a minor third, then a
/// major third), diminished (two minor thirds, its fifth a semitone short of a perfect fifth) or augmented (two major
/// thirds, its fifth a semitone past). Every mode has three of each of the first two and one diminished - on different
/// degrees: in the major scale the triads on degrees 1, 4 and 5 are major, on 2, 3 and 6 minor, and on 7 diminished.
/// The scales with a raised note (`Mode`) have an augmented triad, which sits with the major ones - its third is major
/// - and two diminished ones.
pub const ChordQuality = enum { major, minor, diminished, augmented };

/// The Roman numerals of the triads, by degree: upper case for a major triad, upper case with a plus for an augmented
/// one, lower case for a minor one, lower case with a degree sign for a diminished one.
pub const major_numerals = [7][]const u8{ "I", "II", "III", "IV", "V", "VI", "VII" };
/// The augmented triads' numerals: upper case with a plus.
pub const augmented_numerals = [7][]const u8{ "I+", "II+", "III+", "IV+", "V+", "VI+", "VII+" };
/// The minor triads' numerals: lower case.
pub const minor_numerals = [7][]const u8{ "i", "ii", "iii", "iv", "v", "vi", "vii" };
/// The diminished triads' numerals: lower case with a degree sign.
pub const diminished_numerals = [7][]const u8{
    "i\u{00b0}",
    "ii\u{00b0}",
    "iii\u{00b0}",
    "iv\u{00b0}",
    "v\u{00b0}",
    "vi\u{00b0}",
    "vii\u{00b0}",
};

/// A chord of the scale: the degree of its root and its quality.
pub const ScaleChord = struct {
    /// The degree the chord is built on, 1 to 7.
    root_degree: u8,
    /// Its quality, from its semitones: major, minor, diminished or augmented.
    quality: ChordQuality,

    /// The chord's three notes, as degrees: its root, the third above it, the fifth above it - each two scale steps
    /// above the one before, wrapping past 7 back to 1.
    pub fn degrees(chord: ScaleChord) [3]u8 {
        const root: u8 = chord.root_degree;
        return .{ root, degreeAbove(root, 2), degreeAbove(root, 4) };
    }

    /// Whether the chord is drawn on the minor side: inside the circle, as a circle - the chords whose third is minor.
    /// An augmented chord's is major: it sits with the major ones.
    pub fn isMinorSide(chord: ScaleChord) bool {
        return chord.quality == .minor or chord.quality == .diminished;
    }

    /// The chord's name: its root's degree as a Roman numeral, in the case and with the sign of its quality.
    pub fn numeral(chord: ScaleChord) []const u8 {
        const index: usize = chord.root_degree - 1;
        return switch (chord.quality) {
            .major => major_numerals[index],
            .minor => minor_numerals[index],
            .diminished => diminished_numerals[index],
            .augmented => augmented_numerals[index],
        };
    }
};

/// A scale: its tonic - a letter, C as 0 to B as 6, and an accidental - and its mode, and what follows from them for
/// each degree: its semitones above the tonic, and the triad built on it. Everything the app draws and plays is read
/// from here; only the colours, the shapes' places and the degrees themselves are the scale's own whatever its key.
pub const Scale = struct {
    /// The tonic's letter, C as 0 to B as 6.
    tonic_letter: u8,
    /// The tonic's accidental: 0 for a natural tonic, 1 for a sharp one - C# is C's letter, a semitone up.
    tonic_accidental: i8 = 0,
    /// The mode: which degrees are raised or lowered from the major scale's.
    mode: Mode,
    /// Each degree's semitones above the tonic, the tonic's 0 first.
    semitones: [7]u8,
    /// The triad on each degree, the tonic's first.
    chords: [7]ScaleChord,
    /// Each degree's alteration from the scale its tonic and mode give: +1 raised a semitone, -1 lowered, 0 as it is
    /// (`altered`). A degree keeps its letter: G raised is G sharp.
    alterations: [7]i8 = @splat(0),

    /// The scale on the natural note `tonic_letter` in `mode` (`ofTonic`).
    pub fn of(tonic_letter: u8, mode: Mode) Scale {
        return ofTonic(tonic_letter, 0, mode);
    }

    /// The scale on the tonic `tonic_letter` with `tonic_accidental` - 1 for a sharp - in `mode`. A triad's quality is
    /// read from its thirds: the semitones from its root up to its third, then to its fifth - four and seven a major
    /// triad, three and seven a minor one, three and six the diminished one.
    pub fn ofTonic(tonic_letter: u8, tonic_accidental: i8, mode: Mode) Scale {
        const semitones: [7]u8 = mode.semitonesAboveTonic();
        return .{
            .tonic_letter = tonic_letter,
            .tonic_accidental = tonic_accidental,
            .mode = mode,
            .semitones = semitones,
            .chords = chordsOfSemitones(semitones),
        };
    }

    /// The tonic's natural pitch class, C as 0, moved by its accidental.
    pub fn tonicPitchClass(scale: *const Scale) u8 {
        const tonic_semitone: i16 = @as(i16, natural_semitones[scale.tonic_letter]) + scale.tonic_accidental;
        return @intCast(@mod(tonic_semitone, 12));
    }

    /// The triads on the seven degrees whose semitones above the tonic are `semitones`.
    pub fn chordsOfSemitones(semitones: [7]u8) [7]ScaleChord {
        var chords: [7]ScaleChord = undefined;
        for (&chords, all_degrees) |*chord, root_degree| {
            const root_semitone: u8 = semitones[root_degree - 1];
            const third_semitone: u8 = semitones[degreeAbove(root_degree, 2) - 1];
            const fifth_semitone: u8 = semitones[degreeAbove(root_degree, 4) - 1];
            const third_size: u8 = (third_semitone + 12 - root_semitone) % 12;
            const fifth_size: u8 = (fifth_semitone + 12 - root_semitone) % 12;
            const quality: ChordQuality = if (fifth_size == 6)
                .diminished
            else if (fifth_size == 8)
                .augmented
            else if (third_size == 4)
                .major
            else
                .minor;
            chord.* = .{ .root_degree = root_degree, .quality = quality };
        }
        return chords;
    }

    /// The scale with `alterations` (`Scale.alterations`) on its own notes - each degree's semitones moved by its
    /// alteration, the triads read again from the new semitones. `scale` is the scale as its tonic and mode give it,
    /// unaltered.
    pub fn altered(scale: Scale, alterations: [7]i8) Scale {
        var semitones: [7]u8 = scale.semitones;
        for (&semitones, alterations) |*semitone, alteration| {
            const moved: i16 = @as(i16, semitone.*) + alteration;
            semitone.* = @intCast(@mod(moved, 12));
        }
        return .{
            .tonic_letter = scale.tonic_letter,
            .tonic_accidental = scale.tonic_accidental,
            .mode = scale.mode,
            .semitones = semitones,
            .chords = chordsOfSemitones(semitones),
            .alterations = alterations,
        };
    }

    /// What `chord` - a triad on one of the scale's degrees, of any quality - asks of the scale: its third and its
    /// fifth each moved by the semitone the scale's own are off from the chord's - a major or augmented triad's third
    /// four semitones above its root, a minor or diminished one's three; a fifth seven, six diminished, eight
    /// augmented. In C major, E major (III) raises G to G sharp; D major (II) raises F; F minor (iv) lowers A. The root
    /// is the scale's own. A move of more than a semitone, or one whose note would need a second sharp or flat, is not
    /// made: the chord then keeps the scale's note, the nearest it can sound.
    pub fn alterationsForChord(scale: *const Scale, chord: ScaleChord) [7]i8 {
        var alterations: [7]i8 = @splat(0);
        const root_semitone: u8 = scale.semitones[chord.root_degree - 1];
        const wanted_third: u8 = switch (chord.quality) {
            .major, .augmented => 4,
            .minor, .diminished => 3,
        };
        const wanted_fifth: u8 = switch (chord.quality) {
            .major, .minor => 7,
            .diminished => 6,
            .augmented => 8,
        };
        const parts = [2][2]u8{
            .{ degreeAbove(chord.root_degree, 2), wanted_third },
            .{ degreeAbove(chord.root_degree, 4), wanted_fifth },
        };
        for (parts) |part| {
            const part_degree: u8 = part[0];
            const actual_size: u8 = (scale.semitones[part_degree - 1] + 12 - root_semitone) % 12;
            const change: i8 = @as(i8, @intCast(part[1])) - @as(i8, @intCast(actual_size));
            if (change != -1 and change != 1) {
                continue;
            }
            // The note moved keeps its letter, with at most two sharps or flats (`spellingOf`).
            const letter: u8 = (scale.tonic_letter + part_degree - 1) % 7;
            const moved_pitch_class: i16 = @as(i16, scale.pitchClassOfDegree(part_degree)) + change;
            const accidental: i16 = @mod(moved_pitch_class + 2 - natural_semitones[letter], 12);
            if (accidental > 4) {
                continue;
            }
            alterations[part_degree - 1] = change;
        }
        return alterations;
    }

    /// The triad on `degree`.
    pub fn chordOf(scale: *const Scale, degree: u8) ScaleChord {
        return scale.chords[degree - 1];
    }

    /// The pitch class of `degree`, C as 0 to B as 11: the tonic's pitch class and the degree's semitones above it,
    /// round the octave.
    pub fn pitchClassOfDegree(scale: *const Scale, degree: u8) u4 {
        return @intCast((scale.tonicPitchClass() + scale.semitones[degree - 1]) % 12);
    }

    /// The degree at pitch class `pitch_class`, or null for the five the scale does not use.
    pub fn degreeOfPitchClass(scale: *const Scale, pitch_class: u4) ?u8 {
        for (all_degrees) |degree| {
            if (scale.pitchClassOfDegree(degree) == pitch_class) {
                return degree;
            }
        }
        return null;
    }

    /// How `degree` is spelled: its letter - the tonic's, one letter a degree on, as every scale names each letter
    /// once - and its accidental, the semitones between the degree's pitch class and that letter's natural note: 0 a
    /// double flat, 1 a flat, 2 natural, 3 a sharp, 4 a double sharp. A natural tonic in any of the modes needs no
    /// more than one sharp or one flat a note - B Lydian has an E sharp, F Locrian a C flat; a sharp tonic, in a few,
    /// a double sharp - G# Ionian's F##.
    pub const Spelling = struct {
        /// The letter, C as 0 to B as 6.
        letter: u8,
        /// The accidental, shifted by two: 0 a double flat to 4 a double sharp.
        accidental: u8,
    };

    /// How `degree` is spelled in `scale` (`Spelling`).
    pub fn spellingOf(scale: *const Scale, degree: u8) Spelling {
        const letter: u8 = (scale.tonic_letter + degree - 1) % 7;
        const pitch_class: u8 = scale.pitchClassOfDegree(degree);
        // -2 to +2 semitones from the natural note, shifted to 0 to 4.
        const accidental: u8 = (pitch_class + 12 + 2 - natural_semitones[letter]) % 12;
        return .{ .letter = letter, .accidental = accidental };
    }

    /// The name of `degree`'s note, spelled in the scale: F# in D major, Bb in F major.
    pub fn noteName(scale: *const Scale, degree: u8) []const u8 {
        const spelling: Spelling = scale.spellingOf(degree);
        return spelled_note_names[spelling.letter][spelling.accidental];
    }

    /// The solfege syllable of `degree`'s note, fixed to its letter, with its accidental.
    pub fn solfegeName(scale: *const Scale, degree: u8) []const u8 {
        const spelling: Spelling = scale.spellingOf(degree);
        return spelled_solfege_names[spelling.letter][spelling.accidental];
    }

    /// The MIDI key of `degree`: the tonic in the octave of middle C (MIDI key 60 to 71), the degree's semitones above
    /// it. A Shepard note ignores the octave - only the key's pitch class chooses its partials - but the keys stay
    /// those of one real octave, so that another instrument plays them as they are.
    pub fn midiKeyOfDegree(scale: *const Scale, degree: u8) u8 {
        const tonic_key: u8 = 60 + scale.tonicPitchClass();
        return tonic_key + scale.semitones[degree - 1];
    }

    /// Whether `chord` is one of the scale's two main chords, drawn larger: the tonic's own triad, and its relative -
    /// the triad that shares two of its notes from a third below: vi for a major tonic, III for a minor or diminished
    /// one.
    pub fn isMainChord(scale: *const Scale, chord: ScaleChord) bool {
        const tonic_chord: ScaleChord = scale.chordOf(1);
        const relative_degree: u8 = if (tonic_chord.quality == .major) 6 else 3;
        return chord.root_degree == 1 or chord.root_degree == relative_degree;
    }
};

/// The scale the app starts in: C major.
pub const c_major: Scale = .of(0, .ionian);

/// Where a degree sits on the circle of thirds, counted clockwise from the top: 0 for 1, then 1 for 3, 2 for 5, 3 for
/// 7, 4 for 2, 5 for 4, 6 for 6. Walking the circle adds two degrees a place, so the place of a degree undoes that
/// walk: multiplying by 4 undoes multiplying by 2, since 2 x 4 = 8, which is 1 more than a whole circle of 7.
pub fn circlePlaceOfDegree(degree: u8) u8 {
    return (4 * (degree - 1)) % 7;
}

/// The degree at a place of the circle of thirds, the walk `circlePlaceOfDegree` undoes: two degrees a place from 1.
pub fn degreeAtPlace(circle_place: u8) u8 {
    return (2 * circle_place) % 7 + 1;
}

comptime {
    // The circle of thirds as the drawing needs it, checked when compiling: every degree has a place of its own, and
    // every chord is three neighbours - its third one place clockwise of its root, its fifth two places.
    var is_place_taken: [7]bool = @splat(false);
    for (all_degrees) |degree| {
        const place: u8 = circlePlaceOfDegree(degree);
        if (is_place_taken[place]) {
            @compileError("two degrees share a place on the circle of thirds");
        }
        is_place_taken[place] = true;
    }
    for (c_major.chords) |chord| {
        const chord_degrees: [3]u8 = chord.degrees();
        const root_place: u8 = circlePlaceOfDegree(chord_degrees[0]);
        const is_third_next: bool = circlePlaceOfDegree(chord_degrees[1]) == (root_place + 1) % 7;
        const is_fifth_after: bool = circlePlaceOfDegree(chord_degrees[2]) == (root_place + 2) % 7;
        if (!is_third_next or !is_fifth_after) {
            @compileError("a chord's notes are not three neighbours on the circle of thirds");
        }
    }
}

// ---- Progressions ----

/// A chord a progression borrows from outside the scale: the step it is at, and its quality there.
pub const ProgressionBorrowing = struct {
    /// The step of the progression it is at, from 0.
    step: u8,
    /// Its quality there, other than the scale's chord's on that degree.
    quality: ChordQuality,
};

/// The key of a song's recording, for playing along with it in tune: the key as musicians name it, and the scale to
/// choose for the progression's numbers to give the recording's chords. The numbers count from the relative major, as
/// Nashville numbers do - Hotel California's 6-3-5-2 is Bm-F#-A-E counted from D - so a minor song's scale is its
/// relative major's tonic, Ionian, not its own tonic in Aeolian; a major song's is its own tonic.
pub const SongKey = struct {
    /// Which version, where the song has several in other keys: "Sinatra".
    version: []const u8 = "",
    /// The key as it is named: "B minor".
    name: []const u8,
    /// The tonic to choose, in Ionian, as the tonics offered name it: "D", "G#". Chosen for the player when the song is
    /// (`songKeyTonic`).
    ionian_tonic: []const u8,
};

/// A chord progression to learn (`drawProgressionTrack`): its name, if it is a piece's or a kind's, its chords' roots
/// as Nashville numbers write them - the scale's degrees, 1 the tonic, so that a progression is the same in every key
/// - and as degrees to play. A song in a minor key is numbered from its relative major, as Nashville numbers do: its
/// tonic is 6. Its chords are the scale's own on their degrees, but for the ones it borrows (`borrowings`): Hotel
/// California's chords on 3 and 2 are major, where the scale's own are minor. A borrowed chord is shown as itself -
/// its numeral and its name - on its way to the button of the scale's chord on the same root, the nearest the
/// chooser has. A flat seven, `b7`, is the major chord a whole step below the tonic: in Mixolydian, Dorian and Aeolian
/// it is the scale's own chord on 7; in Ionian and Lydian the chord on 7 is the one nearest it.
pub const Progression = struct {
    /// Its name, if it has one - a song's, or a kind's, "Andalusian cadence".
    name: []const u8 = "",
    /// Its chords' roots in Nashville numbers, as shown: "1-5-6-4".
    nashville: []const u8,
    /// Its chords' roots as degrees, 1 to 7, in order.
    degrees: []const u8,
    /// The chords it borrows from outside the scale, by step (`ProgressionBorrowing`); none for most.
    borrowings: []const ProgressionBorrowing = &.{},
    /// A song's key in the recording one plays along with; none for the progressions that are forms rather than songs.
    original_key: ?SongKey = null,
};

/// The chord at `step` of `progression` in `scale`: the scale's chord on the step's degree, or the borrowed chord on
/// that root, if the progression borrows one there.
pub fn progressionChord(
    scale: *const Scale,
    progression: Progression,
    step: usize,
) ScaleChord {
    const degree: u8 = progression.degrees[step];
    var chord: ScaleChord = scale.chords[degree - 1];
    for (progression.borrowings) |borrowing| {
        if (borrowing.step == step) {
            chord.quality = borrowing.quality;
        }
    }
    return chord;
}

/// The progressions offered in the options: the common ones of pop, rock and jazz first, then famous pieces' and kinds'
/// longer ones, by name.
pub const progressions = [_]Progression{
    .{ .nashville = "1-4-5-1", .degrees = &.{ 1, 4, 5, 1 } },
    .{ .nashville = "1-6-4-5", .degrees = &.{ 1, 6, 4, 5 } },
    .{ .nashville = "1-5-6-4", .degrees = &.{ 1, 5, 6, 4 } },
    .{ .nashville = "2-5-1", .degrees = &.{ 2, 5, 1 } },
    .{ .nashville = "1-6-2-5", .degrees = &.{ 1, 6, 2, 5 } },
    .{ .nashville = "1-3-4-5", .degrees = &.{ 1, 3, 4, 5 } },
    .{ .nashville = "1-4-6-5", .degrees = &.{ 1, 4, 6, 5 } },
    .{ .nashville = "1-3-6-4", .degrees = &.{ 1, 3, 6, 4 } },
    .{ .nashville = "1-4-2-5", .degrees = &.{ 1, 4, 2, 5 } },
    .{ .nashville = "6-4-1-5", .degrees = &.{ 6, 4, 1, 5 } },
    .{ .nashville = "1-b7-4", .degrees = &.{ 1, 7, 4 } },
    .{ .nashville = "1-5-6-3-4", .degrees = &.{ 1, 5, 6, 3, 4 } },
    .{ .nashville = "1-5-4-1", .degrees = &.{ 1, 5, 4, 1 } },
    .{ .nashville = "6-1-6-5", .degrees = &.{ 6, 1, 6, 5 } },
    .{ .nashville = "1-6-2-4", .degrees = &.{ 1, 6, 2, 4 } },
    .{ .nashville = "6-2-5-1", .degrees = &.{ 6, 2, 5, 1 } },
    .{ .nashville = "4-6-5-1", .degrees = &.{ 4, 6, 5, 1 } },
    .{ .nashville = "6-2-3-4", .degrees = &.{ 6, 2, 3, 4 } },
    .{ .nashville = "1-4-b7-1", .degrees = &.{ 1, 4, 7, 1 } },
    .{ .nashville = "5-4-1", .degrees = &.{ 5, 4, 1 } },
    .{
        .name = "Canon",
        .nashville = "1-5-6-3-4-1-4-5",
        .degrees = &.{ 1, 5, 6, 3, 4, 1, 4, 5 },
        .original_key = .{ .name = "D major", .ionian_tonic = "D" },
    },
    .{
        .name = "Hotel California",
        .nashville = "6-3-5-2-4-1-2-3",
        .degrees = &.{ 6, 3, 5, 2, 4, 1, 2, 3 },
        .borrowings = &.{
            .{ .step = 1, .quality = .major },
            .{ .step = 3, .quality = .major },
            .{ .step = 7, .quality = .major },
        },
        .original_key = .{ .name = "B minor", .ionian_tonic = "D" },
    },
    .{
        .name = "Let It Be",
        .nashville = "1-5-6-4-1-5-4-1",
        .degrees = &.{ 1, 5, 6, 4, 1, 5, 4, 1 },
        .original_key = .{ .name = "C major", .ionian_tonic = "C" },
    },
    .{
        .name = "12-bar blues",
        .nashville = "1-1-1-1-4-4-1-1-5-4-1-5",
        .degrees = &.{ 1, 1, 1, 1, 4, 4, 1, 1, 5, 4, 1, 5 },
    },
    .{ .name = "Circle of fifths", .nashville = "1-4-7-3-6-2-5-1", .degrees = &.{ 1, 4, 7, 3, 6, 2, 5, 1 } },
    .{
        .name = "Fly Me to the Moon",
        .nashville = "6-2-5-1-4-7-3-6",
        .degrees = &.{ 6, 2, 5, 1, 4, 7, 3, 6 },
        .borrowings = &.{.{ .step = 6, .quality = .major }},
        .original_key = .{ .version = "Sinatra", .name = "C major", .ionian_tonic = "C" },
    },
    .{
        .name = "Andalusian cadence",
        .nashville = "6-5-4-3",
        .degrees = &.{ 6, 5, 4, 3 },
        .borrowings = &.{.{ .step = 3, .quality = .major }},
    },
    .{ .name = "Royal road", .nashville = "4-5-3-6", .degrees = &.{ 4, 5, 3, 6 } },
    .{
        .name = "La Folia",
        .nashville = "6-3-6-5-1-5-6-3",
        .degrees = &.{ 6, 3, 6, 5, 1, 5, 6, 3 },
        .borrowings = &.{ .{ .step = 1, .quality = .major }, .{ .step = 7, .quality = .major } },
        .original_key = .{ .version = "Corelli", .name = "D minor", .ionian_tonic = "F" },
    },
    .{
        .name = "Ragtime",
        .nashville = "3-6-2-5-1",
        .degrees = &.{ 3, 6, 2, 5, 1 },
        .borrowings = &.{
            .{ .step = 0, .quality = .major },
            .{ .step = 1, .quality = .major },
            .{ .step = 2, .quality = .major },
        },
    },
    .{
        .name = "Creep",
        .nashville = "1-3-4-4",
        .degrees = &.{ 1, 3, 4, 4 },
        .borrowings = &.{ .{ .step = 1, .quality = .major }, .{ .step = 3, .quality = .minor } },
        .original_key = .{ .name = "G major", .ionian_tonic = "G" },
    },
    .{
        .name = "Wonderwall",
        .nashville = "6-1-5-2",
        .degrees = &.{ 6, 1, 5, 2 },
        .original_key = .{ .name = "F# minor", .ionian_tonic = "A" },
    },
    .{
        .name = "Smells Like Teen Spirit",
        .nashville = "6-2-1-4",
        .degrees = &.{ 6, 2, 1, 4 },
        // A flat major, as the sharps the tonics offer spell it: G# Ionian, its seventh F##.
        .original_key = .{ .name = "F minor", .ionian_tonic = "G#" },
    },
};

/// How many modes the header's list holds: `Mode`'s values.
pub const mode_count: usize = std.enums.values(Mode).len;

/// A chord's name as its letters show it: its root's spelling in the key, then "m" for a minor triad, a degree sign
/// for the diminished one, nothing for a major one - C, Dm, and B with the degree sign. The two parts are copied one
/// after the other into `buffer`: a spelling is a letter and at most two accidentals, the suffix at most two bytes, so
/// eight bytes always hold the name.
pub fn chordLetterName(
    buffer: *[8]u8,
    scale: *const Scale,
    chord: ScaleChord,
) []const u8 {
    const quality_suffix: []const u8 = switch (chord.quality) {
        .major => "",
        .minor => "m",
        .diminished => "\u{B0}",
        .augmented => "+",
    };
    const root_spelling: []const u8 = scale.noteName(chord.root_degree);
    const name_length: usize = root_spelling.len + quality_suffix.len;
    @memcpy(buffer[0..root_spelling.len], root_spelling);
    @memcpy(buffer[root_spelling.len..name_length], quality_suffix);
    return buffer[0..name_length];
}

/// Writes a song's key into `buffer` for its label, after its name: ` (D major)` where the scale to choose is the
/// key's own tonic in Ionian; ` (B minor, as D Ionian)` where it is not - a minor key, counted from its relative
/// major; the version first where the song has several (` (Sinatra: C major)`).
pub fn writeSongKey(buffer: []u8, original_key: SongKey) []const u8 {
    const is_own_tonic: bool = startsWith(u8, original_key.name, original_key.ionian_tonic) and
        endsWith(u8, original_key.name, " major");
    const version_separator: []const u8 = if (original_key.version.len > 0) ": " else "";
    if (is_own_tonic) {
        return bufPrint(buffer, " ({s}{s}{s})", .{
            original_key.version,
            version_separator,
            original_key.name,
        }) catch "";
    }
    return bufPrint(buffer, " ({s}{s}{s}, as {s} Ionian)", .{
        original_key.version,
        version_separator,
        original_key.name,
        original_key.ionian_tonic,
    }) catch "";
}

// ---- The tonics and modes the options offer ----

/// A tonic the key dropdown lists: its letter, C as 0 to B as 6, and its accidental, 1 for a sharp.
pub const ListedTonic = struct {
    /// The letter, C as 0 to B as 6.
    letter: u8,
    /// The accidental: 0 natural, 1 sharp.
    accidental: i8,
};

/// The tonics the key dropdown lists, the twelve from A, each natural followed by its sharp where it has one: A, A#,
/// B, C, C#, D, D#, E, F, F#, G, G#.
pub const listed_tonics = [12]ListedTonic{
    .{ .letter = 5, .accidental = 0 },
    .{ .letter = 5, .accidental = 1 },
    .{ .letter = 6, .accidental = 0 },
    .{ .letter = 0, .accidental = 0 },
    .{ .letter = 0, .accidental = 1 },
    .{ .letter = 1, .accidental = 0 },
    .{ .letter = 1, .accidental = 1 },
    .{ .letter = 2, .accidental = 0 },
    .{ .letter = 3, .accidental = 0 },
    .{ .letter = 3, .accidental = 1 },
    .{ .letter = 4, .accidental = 0 },
    .{ .letter = 4, .accidental = 1 },
};

/// The names the two dropdowns list: the tonics', A to G#, and the modes', Ionian to Locrian - in the order of
/// `Mode`'s values, so that a mode's index in the list is its value.
pub const listed_tonic_names = [12][]const u8{ "A", "A#", "B", "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#" };

/// The tonic a song's key is played in (`SongKey.ionian_tonic`), where the options offer it: the twelve listed; null
/// for any other spelling.
pub fn songKeyTonic(original_key: SongKey) ?ListedTonic {
    for (listed_tonic_names, listed_tonics) |tonic_name, tonic| {
        if (eql(u8, tonic_name, original_key.ionian_tonic)) {
            return tonic;
        }
    }
    return null;
}
/// The modes' names as the mode dropdown lists them, in the order of `Mode`'s values.
pub const listed_mode_names = [11][]const u8{
    "Ionian",
    "Dorian",
    "Phrygian",
    "Lydian",
    "Mixolydian",
    "Aeolian",
    "Locrian",
    "Harmonic minor",
    "Melodic minor",
    "Harmonic major",
    "Phrygian dominant",
};

/// The notes a mode alters from the major scale, as its label shows them (`writeModeLabels`): each degree a semitone
/// below the major scale's a flat, each a semitone above it a sharp - Lydian #4, Dorian b3 b7, Locrian b2 b3 b5 b6 b7 -
/// and a dash for the major scale itself. Written into `buffer`; at most seven of three bytes, spaces between.
pub fn writeAlterations(buffer: []u8, mode: Mode) []const u8 {
    const mode_semitones: [7]u8 = mode.semitonesAboveTonic();
    var alterations_length: usize = 0;
    for (mode_semitones, natural_semitones, 1..) |mode_semitone, major_semitone, degree| {
        const sign: []const u8 = if (mode_semitone + 1 == major_semitone)
            "b"
        else if (mode_semitone == major_semitone + 1)
            "#"
        else
            continue;
        const separator: []const u8 = if (alterations_length == 0) "" else " ";
        const room: []u8 = buffer[alterations_length..];
        const written: []const u8 = bufPrint(room, "{s}{s}{d}", .{ separator, sign, degree }) catch break;
        alterations_length += written.len;
    }
    if (alterations_length == 0) {
        buffer[0] = '-';
        alterations_length = 1;
    }
    return buffer[0..alterations_length];
}

/// The room one mode's label takes in the mode dropdown's list (`writeModeLabel`): a line of its name and
/// alterations, and a line of seven chord names of at most five bytes each - a letter, two accidentals at most and a
/// degree sign of two.
pub const mode_label_capacity: usize = 96;

/// How many columns the first line of a mode's label spans: its name at the left, its alterations at the right - in
/// a monospaced font the alterations then line up down the list.
pub const mode_label_columns: usize = 28;

/// Writes a mode's label for the mode dropdown's list into `buffer`, in two lines: the mode's name with the notes it
/// alters from the major scale at the right (`writeAlterations`), the line `columns` wide where they fit; then its
/// seven chords on the tonic `tonic_letter` with `tonic_accidental` - C Dorian's are Cm, Dm, Eb, F, Gm, A diminished
/// and Bb. `buffer` holds `mode_label_capacity` bytes or more.
pub fn writeModeLabel(
    buffer: []u8,
    tonic_letter: u8,
    tonic_accidental: i8,
    mode: Mode,
    columns: usize,
) []const u8 {
    const scale: Scale = .ofTonic(tonic_letter, tonic_accidental, mode);
    var alteration_buffer: [32]u8 = undefined;
    const alterations: []const u8 = writeAlterations(&alteration_buffer, mode);
    const name: []const u8 = listed_mode_names[@backingInt(mode)];
    const gap: usize = @max(2, columns -| (name.len + alterations.len));
    var label_length: usize = 0;
    @memcpy(buffer[0..name.len], name);
    label_length += name.len;
    @memset(buffer[label_length..][0..gap], ' ');
    label_length += gap;
    @memcpy(buffer[label_length..][0..alterations.len], alterations);
    label_length += alterations.len;
    buffer[label_length] = '\n';
    label_length += 1;
    for (scale.chords, 0..) |chord, chord_index| {
        var name_buffer: [8]u8 = undefined;
        const chord_name: []const u8 = chordLetterName(&name_buffer, &scale, chord);
        const separator: []const u8 = if (chord_index == 0) "" else " ";
        const room: []u8 = buffer[label_length..];
        const written: []const u8 = bufPrint(room, "{s}{s}", .{ separator, chord_name }) catch break;
        label_length += written.len;
    }
    return buffer[0..label_length];
}

// ---- Naming the chord ----

/// A set of pitch classes - the twelve notes of the octave, C to B, without regard to which octave - as twelve bits:
/// bit 0 for C, bit 1 for C sharp, and on to bit 11 for B. A set of notes sounding, or a chord's notes counted from its
/// root (`ChordPattern`).
pub const PitchClassSet = u12;

/// The set holding the pitch classes `semitones_from_root` above a root at 0.
pub fn pitchClassSetOf(comptime semitones_from_root: []const u4) PitchClassSet {
    var set: PitchClassSet = 0;
    for (semitones_from_root) |semitone| {
        set |= @as(PitchClassSet, 1) << semitone;
    }
    return set;
}

/// `set` as seen from `root`: every pitch class moved down by `root` semitones, round the octave, so that the root is
/// at 0 - the form a chord's pattern is written in. C E G seen from C is 0 4 7; seen from E, 0 3 8.
pub fn pitchClassesFromRoot(set: PitchClassSet, root: u4) PitchClassSet {
    // A rotation of the twelve bits, by `root`: the set written twice in a row, 24 bits, and the twelve from bit
    // `root` on taken - each bit below `root` comes back round at the top.
    const set_twice: u24 = @as(u24, set) | (@as(u24, set) << 12);
    return @truncate(set_twice >> root);
}

/// A kind of chord: the pitch classes it holds counted from its root, the suffix written after the root's name in a
/// chord symbol, and the kind spelled out.
pub const ChordPattern = struct {
    /// The pitch classes it holds, counted from its root: bit 0 the root, bit 4 a major third.
    from_root: PitchClassSet,
    /// What follows the root's name in a chord symbol: "m7" in Am7.
    suffix: []const u8,
    /// The kind spelled out: "minor seventh".
    description: []const u8,
    /// How the kind reads after a Roman numeral, which names the root by its degree (`numeralNameOf`): the numeral
    /// in small letters when the chord's third is minor (`has_minor_third`), in capitals otherwise - so a minor
    /// seventh is `ii7`, not `iim7`; a half-diminished seventh is vii with a slashed o and a 7. A sixth is written
    /// `add6`: in Roman numeral analysis a 6 alone after the numeral means the first inversion.
    numeral_suffix: []const u8,
    /// Whether its third is minor: its numeral is then written in small letters.
    has_minor_third: bool,
};

/// The chords named, in the order a name is preferred when several fit the same notes (`nameOfChord`): the triads
/// first, then the seventh chords built of thirds, then the suspended chords, the sixths and the added notes, then the
/// ninths, and the bare fifth last. A diatonic scale holds all of these; the augmented triad and the diminished seventh
/// it does not, and they are left out.
pub const chord_patterns = [_]ChordPattern{
    .{
        .from_root = pitchClassSetOf(&.{ 0, 4, 7 }),
        .suffix = "",
        .description = "major",
        .numeral_suffix = "",
        .has_minor_third = false,
    },
    .{
        .from_root = pitchClassSetOf(&.{ 0, 3, 7 }),
        .suffix = "m",
        .description = "minor",
        .numeral_suffix = "",
        .has_minor_third = true,
    },
    .{
        .from_root = pitchClassSetOf(&.{ 0, 3, 6 }),
        .suffix = "\u{00b0}",
        .description = "diminished",
        .numeral_suffix = "\u{00b0}",
        .has_minor_third = true,
    },
    .{
        .from_root = pitchClassSetOf(&.{ 0, 4, 7, 11 }),
        .suffix = "maj7",
        .description = "major seventh",
        .numeral_suffix = "maj7",
        .has_minor_third = false,
    },
    .{
        .from_root = pitchClassSetOf(&.{ 0, 4, 7, 10 }),
        .suffix = "7",
        .description = "dominant seventh",
        .numeral_suffix = "7",
        .has_minor_third = false,
    },
    .{
        .from_root = pitchClassSetOf(&.{ 0, 3, 7, 10 }),
        .suffix = "m7",
        .description = "minor seventh",
        .numeral_suffix = "7",
        .has_minor_third = true,
    },
    .{
        .from_root = pitchClassSetOf(&.{ 0, 3, 6, 10 }),
        .suffix = "m7b5",
        .description = "half-diminished",
        .numeral_suffix = "\u{00f8}7",
        .has_minor_third = true,
    },
    .{
        .from_root = pitchClassSetOf(&.{ 0, 2, 7 }),
        .suffix = "sus2",
        .description = "suspended second",
        .numeral_suffix = "sus2",
        .has_minor_third = false,
    },
    .{
        .from_root = pitchClassSetOf(&.{ 0, 5, 7 }),
        .suffix = "sus4",
        .description = "suspended fourth",
        .numeral_suffix = "sus4",
        .has_minor_third = false,
    },
    .{
        .from_root = pitchClassSetOf(&.{ 0, 5, 7, 10 }),
        .suffix = "7sus4",
        .description = "seventh, suspended fourth",
        .numeral_suffix = "7sus4",
        .has_minor_third = false,
    },
    .{
        .from_root = pitchClassSetOf(&.{ 0, 4, 7, 9 }),
        .suffix = "6",
        .description = "major sixth",
        .numeral_suffix = "add6",
        .has_minor_third = false,
    },
    .{
        .from_root = pitchClassSetOf(&.{ 0, 3, 7, 9 }),
        .suffix = "m6",
        .description = "minor sixth",
        .numeral_suffix = "add6",
        .has_minor_third = true,
    },
    .{
        .from_root = pitchClassSetOf(&.{ 0, 2, 4, 7 }),
        .suffix = "add9",
        .description = "added ninth",
        .numeral_suffix = "add9",
        .has_minor_third = false,
    },
    .{
        .from_root = pitchClassSetOf(&.{ 0, 2, 3, 7 }),
        .suffix = "m(add9)",
        .description = "minor, added ninth",
        .numeral_suffix = "add9",
        .has_minor_third = true,
    },
    .{
        .from_root = pitchClassSetOf(&.{ 0, 2, 4, 7, 11 }),
        .suffix = "maj9",
        .description = "major ninth",
        .numeral_suffix = "maj9",
        .has_minor_third = false,
    },
    .{
        .from_root = pitchClassSetOf(&.{ 0, 2, 4, 7, 10 }),
        .suffix = "9",
        .description = "dominant ninth",
        .numeral_suffix = "9",
        .has_minor_third = false,
    },
    .{
        .from_root = pitchClassSetOf(&.{ 0, 2, 3, 7, 10 }),
        .suffix = "m9",
        .description = "minor ninth",
        .numeral_suffix = "9",
        .has_minor_third = true,
    },
    .{
        .from_root = pitchClassSetOf(&.{ 0, 2, 4, 7, 9 }),
        .suffix = "6/9",
        .description = "six-nine",
        .numeral_suffix = "add6/9",
        .has_minor_third = false,
    },
    .{
        .from_root = pitchClassSetOf(&.{ 0, 4, 8 }),
        .suffix = "+",
        .description = "augmented",
        .numeral_suffix = "+",
        .has_minor_third = false,
    },
    .{
        .from_root = pitchClassSetOf(&.{ 0, 7 }),
        .suffix = "5",
        .description = "fifth",
        .numeral_suffix = "5",
        .has_minor_third = false,
    },
};

/// The names of the intervals, by their size in semitones within the octave: what two notes that are no chord of
/// `chord_patterns` are called.
pub const interval_names = [12][]const u8{
    "unison",  "minor second", "major second", "minor third", "major third",   "fourth",
    "tritone", "fifth",        "minor sixth",  "major sixth", "minor seventh", "major seventh",
};

/// What the notes sounding are called, as the centre of the chromatic circle shows it: a symbol - `Am7`, `G`, `Bdim` -
/// and the kind spelled out beneath it, or the notes themselves when no name fits. `root` is the chord's root, by its
/// pitch class, when there is one: the polygon is drawn in its color.
pub const ChordName = struct {
    /// The symbol's letters.
    symbol_buffer: [24]u8,
    /// How many of them are the symbol.
    symbol_length: usize,
    /// The kind spelled out, or the notes named when no kind fits.
    description: []const u8,
    /// The chord's root's pitch class, if it has one.
    root: ?u4,

    /// The symbol: `Am7`.
    pub fn symbol(name: *const ChordName) []const u8 {
        return name.symbol_buffer[0..name.symbol_length];
    }
};

/// A chord's name from its root and its pattern: the root's name and the pattern's suffix - `A` and `m7`, `Am7`.
pub fn nameFromPattern(scale: *const Scale, root: u4, pattern: ChordPattern) ChordName {
    var name: ChordName = .{
        .symbol_buffer = undefined,
        .symbol_length = 0,
        .description = pattern.description,
        .root = root,
    };
    // The root is a note of the scale - nothing else sounds - so it is named as the scale spells it.
    const root_degree: u8 = scale.degreeOfPitchClass(root) orelse 1;
    const root_name: []const u8 = scale.noteName(root_degree);
    const symbol: []const u8 = bufPrint(&name.symbol_buffer, "{s}{s}", .{ root_name, pattern.suffix }) catch "";
    name.symbol_length = symbol.len;
    return name;
}

/// A chord found in the notes sounding: its root, and the pattern its notes make from it.
pub const ChordMatch = struct {
    /// The chord's root's pitch class.
    root: u4,
    /// The kind of chord it is.
    pattern: ChordPattern,
};

/// The chord `sounding` makes, if one of `chord_patterns` fits it: from `preferred_root` - the chosen chord's - if that
/// root fits, else the first pattern that fits from any root, and for that pattern the lowest root from C.
pub fn matchedChord(sounding: PitchClassSet, preferred_root: u4) ?ChordMatch {
    const preferred_root_bit: PitchClassSet = @as(PitchClassSet, 1) << preferred_root;
    if (sounding & preferred_root_bit != 0) {
        for (chord_patterns) |pattern| {
            if (pitchClassesFromRoot(sounding, preferred_root) == pattern.from_root) {
                return .{ .root = preferred_root, .pattern = pattern };
            }
        }
    }
    for (chord_patterns) |pattern| {
        for (0..12) |root_index| {
            const root: u4 = @intCast(root_index);
            const root_bit: PitchClassSet = @as(PitchClassSet, 1) << root;
            if (sounding & root_bit != 0 and pitchClassesFromRoot(sounding, root) == pattern.from_root) {
                return .{ .root = root, .pattern = pattern };
            }
        }
    }
    return null;
}

/// The chord `sounding` makes, named by letters (`matchedChord`, `nameFromPattern`).
pub fn namedChord(
    scale: *const Scale,
    sounding: PitchClassSet,
    preferred_root: u4,
) ?ChordName {
    const match: ChordMatch = matchedChord(sounding, preferred_root) orelse return null;
    return nameFromPattern(scale, match.root, match.pattern);
}

/// A chord named as Roman numeral analysis names the chords of a key: the root by its degree - I to VII, in small
/// letters when the chord's third is minor - and the kind after it (`ChordPattern.numeral_suffix`): `V7`, `ii7`,
/// `Imaj7`, `Vsus4`, `Iadd6`, and vii with the degree sign. No note is named: the numeral is the degree, in any key.
pub fn numeralNameOf(buffer: []u8, scale: *const Scale, match: ChordMatch) []const u8 {
    const root_degree: u8 = scale.degreeOfPitchClass(match.root) orelse 1;
    const numerals: *const [7][]const u8 = if (match.pattern.has_minor_third) &minor_numerals else &major_numerals;
    const numeral: []const u8 = numerals[root_degree - 1];
    return bufPrint(buffer, "{s}{s}", .{ numeral, match.pattern.numeral_suffix }) catch "";
}

comptime {
    // The names, checked when compiling: each chord of the scale, some sevenths, and the notes two chords share,
    // named from the chosen chord's root when it fits. C is 0, D 2, E 4, F 5, G 7, A 9, B 11.
    const checks = [_]struct { notes: []const u4, preferred_root: u4, symbol: []const u8 }{
        .{ .notes = &.{ 0, 4, 7 }, .preferred_root = 0, .symbol = "C" },
        .{ .notes = &.{ 2, 5, 9 }, .preferred_root = 0, .symbol = "Dm" },
        .{ .notes = &.{ 4, 7, 11 }, .preferred_root = 0, .symbol = "Em" },
        .{ .notes = &.{ 5, 9, 0 }, .preferred_root = 0, .symbol = "F" },
        .{ .notes = &.{ 7, 11, 2 }, .preferred_root = 0, .symbol = "G" },
        .{ .notes = &.{ 9, 0, 4 }, .preferred_root = 0, .symbol = "Am" },
        .{ .notes = &.{ 11, 2, 5 }, .preferred_root = 0, .symbol = "B\u{00b0}" },
        .{ .notes = &.{ 7, 11, 2, 5 }, .preferred_root = 0, .symbol = "G7" },
        .{ .notes = &.{ 0, 4, 7, 11 }, .preferred_root = 0, .symbol = "Cmaj7" },
        .{ .notes = &.{ 2, 5, 9, 0 }, .preferred_root = 2, .symbol = "Dm7" },
        .{ .notes = &.{ 11, 2, 5, 9 }, .preferred_root = 11, .symbol = "Bm7b5" },
        .{ .notes = &.{ 0, 4, 7, 9 }, .preferred_root = 0, .symbol = "C6" },
        .{ .notes = &.{ 0, 4, 7, 9 }, .preferred_root = 9, .symbol = "Am7" },
        .{ .notes = &.{ 0, 4, 7, 9 }, .preferred_root = 7, .symbol = "Am7" },
        .{ .notes = &.{ 0, 2, 7 }, .preferred_root = 0, .symbol = "Csus2" },
        .{ .notes = &.{ 0, 2, 7 }, .preferred_root = 7, .symbol = "Gsus4" },
        .{ .notes = &.{ 0, 7 }, .preferred_root = 0, .symbol = "C5" },
    };
    @setEvalBranchQuota(100_000);
    for (checks) |check| {
        var sounding: PitchClassSet = 0;
        for (check.notes) |pitch_class| {
            sounding |= @as(PitchClassSet, 1) << pitch_class;
        }
        const chord_name: ChordName = namedChord(&c_major, sounding, check.preferred_root) orelse
            @compileError("no name for the chord " ++ check.symbol);
        if (!eql(u8, chord_name.symbol(), check.symbol)) {
            @compileError("the chord " ++ check.symbol ++ " is named " ++ chord_name.symbol());
        }
    }
}

comptime {
    // The numeral names, checked when compiling, in C major: C is 0, D 2, E 4, F 5, G 7, A 9, B 11.
    const checks = [_]struct { notes: []const u4, preferred_root: u4, numeral_name: []const u8 }{
        .{ .notes = &.{ 0, 4, 7 }, .preferred_root = 0, .numeral_name = "I" },
        .{ .notes = &.{ 2, 5, 9 }, .preferred_root = 0, .numeral_name = "ii" },
        .{ .notes = &.{ 11, 2, 5 }, .preferred_root = 0, .numeral_name = "vii\u{00b0}" },
        .{ .notes = &.{ 7, 11, 2, 5 }, .preferred_root = 0, .numeral_name = "V7" },
        .{ .notes = &.{ 0, 4, 7, 11 }, .preferred_root = 0, .numeral_name = "Imaj7" },
        .{ .notes = &.{ 2, 5, 9, 0 }, .preferred_root = 2, .numeral_name = "ii7" },
        .{ .notes = &.{ 11, 2, 5, 9 }, .preferred_root = 11, .numeral_name = "vii\u{00f8}7" },
        .{ .notes = &.{ 0, 2, 7 }, .preferred_root = 0, .numeral_name = "Isus2" },
        .{ .notes = &.{ 0, 2, 7 }, .preferred_root = 7, .numeral_name = "Vsus4" },
        .{ .notes = &.{ 0, 4, 7, 9 }, .preferred_root = 0, .numeral_name = "Iadd6" },
        .{ .notes = &.{ 0, 4, 7, 9 }, .preferred_root = 9, .numeral_name = "vi7" },
        .{ .notes = &.{ 0, 2, 4, 7 }, .preferred_root = 0, .numeral_name = "Iadd9" },
    };
    @setEvalBranchQuota(100_000);
    for (checks) |check| {
        var sounding: PitchClassSet = 0;
        for (check.notes) |pitch_class| {
            sounding |= @as(PitchClassSet, 1) << pitch_class;
        }
        const match: ChordMatch = matchedChord(sounding, check.preferred_root) orelse
            @compileError("no chord in " ++ check.numeral_name);
        var name_buffer: [24]u8 = undefined;
        const numeral_name: []const u8 = numeralNameOf(&name_buffer, &c_major, match);
        if (!eql(u8, numeral_name, check.numeral_name)) {
            @compileError("the chord " ++ check.numeral_name ++ " is named " ++ numeral_name);
        }
    }
}

// ---- The degrees' functions ----

/// The names of the degrees' functions in a key, the tonic's first: what a chord on the degree, or the note alone, is
/// called - the seventh's by its distance from the tonic (`functionNameOfDegree`).
pub const degree_function_names = [6][]const u8{
    "Tonic",
    "Supertonic",
    "Mediant",
    "Subdominant",
    "Dominant",
    "Submediant",
};

/// The name of `degree`'s function in `scale`: its name from the list, but the seventh's by how far below the tonic
/// it lies - a half step, the leading tone, which leads up into the tonic, as in major and harmonic minor; a whole
/// step, the subtonic, which does not, as in natural minor.
pub fn functionNameOfDegree(scale: *const Scale, degree: u8) []const u8 {
    if (degree == 7) {
        const is_half_step_below_tonic: bool = scale.semitones[6] == 11;
        return if (is_half_step_below_tonic) "Leading tone" else "Subtonic";
    }
    return degree_function_names[degree - 1];
}

// ---- Tests ----
//
// Each expectation is written out by hand, from the notes as a musician names them, not from what the code computes.

test "music_theory: D major spells D E F# G A B C#; F# major's seventh is E#, G# major's F##" {
    const d_major: Scale = .of(1, .ionian);
    const d_major_names: [7][]const u8 = .{ "D", "E", "F#", "G", "A", "B", "C#" };
    for (all_degrees, d_major_names) |degree, expected_name| {
        try expectEqualStrings(expected_name, d_major.noteName(degree));
    }
    const f_sharp_major: Scale = .ofTonic(3, 1, .ionian);
    try expectEqualStrings("E#", f_sharp_major.noteName(7));
    const g_sharp_major: Scale = .ofTonic(4, 1, .ionian);
    try expectEqualStrings("F##", g_sharp_major.noteName(7));
}

test "music_theory: no scale offered needs more than two sharps or flats on a note" {
    for (listed_tonics) |tonic| {
        for (std.enums.values(Mode)) |mode| {
            const scale: Scale = .ofTonic(tonic.letter, tonic.accidental, mode);
            for (all_degrees) |degree| {
                // 0 a double flat to 4 a double sharp: the five names `spelled_note_names` holds for each letter.
                try expect(scale.spellingOf(degree).accidental <= 4);
            }
        }
    }
}

test "music_theory: the modes' semitones above the tonic" {
    const dorian: [7]u8 = .{ 0, 2, 3, 5, 7, 9, 10 };
    const lydian: [7]u8 = .{ 0, 2, 4, 6, 7, 9, 11 };
    const harmonic_minor: [7]u8 = .{ 0, 2, 3, 5, 7, 8, 11 };
    const phrygian_dominant: [7]u8 = .{ 0, 1, 4, 5, 7, 8, 10 };
    try expectEqualSlices(u8, &dorian, &Mode.dorian.semitonesAboveTonic());
    try expectEqualSlices(u8, &lydian, &Mode.lydian.semitonesAboveTonic());
    try expectEqualSlices(u8, &harmonic_minor, &Mode.harmonic_minor.semitonesAboveTonic());
    try expectEqualSlices(u8, &phrygian_dominant, &Mode.phrygian_dominant.semitonesAboveTonic());
}

test "music_theory: C Dorian's chords are Cm Dm Eb F Gm, A diminished and Bb" {
    const c_dorian: Scale = .of(0, .dorian);
    const expected_names: [7][]const u8 = .{ "Cm", "Dm", "Eb", "F", "Gm", "A\u{B0}", "Bb" };
    for (c_dorian.chords, expected_names) |chord, expected_name| {
        var name_buffer: [8]u8 = undefined;
        try expectEqualStrings(expected_name, chordLetterName(&name_buffer, &c_dorian, chord));
    }
}

test "music_theory: Hotel California in D Ionian is Bm F# A E G D Em F#" {
    const hotel_california: Progression = for (progressions) |progression| {
        if (eql(u8, progression.name, "Hotel California")) {
            break progression;
        }
    } else return error.TestUnexpectedResult;
    const d_major: Scale = .of(1, .ionian);
    const expected_names: [8][]const u8 = .{ "Bm", "F#", "A", "E", "G", "D", "Em", "F#" };
    for (expected_names, 0..) |expected_name, step| {
        var name_buffer: [8]u8 = undefined;
        const chord: ScaleChord = progressionChord(&d_major, hotel_california, step);
        try expectEqualStrings(expected_name, chordLetterName(&name_buffer, &d_major, chord));
    }
}

test "music_theory: a borrowed chord raises or lowers the one note it changes" {
    // In C major: E major (III) raises G, the 5th degree; D major (II) raises F, the 4th; F minor (iv) lowers A,
    // the 6th.
    const e_major: ScaleChord = .{ .root_degree = 3, .quality = .major };
    const d_major: ScaleChord = .{ .root_degree = 2, .quality = .major };
    const f_minor: ScaleChord = .{ .root_degree = 4, .quality = .minor };
    const raises_fifth_degree: [7]i8 = .{ 0, 0, 0, 0, 1, 0, 0 };
    const raises_fourth_degree: [7]i8 = .{ 0, 0, 0, 1, 0, 0, 0 };
    const lowers_sixth_degree: [7]i8 = .{ 0, 0, 0, 0, 0, -1, 0 };
    try expectEqualSlices(i8, &raises_fifth_degree, &c_major.alterationsForChord(e_major));
    try expectEqualSlices(i8, &raises_fourth_degree, &c_major.alterationsForChord(d_major));
    try expectEqualSlices(i8, &lowers_sixth_degree, &c_major.alterationsForChord(f_minor));
}

test "music_theory: a song's key and a mode's alterations, as the options write them" {
    var buffer: [48]u8 = undefined;
    const hotel_california_key: SongKey = .{ .name = "B minor", .ionian_tonic = "D" };
    const canon_key: SongKey = .{ .name = "D major", .ionian_tonic = "D" };
    const fly_me_key: SongKey = .{ .version = "Sinatra", .name = "C major", .ionian_tonic = "C" };
    try expectEqualStrings(" (B minor, as D Ionian)", writeSongKey(&buffer, hotel_california_key));
    try expectEqualStrings(" (D major)", writeSongKey(&buffer, canon_key));
    try expectEqualStrings(" (Sinatra: C major)", writeSongKey(&buffer, fly_me_key));
    try expectEqualStrings("-", writeAlterations(&buffer, .ionian));
    try expectEqualStrings("#4", writeAlterations(&buffer, .lydian));
    try expectEqualStrings("b3 b7", writeAlterations(&buffer, .dorian));
    try expectEqualStrings("b2 b3 b5 b6 b7", writeAlterations(&buffer, .locrian));
    try expectEqualStrings("b3 b6", writeAlterations(&buffer, .harmonic_minor));
}

test "music_theory: a mode's label is its name and alterations across 28 columns, then its chords on the tonic" {
    var buffer: [mode_label_capacity]u8 = undefined;
    // "Dorian" is 6 columns and "b3 b7" 5: 17 spaces between them fill the 28.
    const c_dorian_label: []const u8 = "Dorian                 b3 b7\nCm Dm Eb F Gm A\u{B0} Bb";
    try expectEqualStrings(c_dorian_label, writeModeLabel(&buffer, 0, 0, .dorian, mode_label_columns));
    // The major scale alters nothing - a dash: "Ionian", 21 spaces, the dash.
    const g_ionian_label: []const u8 = "Ionian                     -\nG Am Bm C D Em F#\u{B0}";
    try expectEqualStrings(g_ionian_label, writeModeLabel(&buffer, 4, 0, .ionian, mode_label_columns));
}

test "music_theory: a song's tonic among the twelve offered" {
    const teen_spirit_key: SongKey = .{ .name = "F minor", .ionian_tonic = "G#" };
    const flat_spelled_key: SongKey = .{ .name = "F minor", .ionian_tonic = "Ab" };
    const g_sharp: ListedTonic = songKeyTonic(teen_spirit_key) orelse return error.TestUnexpectedResult;
    try expectEqual(@as(u8, 4), g_sharp.letter);
    try expectEqual(@as(i8, 1), g_sharp.accidental);
    try expect(songKeyTonic(flat_spelled_key) == null);
}

test "music_theory: the seventh degree is the leading tone a half step below the tonic, else the subtonic" {
    const a_aeolian: Scale = .of(5, .aeolian);
    const a_harmonic_minor: Scale = .of(5, .harmonic_minor);
    try expectEqualStrings("Dominant", functionNameOfDegree(&c_major, 5));
    try expectEqualStrings("Leading tone", functionNameOfDegree(&c_major, 7));
    try expectEqualStrings("Subtonic", functionNameOfDegree(&a_aeolian, 7));
    try expectEqualStrings("Leading tone", functionNameOfDegree(&a_harmonic_minor, 7));
}
