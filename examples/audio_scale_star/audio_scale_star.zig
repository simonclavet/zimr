//! examples/audio_scale_star - the notes and the chords of the major scale, drawn around a circle in thirds.
//!
//! The seven notes of C major sit on a circle, clockwise from the top, in the order 1 3 5 7 2 4 6: each note a third
//! above the one before it. A third is two steps of the scale, and a chord of the scale - a triad - is a note with
//! the third and the fifth above it, so on this circle every chord is three neighbours: its root, its third and its
//! fifth. C major (I) is 1 3 5; D minor (ii) is 2 4 6; and so on round the circle.
//!
//!                  1 C            each chord is drawn beside the middle of its three notes, its third:
//!          6 A           3 E      the major chords (I, IV, V) outside the circle, the minor ones (ii, iii, vi)
//!                                 and the diminished one (vii) inside
//!       4 F                 5 G
//!                                 lines lead from a chord to its notes, one style for each role:
//!           2 D       7 B           root    a solid line ending in an arrowhead
//!                                   third   a zigzag
//!                                   fifth   a dashed line
//!
//! A major chord - I, IV, V - is a square, and so is each note whose own chord is major - 1, 4, 5; the minor chords
//! - ii, iii, vi - and the diminished vii are circles, as are the notes 2, 3, 6 and 7: the major side and the minor
//! side of the scale can be told apart at a glance. Each chord but vii fills the triangles between it, its root and its
//! third, and between it, its third and its fifth, faintly with its color - the first less faintly than the second.
//! Everything is placed from the window's size, so the drawing fills a phone held either way.
//!
//! It plays. The digits 1 to 7 - on the top row or the keypad - and a press on a note play that note while held; a
//! press on a chord plays its three notes while held, and sliding to another note or chord while pressed plays that
//! one instead. What sounds is lit: a note while it sounds, and a chord while all three of its notes do - so that 1, 3
//! and 5 held on the keyboard light the chord I as a press on I does. The notes are Shepard tones
//! (`z.mixer.shepard_instrument`): each note sounds in every octave at once under one fixed bell, so the notes differ
//! in pitch class and not in height, and a scale played round the circle neither rises nor falls.
const std = @import("std");
const Allocator = std.mem.Allocator;
const bufPrint = std.fmt.bufPrint;
const indexOfScalar = std.mem.indexOfScalar;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const Vec2 = zm.Vec2;
const float = zm.float;
const sinTurns = zm.sinTurns;
const cosTurns = zm.cosTurns;
const length = zm.length;
const assert = zm.assert;
const inf = zm.inf;
const splat2 = zm.splat2;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const background: Color = .{ .r = 16, .g = 17, .b = 22, .a = 255 };
const text_color: Color = .{ .r = 235, .g = 235, .b = 240, .a = 255 };
const dim_text_color: Color = .{ .r = 150, .g = 156, .b = 170, .a = 255 };
const circle_path_color: Color = .{ .r = 70, .g = 74, .b = 90, .a = 255 };
const outline_color: Color = .{ .r = 225, .g = 228, .b = 236, .a = 255 };
/// Text on a lit note or chord, which is filled with its full color: dark, since some of the colors are light.
const lit_text_color: Color = .{ .r = 16, .g = 17, .b = 22, .a = 255 };

/// Each degree's color, as a rainbow keyboard colors its white keys from C: red, orange, yellow, green, cyan, blue,
/// violet. A note is filled with its color, dimmed until it sounds; a chord takes its root's color.
const degree_colors = [7]Color{
    .rgbHex(0xF52A2A),
    .rgbHex(0xFFA514),
    .rgbHex(0xFFF200),
    .rgbHex(0x18E018),
    .rgbHex(0x18E6F0),
    .rgbHex(0x1464FF),
    .rgbHex(0xA83CF0),
};

/// How far toward the background a color is drawn while its note or chord is silent: lit, it is drawn whole.
const resting_dimming: f32 = 0.45;

/// How far toward the background a chord's triangles are drawn (`drawChordTriangles`): faint while the chord is
/// silent, a little less faint while it sounds.
const TriangleDimming = struct {
    resting: f32,
    lit: f32,
};
/// The triangle between the root and the third is the more opaque of a chord's two: the third is what makes a chord
/// major or minor. The one between the third and the fifth is fainter.
const root_third_dimming: TriangleDimming = .{ .resting = 0.8, .lit = 0.6 };
const third_fifth_dimming: TriangleDimming = .{ .resting = 0.9, .lit = 0.76 };

/// A degree's color, whole while it sounds and dimmed while it does not.
fn colorOfDegree(degree: u8, is_lit: bool) Color {
    const whole_color: Color = degree_colors[degree - 1];
    return if (is_lit) whole_color else whole_color.lerp(background, resting_dimming);
}

// ---- The scale ----

/// A note of the major scale: its degree, from 1 (the tonic) to 7, and its names - the letter of C major and the
/// solfege syllable.
const ScaleNote = struct {
    degree: u8,
    letter: []const u8,
    solfege: []const u8,
};

/// The seven notes of C major, by degree.
const scale_notes = [7]ScaleNote{
    .{ .degree = 1, .letter = "C", .solfege = "do" },
    .{ .degree = 2, .letter = "D", .solfege = "re" },
    .{ .degree = 3, .letter = "E", .solfege = "mi" },
    .{ .degree = 4, .letter = "F", .solfege = "fa" },
    .{ .degree = 5, .letter = "G", .solfege = "sol" },
    .{ .degree = 6, .letter = "A", .solfege = "la" },
    .{ .degree = 7, .letter = "B", .solfege = "si" },
};

/// The degree `steps` scale steps above `degree`, within one octave: 6 and 2 steps up is 1.
fn degreeAbove(degree: u8, steps: u8) u8 {
    return (degree - 1 + steps) % 7 + 1;
}

/// What a triad of the major scale is: major (a major third, then a minor third above it), minor (a minor third, then
/// a major third) or diminished (two minor thirds, its fifth a semitone short of a perfect fifth). In a major scale the
/// triads on degrees 1, 4 and 5 are major, on 2, 3 and 6 minor, and on 7 diminished.
const ChordQuality = enum { major, minor, diminished };

/// A chord of the scale: the degree of its root, its quality, and its name - a Roman numeral, upper case for a major
/// triad and lower case for a minor one; the diminished triad's numeral carries a degree sign.
const ScaleChord = struct {
    root_degree: u8,
    quality: ChordQuality,
    name: []const u8,

    /// The chord's three notes, as degrees: its root, the third above it, the fifth above it - each two scale steps
    /// above the one before, wrapping past 7 back to 1.
    fn degrees(chord: ScaleChord) [3]u8 {
        const root: u8 = chord.root_degree;
        return .{ root, degreeAbove(root, 2), degreeAbove(root, 4) };
    }

    /// Whether the chord is drawn on the minor side: inside the circle, as a circle.
    fn isMinorSide(chord: ScaleChord) bool {
        return chord.quality != .major;
    }
};

/// The seven chords of C major, by the degree of their root.
const scale_chords = [7]ScaleChord{
    .{ .root_degree = 1, .quality = .major, .name = "I" },
    .{ .root_degree = 2, .quality = .minor, .name = "ii" },
    .{ .root_degree = 3, .quality = .minor, .name = "iii" },
    .{ .root_degree = 4, .quality = .major, .name = "IV" },
    .{ .root_degree = 5, .quality = .major, .name = "V" },
    .{ .root_degree = 6, .quality = .minor, .name = "vi" },
    .{ .root_degree = 7, .quality = .diminished, .name = "vii\u{00b0}" },
};

/// The semitones from C up to each degree of C major: whole, whole, half, whole, whole, whole steps - the major scale's
/// pattern, whose last half step returns to C an octave up.
const semitones_above_tonic = [7]u8{ 0, 2, 4, 5, 7, 9, 11 };

/// The MIDI key the scale's tonic plays at: 60, middle C. A Shepard note ignores the octave - only the key's pitch
/// class chooses its partials - but the keys stay those of one real octave, so that another instrument plays them as
/// they are.
const tonic_key: u8 = 60;

/// The MIDI key of a degree.
fn keyOfDegree(degree: u8) u8 {
    return tonic_key + semitones_above_tonic[degree - 1];
}

/// How hard every note is struck: half the instrument's full level, so that a chord of three stays clear of clipping.
const note_velocity: f32 = 0.5;

/// The keys that play each degree while held: the top row's digits and the keypad's.
const digit_keys = [7]z.KeyboardKey{ .one, .two, .three, .four, .five, .six, .seven };
const keypad_keys = [7]z.KeyboardKey{ .kp_1, .kp_2, .kp_3, .kp_4, .kp_5, .kp_6, .kp_7 };

/// Where a degree sits on the circle of thirds, counted clockwise from the top: 0 for 1, then 1 for 3, 2 for 5, 3 for
/// 7, 4 for 2, 5 for 4, 6 for 6. Walking the circle adds two degrees a place, so the place of a degree undoes that
/// walk: multiplying by 4 undoes multiplying by 2, since 2 x 4 = 8, which is 1 more than a whole circle of 7.
fn circlePlaceOfDegree(degree: u8) u8 {
    return (4 * (degree - 1)) % 7;
}

comptime {
    // The circle of thirds as the drawing needs it, checked when compiling: every degree has a place of its own, and
    // every chord is three neighbours - its third one place clockwise of its root, its fifth two places.
    var is_place_taken: [7]bool = @splat(false);
    for (scale_notes) |note| {
        const place: u8 = circlePlaceOfDegree(note.degree);
        if (is_place_taken[place]) {
            @compileError("two degrees share a place on the circle of thirds");
        }
        is_place_taken[place] = true;
    }
    for (scale_chords) |chord| {
        const chord_degrees: [3]u8 = chord.degrees();
        const root_place: u8 = circlePlaceOfDegree(chord_degrees[0]);
        const is_third_next: bool = circlePlaceOfDegree(chord_degrees[1]) == (root_place + 1) % 7;
        const is_fifth_after: bool = circlePlaceOfDegree(chord_degrees[2]) == (root_place + 2) % 7;
        if (!is_third_next or !is_fifth_after) {
            @compileError("a chord's notes are not three neighbours on the circle of thirds");
        }
    }
}

// ---- The layout ----

/// The shape a note or a chord is drawn as: a square on the major side of the scale - the chords I, IV and V, and the
/// notes 1, 4 and 5, whose own chords they are - and a circle on the minor side: ii, iii, vi and vii, and the notes 2,
/// 3, 6 and 7.
const Shape = enum { square, circle };

fn shapeOfChord(chord: ScaleChord) Shape {
    return if (chord.isMinorSide()) .circle else .square;
}

fn shapeOfDegree(degree: u8) Shape {
    return shapeOfChord(scale_chords[degree - 1]);
}

/// A shape and its size, in size units: the half-side of a square or the radius of a circle. A note is one unit; a
/// chord, two - twice a note's size, as the larger target, since it plays three notes - except the diminished chord,
/// vii, the scale's least used, at one and a half.
const ShapedSize = struct {
    shape: Shape,
    size_in_units: f32,
};
const note_size_in_units: f32 = 1;
const chord_size_in_units: f32 = 2;
const diminished_chord_size_in_units: f32 = 1.5;

fn chordSizeInUnits(chord: ScaleChord) f32 {
    return if (chord.quality == .diminished) diminished_chord_size_in_units else chord_size_in_units;
}

fn shapedSizeOfChord(chord: ScaleChord) ShapedSize {
    return .{ .shape = shapeOfChord(chord), .size_in_units = chordSizeInUnits(chord) };
}

/// How far `point` is from a shape centred at `centre`, of half-size `half_size`: 0 inside it, else the distance to
/// its nearest edge, or corner.
fn distanceToShape(point: Vec2, centre: Vec2, shape: Shape, half_size: f32) f32 {
    const offset: Vec2 = point - centre;
    switch (shape) {
        .circle => return @max(length(offset) - half_size, 0),
        .square => {
            const outside: Vec2 = @max(@abs(offset) - splat2(half_size), splat2(0));
            return length(outside);
        },
    }
}

/// The point where a ray from a shape's centre toward `target` leaves the shape: at its radius for a circle; for a
/// square, where the ray meets the nearer of its vertical and horizontal edges - at the fraction of the way to the
/// target that reaches the first of them.
fn shapeEdgeToward(centre: Vec2, shape: Shape, half_size: f32, target: Vec2) Vec2 {
    const offset: Vec2 = target - centre;
    const offset_length: f32 = length(offset);
    if (offset_length == 0) {
        return centre;
    }
    switch (shape) {
        .circle => return centre + offset * splat2(half_size / offset_length),
        .square => {
            const fraction_to_side: f32 = if (offset[0] == 0) 1 else half_size / @abs(offset[0]);
            const fraction_to_top: f32 = if (offset[1] == 0) 1 else half_size / @abs(offset[1]);
            const fraction: f32 = @min(fraction_to_side, fraction_to_top, 1);
            return centre + offset * splat2(fraction);
        },
    }
}

/// The largest size unit `u` at which two shapes, their centres `offset` apart, are at least `clearance` units apart:
///
///     two circles     u <= distance / (a + b + c)               a, b their sizes in units, c the clearance
///     two squares     u <= max(|dx|, |dy|) / (a + b + c)        apart in x or in y is enough
///     a circle and    the square's nearest point at least (a + c) u from the circle's centre
///       a square
///
/// For the last, as `u` grows the square grows toward the circle while the distance needed grows too, so there is a
/// single largest `u`, found by halving an interval that holds it - from 0 to the distance between the centres - 24
/// times, to within a 16-millionth of that distance.
fn largestUnitApart(
    offset: Vec2,
    first: ShapedSize,
    second: ShapedSize,
    clearance: f32,
) f32 {
    const apart: Vec2 = @abs(offset);
    const sizes_and_clearance: f32 = first.size_in_units + second.size_in_units + clearance;
    if (first.shape == .circle and second.shape == .circle) {
        return length(apart) / sizes_and_clearance;
    }
    if (first.shape == .square and second.shape == .square) {
        return @max(apart[0], apart[1]) / sizes_and_clearance;
    }
    const circle: ShapedSize = if (first.shape == .circle) first else second;
    const square: ShapedSize = if (first.shape == .square) first else second;
    var clear_unit: f32 = 0;
    var touching_unit: f32 = length(apart);
    for (0..24) |_| {
        const trial_unit: f32 = (clear_unit + touching_unit) / 2;
        const half_square: Vec2 = @splat(square.size_in_units * trial_unit);
        const outside_square: Vec2 = @max(apart - half_square, splat2(0));
        const is_clear: bool = length(outside_square) >= (circle.size_in_units + clearance) * trial_unit;
        if (is_clear) {
            clear_unit = trial_unit;
        } else {
            touching_unit = trial_unit;
        }
    }
    return clear_unit;
}

/// Where everything is drawn, worked out from the window's size each frame so that the drawing fills the window,
/// whatever its shape.
///
/// The notes sit on an ellipse rather than a circle - as wide as the window allows and as tall - so that on a phone
/// held upright the notes spread down the whole screen, and on one held sideways across it. The chords sit on two more
/// ellipses of the same shape, one outside for the major chords and one inside for the others, each chord at the
/// angle of its third.
///
/// The sizes follow from those places. A note is `u` in size and a chord `2 u` (`ShapedSize`), and `u` is the
/// largest size at which no two of the fourteen come too near each other (`largestSizeUnit`). Since the figure must
/// also fit the window, and its size is what is being found, the two are settled together: the figure is stretched
/// to the window at the sizes found (`fitToRoom`), `u` is found again for the new places, and so on - a few rounds,
/// each changing less than the one before.
///
/// The figure adapts to the screen's shape in four ways, and the layout is worked out for every combination, the one
/// with the largest notes drawn (`ofWindow`):
///
///     the figure's turn      1 at the top, or a quarter turn round with 1 at the right: with 1 at the top the chords
///                            ii and iii sit side by side, which a narrow screen squeezes
///     the button's corner    a page's fullscreen button covers the window's bottom right corner, which the figure
///                            leaves free: as a strip along the right edge, or one along the bottom
///     the inner chords       their ellipse's size, as a fraction of the notes': nearer the centre leaves more room
///                            between them and their notes, nearer the notes more room among themselves
///     the outer chords       their ellipse's size: further out leaves more room between them and their notes, and
///                            less for the figure
///
/// Since it tries dozens of layouts, the app keeps the one chosen until the window's size changes (`layoutOf`).
const Layout = struct {
    centre: Vec2,
    /// The half-width and the half-height of the ellipse the notes sit on.
    note_ellipse_radii: Vec2,
    /// Where place 0 - the degree 1 - sits, in turns clockwise from the top: 0, or a quarter turn.
    rotation_turns: f32,
    /// The chords' ellipses, as multiples of the notes': the major chords' outside, the others' inside.
    outer_chord_scale: f32,
    inner_chord_scale: f32,
    /// A note's half-size: the half-side of its square, or its circle's radius. A chord's is twice it.
    size_unit: f32,

    /// The sizes of the chords' ellipses `ofWindow` tries, as multiples of the notes'.
    const outer_chord_scales = [_]f32{ 1.5, 1.62, 1.75 };
    const inner_chord_scales = [_]f32{ 0.4, 0.5, 0.6, 0.7 };
    /// The height of the line of text at the top, and the gap kept along the window's edges.
    const header_height: f32 = 26;
    const margin: f32 = 6;
    /// The corner a page's fullscreen button covers: the button's 52 pixels and its 10 from the window's edges.
    const fullscreen_button_reach: f32 = 62;
    /// The rounds `settled` takes to settle the places and the sizes together.
    const settling_rounds: usize = 5;

    fn ofWindow(f: *z.Frame) Layout {
        const width: f32 = f.window.widthf();
        const height: f32 = f.window.heightf();
        const whole_room: z.Rectangle = .{
            .x = margin,
            .y = header_height + margin,
            .width = width - 2 * margin,
            .height = height - header_height - 2 * margin,
        };
        // The fullscreen button's corner left free along the right edge, or along the bottom.
        var room_beside_button: z.Rectangle = whole_room;
        room_beside_button.width -= fullscreen_button_reach - margin;
        var room_above_button: z.Rectangle = whole_room;
        room_above_button.height -= fullscreen_button_reach - margin;
        const rooms = [2]z.Rectangle{ room_beside_button, room_above_button };
        const rotations = [2]f32{ 0, 0.25 };
        var best: ?Layout = null;
        for (rooms) |room| {
            for (rotations) |rotation_turns| {
                for (outer_chord_scales) |outer_chord_scale| {
                    for (inner_chord_scales) |inner_chord_scale| {
                        const scales: ChordScales = .{ .outer = outer_chord_scale, .inner = inner_chord_scale };
                        const candidate: Layout = settled(room, rotation_turns, scales);
                        const best_size_unit: f32 = if (best) |best_so_far| best_so_far.size_unit else -1;
                        const is_better: bool = candidate.size_unit > best_size_unit;
                        if (is_better) {
                            best = candidate;
                        }
                    }
                }
            }
        }
        return best.?;
    }

    /// The sizes of the chords' two ellipses, as multiples of the notes'.
    const ChordScales = struct {
        outer: f32,
        inner: f32,
    };

    /// The layout with the figure turned by `rotation_turns` and its chords' ellipses at `scales`, its places and its
    /// sizes settled together in `room`.
    fn settled(room: z.Rectangle, rotation_turns: f32, scales: ChordScales) Layout {
        // First guess: no size at all, and the figure as large as the room.
        var layout: Layout = .{
            .centre = .{ room.x + room.width / 2, room.y + room.height / 2 },
            .note_ellipse_radii = .{ room.width, room.height },
            .rotation_turns = rotation_turns,
            .outer_chord_scale = scales.outer,
            .inner_chord_scale = scales.inner,
            .size_unit = 0,
        };
        layout.fitToRoom(room);
        for (0..settling_rounds) |_| {
            layout.size_unit = layout.largestSizeUnit();
            layout.fitToRoom(room);
        }
        return layout;
    }

    fn noteHalfSize(layout: Layout) f32 {
        return note_size_in_units * layout.size_unit;
    }

    fn chordHalfSize(layout: Layout, chord: ScaleChord) f32 {
        return chordSizeInUnits(chord) * layout.size_unit;
    }

    /// The fourteen targets: seven notes, then seven chords.
    const target_count: usize = 14;

    /// Stretches the figure to fill `room`, at the sizes it has now: on each axis, the ellipses' radius and the
    /// figure's centre such that the figure's outermost note or chord touches the room's edges on both sides
    /// (`fitAxis`).
    fn fitToRoom(layout: *Layout, room: z.Rectangle) void {
        var place_offsets: [target_count]Vec2 = undefined;
        var half_sizes: [target_count]f32 = undefined;
        for (scale_notes, 0..) |note, note_index| {
            place_offsets[note_index] = layout.noteCentre(note.degree) - layout.centre;
            half_sizes[note_index] = layout.noteHalfSize();
        }
        for (scale_chords, 0..) |chord, chord_index| {
            place_offsets[7 + chord_index] = layout.chordCentre(chord) - layout.centre;
            half_sizes[7 + chord_index] = layout.chordHalfSize(chord);
        }
        // The places, as multiples of the radii now: what each axis's radius scales.
        var coefficients: [2][target_count]f32 = undefined;
        inline for (0..2) |axis| {
            for (0..target_count) |target_index| {
                const radius: f32 = layout.note_ellipse_radii[axis];
                coefficients[axis][target_index] = place_offsets[target_index][axis] / radius;
            }
        }
        const fit_x: AxisFit = fitAxis(&coefficients[0], &half_sizes, room.width);
        const fit_y: AxisFit = fitAxis(&coefficients[1], &half_sizes, room.height);
        layout.note_ellipse_radii = .{ fit_x.radius, fit_y.radius };
        layout.centre = .{ room.x + fit_x.centre_from_start, room.y + fit_y.centre_from_start };
    }

    /// One axis of a fit: the ellipses' radius along it, and where the figure's centre falls, from the room's start.
    const AxisFit = struct {
        radius: f32,
        centre_from_start: f32,
    };

    /// The largest radius at which targets placed at `coefficients x radius` from the centre, each `half_sizes` to
    /// either side, span no more than `room_length`, and the centre that puts that span in the middle of the room.
    /// The span only grows with the radius, so the largest is found by halving an interval that holds it, 32 times.
    fn fitAxis(
        coefficients: *const [target_count]f32,
        half_sizes: *const [target_count]f32,
        room_length: f32,
    ) AxisFit {
        var fitting_radius: f32 = 0;
        var too_large_radius: f32 = 4 * room_length;
        for (0..32) |_| {
            const trial_radius: f32 = (fitting_radius + too_large_radius) / 2;
            const trial_span: Span = spanAt(coefficients, half_sizes, trial_radius);
            if (trial_span.high - trial_span.low <= room_length) {
                fitting_radius = trial_radius;
            } else {
                too_large_radius = trial_radius;
            }
        }
        const span: Span = spanAt(coefficients, half_sizes, fitting_radius);
        // The span's middle at the room's middle.
        return .{ .radius = fitting_radius, .centre_from_start = room_length / 2 - (span.low + span.high) / 2 };
    }

    /// Where the figure reaches along one axis, measured from its centre: its lowest and its highest points.
    const Span = struct {
        low: f32,
        high: f32,
    };

    fn spanAt(
        coefficients: *const [target_count]f32,
        half_sizes: *const [target_count]f32,
        radius: f32,
    ) Span {
        var span: Span = .{ .low = inf(f32), .high = -inf(f32) };
        for (coefficients, half_sizes) |coefficient, half_size| {
            const centre_offset: f32 = coefficient * radius;
            span.low = @min(span.low, centre_offset - half_size);
            span.high = @max(span.high, centre_offset + half_size);
        }
        return span;
    }

    /// The clear space kept between two targets, in size units: between any two, and - wider, so that the lines
    /// between them have room to show their shapes - between a chord and its own three notes.
    const clearance_in_units: f32 = 0.3;
    const own_note_clearance_in_units: f32 = 0.55;

    /// The largest size unit at which none of the fourteen targets comes nearer another than its clearance, at the
    /// places the ellipses give them now: the smallest of the limits every pair sets (`largestUnitApart`).
    fn largestSizeUnit(layout: Layout) f32 {
        var size_unit: f32 = inf(f32);
        for (scale_notes, 0..) |note, note_index| {
            const note_centre: Vec2 = layout.noteCentre(note.degree);
            const note_shape: ShapedSize = .{
                .shape = shapeOfDegree(note.degree),
                .size_in_units = note_size_in_units,
            };
            for (scale_notes[note_index + 1 ..]) |other_note| {
                const other_shape: ShapedSize = .{
                    .shape = shapeOfDegree(other_note.degree),
                    .size_in_units = note_size_in_units,
                };
                const offset: Vec2 = layout.noteCentre(other_note.degree) - note_centre;
                size_unit = @min(size_unit, largestUnitApart(offset, note_shape, other_shape, clearance_in_units));
            }
            for (scale_chords) |chord| {
                const is_own_note: bool = indexOfScalar(u8, &chord.degrees(), note.degree) != null;
                const clearance: f32 = if (is_own_note) own_note_clearance_in_units else clearance_in_units;
                const chord_shape: ShapedSize = shapedSizeOfChord(chord);
                const offset: Vec2 = layout.chordCentre(chord) - note_centre;
                size_unit = @min(size_unit, largestUnitApart(offset, note_shape, chord_shape, clearance));
            }
        }
        for (scale_chords, 0..) |chord, chord_index| {
            const chord_centre: Vec2 = layout.chordCentre(chord);
            const chord_shape: ShapedSize = shapedSizeOfChord(chord);
            for (scale_chords[chord_index + 1 ..]) |other_chord| {
                const other_shape: ShapedSize = shapedSizeOfChord(other_chord);
                const offset: Vec2 = layout.chordCentre(other_chord) - chord_centre;
                size_unit = @min(size_unit, largestUnitApart(offset, chord_shape, other_shape, clearance_in_units));
            }
        }
        return size_unit;
    }

    /// The point at place `circle_place` of 7, clockwise from the figure's top, on the notes' ellipse scaled by
    /// `scale`. Angles are in turns: place `k` is `k / 7` of a turn round from the figure's rotation. The screen's y
    /// grows downward, so the top is -y.
    fn pointAtPlace(layout: Layout, circle_place: u8, scale: f32) Vec2 {
        const angle_turns: f32 = layout.rotation_turns + float(circle_place) / 7;
        const direction: Vec2 = .{ sinTurns(angle_turns), -cosTurns(angle_turns) };
        const radii: Vec2 = layout.note_ellipse_radii * splat2(scale);
        return layout.centre + direction * radii;
    }

    fn noteCentre(layout: Layout, degree: u8) Vec2 {
        return layout.pointAtPlace(circlePlaceOfDegree(degree), 1);
    }

    /// A chord's centre: at the place of its third, on the outer ellipse for a major chord, the inner for the others.
    fn chordCentre(layout: Layout, chord: ScaleChord) Vec2 {
        const third_degree: u8 = chord.degrees()[1];
        const scale: f32 = if (chord.isMinorSide()) layout.inner_chord_scale else layout.outer_chord_scale;
        return layout.pointAtPlace(circlePlaceOfDegree(third_degree), scale);
    }
};

// ---- Drawing ----

/// What the pointer presses: a note, by its degree, or a chord, by its index in `scale_chords`.
const PointerTarget = union(enum) {
    note: u8,
    chord: u8,
};

/// A pointer holding a target: a finger, by the identifier the platform gives it for as long as it touches - the
/// same from frame to frame, wherever it moves - or the mouse.
const PointerHold = struct {
    pointer_id: i32,
    target: PointerTarget,
};

/// The most pointers held at once: the ten touches the engine tracks, and the mouse.
const most_pointers: usize = 11;

/// The mouse's identifier among the pointers: one no touch is given, touches being numbered up from 0.
const mouse_pointer_id: i32 = -1;

/// A pointer down this frame: its identifier and where it is.
const PointerNow = struct {
    pointer_id: i32,
    position: Vec2,
};

const State = struct {
    font: z.Font,
    /// For each degree, how many things hold its note down: its key, each finger on the note, each finger on a chord
    /// that contains it. The note's key goes down when its count leaves 0 and up when it returns to 0, so that a note
    /// held several ways at once - its digit, and a chord containing it - sounds once and stops only when all let go.
    hold_counts: [7]u8,
    /// Which degrees their keys hold, so that a key's release is matched with its press.
    is_held_by_key: [7]bool,
    /// What each pointer holds, while it is down: a slot each, free when null.
    pointer_holds: [most_pointers]?PointerHold,
    /// The layout last worked out, and the window's size it was worked out for (`layoutOf`).
    layout: ?Layout,
    layout_window_size: Vec2,
    /// Whether the screen has reported a touch. A browser also turns a touch into the mouse's press and movement,
    /// so that pages written for a mouse work on a phone; once a touch has been seen, the mouse is ignored, and each
    /// finger counts once, as itself.
    has_seen_touch: bool,
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 32);
    s.* = .{
        .font = font,
        .hold_counts = @splat(0),
        .is_held_by_key = @splat(false),
        .pointer_holds = @splat(null),
        .layout = null,
        .layout_window_size = .{ 0, 0 },
        .has_seen_touch = false,
    };
    z.audio_device.init(f.audio_device);
    f.mixer.setInstrument(z.mixer.shepard_instrument);
}

// ---- Playing ----

/// One more hold on a degree's note: the first starts it.
fn holdDegree(f: *z.Frame, s: *State, degree: u8) void {
    s.hold_counts[degree - 1] += 1;
    if (s.hold_counts[degree - 1] == 1) {
        _ = f.mixer.sendNote(.{ .key = keyOfDegree(degree), .is_down = true, .velocity = note_velocity });
    }
}

/// One hold fewer on a degree's note: the last releases it.
fn releaseDegree(f: *z.Frame, s: *State, degree: u8) void {
    assert(s.hold_counts[degree - 1] > 0, @src());
    s.hold_counts[degree - 1] -= 1;
    if (s.hold_counts[degree - 1] == 0) {
        _ = f.mixer.sendNote(.{ .key = keyOfDegree(degree), .is_down = false });
    }
}

fn holdTarget(f: *z.Frame, s: *State, target: PointerTarget) void {
    switch (target) {
        .note => |degree| holdDegree(f, s, degree),
        .chord => |chord_index| for (scale_chords[chord_index].degrees()) |degree| {
            holdDegree(f, s, degree);
        },
    }
}

fn releaseTarget(f: *z.Frame, s: *State, target: PointerTarget) void {
    switch (target) {
        .note => |degree| releaseDegree(f, s, degree),
        .chord => |chord_index| for (scale_chords[chord_index].degrees()) |degree| {
            releaseDegree(f, s, degree);
        },
    }
}

/// The keys: a degree's digit or keypad key pressed this frame holds its note; once neither is down any more, the
/// note is let go.
fn readKeys(f: *z.Frame, s: *State) void {
    for (digit_keys, keypad_keys, 0..) |digit_key, keypad_key, degree_index| {
        const degree: u8 = @intCast(degree_index + 1);
        const is_pressed: bool = z.isKeyPressed(f.input, digit_key) or z.isKeyPressed(f.input, keypad_key);
        const is_down: bool = z.isKeyDown(f.input, digit_key) or z.isKeyDown(f.input, keypad_key);
        if (is_pressed and !s.is_held_by_key[degree_index]) {
            s.is_held_by_key[degree_index] = true;
            holdDegree(f, s, degree);
        } else if (s.is_held_by_key[degree_index] and !is_down) {
            s.is_held_by_key[degree_index] = false;
            releaseDegree(f, s, degree);
        }
    }
}

/// The note or chord nearest `point`, by the distance to its shape: every point of the window belongs to one, so that a
/// press anywhere plays - the window is divided among the fourteen targets, each taking the points nearer to it than
/// to any other. A point inside a shape is at distance 0 from it, and so belongs to it.
fn nearestTarget(layout: Layout, point: Vec2) PointerTarget {
    var nearest: PointerTarget = .{ .note = 1 };
    var nearest_distance: f32 = inf(f32);
    for (scale_notes) |note| {
        const note_centre: Vec2 = layout.noteCentre(note.degree);
        const note_shape: Shape = shapeOfDegree(note.degree);
        const note_distance: f32 = distanceToShape(point, note_centre, note_shape, layout.noteHalfSize());
        if (note_distance < nearest_distance) {
            nearest = .{ .note = note.degree };
            nearest_distance = note_distance;
        }
    }
    for (scale_chords, 0..) |chord, chord_index| {
        const chord_centre: Vec2 = layout.chordCentre(chord);
        const chord_half_size: f32 = layout.chordHalfSize(chord);
        const chord_distance: f32 = distanceToShape(point, chord_centre, shapeOfChord(chord), chord_half_size);
        if (chord_distance < nearest_distance) {
            nearest = .{ .chord = @intCast(chord_index) };
            nearest_distance = chord_distance;
        }
    }
    return nearest;
}

/// The pointers down this frame: every finger on the screen, or - on a device that has never reported a touch - the
/// mouse while its button is down.
fn pointersDown(
    f: *z.Frame,
    s: *State,
    pointers: *[most_pointers]PointerNow,
) []const PointerNow {
    const touch_count: usize = @intCast(z.getTouchPointCount(f.input));
    if (touch_count > 0) {
        s.has_seen_touch = true;
    }
    var pointer_count: usize = 0;
    for (0..touch_count) |touch_index| {
        const touch_slot: i32 = @intCast(touch_index);
        pointers[pointer_count] = .{
            .pointer_id = z.getTouchPointId(f.input, touch_slot),
            .position = z.getTouchPosition(f.input, touch_slot),
        };
        pointer_count += 1;
    }
    const is_mouse_down: bool = z.isMouseButtonDown(f.input, .left);
    if (!s.has_seen_touch and is_mouse_down) {
        pointers[pointer_count] = .{ .pointer_id = mouse_pointer_id, .position = z.getMousePosition(f.input) };
        pointer_count += 1;
    }
    return pointers[0..pointer_count];
}

/// The pointers, each on its own - several fingers play several notes and chords at once. A pointer pressed anywhere
/// holds the nearest note or chord (`nearestTarget`); moved nearer another while still down, it lets the first go and
/// holds the second, as a finger sliding across them; lifted, it lets go.
fn readPointers(f: *z.Frame, s: *State, layout: Layout) void {
    var pointers_buffer: [most_pointers]PointerNow = undefined;
    const pointers: []const PointerNow = pointersDown(f, s, &pointers_buffer);
    // A hold whose pointer is no longer down lets its target go.
    for (&s.pointer_holds) |*hold_slot| {
        const hold: PointerHold = hold_slot.* orelse continue;
        const is_still_down: bool = for (pointers) |pointer| {
            if (pointer.pointer_id == hold.pointer_id) {
                break true;
            }
        } else false;
        if (!is_still_down) {
            releaseTarget(f, s, hold.target);
            hold_slot.* = null;
        }
    }
    // Each pointer down: one already holding follows its finger to the nearest target; a new one takes a free slot.
    for (pointers) |pointer| {
        const target_now: PointerTarget = nearestTarget(layout, pointer.position);
        const held_slot: ?*?PointerHold = for (&s.pointer_holds) |*hold_slot| {
            const hold: PointerHold = hold_slot.* orelse continue;
            if (hold.pointer_id == pointer.pointer_id) {
                break hold_slot;
            }
        } else null;
        if (held_slot) |hold_slot| {
            const held_target: PointerTarget = hold_slot.*.?.target;
            if (!std.meta.eql(held_target, target_now)) {
                releaseTarget(f, s, held_target);
                holdTarget(f, s, target_now);
                hold_slot.* = .{ .pointer_id = pointer.pointer_id, .target = target_now };
            }
            continue;
        }
        const free_slot: ?*?PointerHold = for (&s.pointer_holds) |*hold_slot| {
            if (hold_slot.* == null) {
                break hold_slot;
            }
        } else null;
        if (free_slot) |hold_slot| {
            holdTarget(f, s, target_now);
            hold_slot.* = .{ .pointer_id = pointer.pointer_id, .target = target_now };
        }
    }
}

/// Whether a degree's note sounds: something holds it.
fn isDegreeSounding(s: *const State, degree: u8) bool {
    return s.hold_counts[degree - 1] > 0;
}

/// Whether a chord is lit: all three of its notes sound, however they are held.
fn isChordSounding(s: *const State, chord: ScaleChord) bool {
    for (chord.degrees()) |degree| {
        if (!isDegreeSounding(s, degree)) {
            return false;
        }
    }
    return true;
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

/// How a line from a chord to one of its notes is drawn: by the note's role in the chord.
const LineRole = enum { root, third, fifth };

/// The color of a line by the role of the note it leads to: the root red, the third yellow, the fifth cyan - the
/// colors of 1, 3 and 5, the root, third and fifth of the scale's first chord.
fn roleColor(role: LineRole) Color {
    return switch (role) {
        .root => degree_colors[0],
        .third => degree_colors[2],
        .fifth => degree_colors[4],
    };
}

/// The width of the drawing's strokes - rings, borders, lines - in proportion to the notes' size.
fn strokeThickness(layout: Layout) f32 {
    return @max(1.5, 0.07 * layout.size_unit);
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
    f.gl.text(top_left, text, .{ .size = size, .color = color, .font = &s.font });
}

/// A solid line from `start` to `end`, ending in a filled arrowhead whose tip is at `end`.
fn drawArrow(
    f: *z.Frame,
    start: Vec2,
    end: Vec2,
    thickness: f32,
    head_length: f32,
    color: Color,
) void {
    const offset: Vec2 = end - start;
    const line_length: f32 = length(offset);
    if (line_length <= head_length) {
        return;
    }
    const along: Vec2 = offset / splat2(line_length);
    const across: Vec2 = .{ -along[1], along[0] };
    const head_base: Vec2 = end - along * splat2(head_length);
    const half_head_width: Vec2 = across * splat2(head_length * 0.45);
    f.gl.line(start, head_base, .{ .color = color, .thickness = thickness });
    f.gl.triangle(end, head_base + half_head_width, head_base - half_head_width, .{ .color = color });
}

/// A zigzag from `start` to `end`: straight for its first and last quarter-wavelength, so that it meets its ends
/// cleanly, and between them a line that swings `amplitude` to either side of the straight one, once every
/// `wavelength`.
fn drawZigzag(
    f: *z.Frame,
    start: Vec2,
    end: Vec2,
    thickness: f32,
    wavelength: f32,
    color: Color,
) void {
    const offset: Vec2 = end - start;
    const line_length: f32 = length(offset);
    if (line_length <= wavelength) {
        f.gl.line(start, end, .{ .color = color, .thickness = thickness });
        return;
    }
    const along: Vec2 = offset / splat2(line_length);
    const across: Vec2 = .{ -along[1], along[0] };
    const amplitude: f32 = wavelength * 0.4;
    // Corners every half wavelength, alternating to either side, over the length between the two straight ends.
    const half_wavelength: f32 = wavelength / 2;
    const zigzag_length: f32 = line_length - half_wavelength;
    const corner_count: usize = @floor(zigzag_length / half_wavelength);
    var previous_point: Vec2 = start;
    for (0..corner_count) |corner_index| {
        const distance_along: f32 = half_wavelength / 2 + float(corner_index) * half_wavelength;
        const side: f32 = if (corner_index % 2 == 0) amplitude else -amplitude;
        const corner: Vec2 = start + along * splat2(distance_along) + across * splat2(side);
        f.gl.line(previous_point, corner, .{ .color = color, .thickness = thickness });
        previous_point = corner;
    }
    f.gl.line(previous_point, end, .{ .color = color, .thickness = thickness });
}

/// The line from a chord to one of its notes: it leaves the chord's shape at its edge and stops just short of the
/// note's, drawn in the style and the color of the note's role (`LineRole`).
fn drawChordLine(
    f: *z.Frame,
    layout: Layout,
    chord: ScaleChord,
    note_degree: u8,
    role: LineRole,
    is_lit: bool,
) void {
    const note_centre: Vec2 = layout.noteCentre(note_degree);
    const chord_centre: Vec2 = layout.chordCentre(chord);
    const start: Vec2 = shapeEdgeToward(chord_centre, shapeOfChord(chord), layout.chordHalfSize(chord), note_centre);
    const gap_beyond_note: f32 = 1.15 * layout.noteHalfSize();
    const end: Vec2 = shapeEdgeToward(note_centre, shapeOfDegree(note_degree), gap_beyond_note, start);
    if (length(end - start) <= 0.5 * layout.size_unit) {
        return;
    }
    // A lit chord's lines are drawn whole and twice as thick, so that the chord stands out from the six others.
    const whole_color: Color = roleColor(role);
    const color: Color = if (is_lit) whole_color else whole_color.lerp(background, resting_dimming);
    const resting_thickness: f32 = strokeThickness(layout);
    const thickness: f32 = if (is_lit) 2 * resting_thickness else resting_thickness;
    const size_unit: f32 = layout.size_unit;
    switch (role) {
        .root => drawArrow(f, start, end, thickness, 0.5 * size_unit, color),
        .third => drawZigzag(f, start, end, thickness, 0.35 * size_unit, color),
        .fifth => {
            const dash_length: f32 = 0.3 * size_unit;
            f.gl.lineDashed(start, end, thickness, dash_length, dash_length * 0.8, .{ .color = color });
        },
    }
}

/// A chord's two triangles, filled faintly with the chord's color: one between the chord, its root and its third, the
/// other between the chord, its third and its fifth - IV's green between IV, 4 and 6, and fainter between IV, 6 and
/// 1 - so that each chord's part of the figure reads as one region. Drawn first, under the lines and the shapes. Not
/// for vii, the diminished chord, which sits among the others inside.
fn drawChordTriangles(f: *z.Frame, layout: Layout, chord: ScaleChord, is_lit: bool) void {
    if (chord.quality == .diminished) {
        return;
    }
    const chord_degrees: [3]u8 = chord.degrees();
    const chord_centre: Vec2 = layout.chordCentre(chord);
    const root_centre: Vec2 = layout.noteCentre(chord_degrees[0]);
    const third_centre: Vec2 = layout.noteCentre(chord_degrees[1]);
    const fifth_centre: Vec2 = layout.noteCentre(chord_degrees[2]);
    const chord_color: Color = degree_colors[chord.root_degree - 1];
    const root_third_amount: f32 = if (is_lit) root_third_dimming.lit else root_third_dimming.resting;
    const third_fifth_amount: f32 = if (is_lit) third_fifth_dimming.lit else third_fifth_dimming.resting;
    const root_third_color: Color = chord_color.lerp(background, root_third_amount);
    const third_fifth_color: Color = chord_color.lerp(background, third_fifth_amount);
    f.gl.triangle(chord_centre, root_centre, third_centre, .{ .color = root_third_color });
    f.gl.triangle(chord_centre, third_centre, fifth_centre, .{ .color = third_fifth_color });
}

/// A shape filled with `fill_color` and outlined.
fn drawShape(
    f: *z.Frame,
    centre: Vec2,
    shape: Shape,
    half_size: f32,
    fill_color: Color,
    stroke: f32,
) void {
    switch (shape) {
        .square => {
            const square: z.Rectangle = .{
                .x = centre[0] - half_size,
                .y = centre[1] - half_size,
                .width = 2 * half_size,
                .height = 2 * half_size,
            };
            f.gl.rect(square, .{ .color = fill_color });
            f.gl.rect(square, .{ .color = outline_color, .outline = stroke });
        },
        .circle => {
            f.gl.circle(centre, half_size, .{ .color = fill_color });
            f.gl.circle(centre, half_size, .{ .color = outline_color, .outline = stroke });
        },
    }
}

/// The circle the notes sit on, as seven straight segments from note to note round the circle - the path of thirds.
fn drawCirclePath(f: *z.Frame, layout: Layout) void {
    for (0..7) |circle_place| {
        const place: u8 = @intCast(circle_place);
        const next_place: u8 = (place + 1) % 7;
        const point: Vec2 = layout.pointAtPlace(place, 1);
        const next_point: Vec2 = layout.pointAtPlace(next_place, 1);
        f.gl.line(point, next_point, .{ .color = circle_path_color, .thickness = 1.5 });
    }
}

/// A note: its shape - a square on the major side, a circle on the minor - in its color, dimmed until it sounds; its
/// degree, large, and its letter and solfege name beneath.
fn drawNote(
    f: *z.Frame,
    s: *State,
    layout: Layout,
    note: ScaleNote,
    is_lit: bool,
) void {
    const centre: Vec2 = layout.noteCentre(note.degree);
    const half_size: f32 = layout.noteHalfSize();
    const fill_color: Color = colorOfDegree(note.degree, is_lit);
    drawShape(f, centre, shapeOfDegree(note.degree), half_size, fill_color, strokeThickness(layout));
    const degree_color: Color = if (is_lit) lit_text_color else text_color;
    const degree_text: [1]u8 = .{'0' + note.degree};
    const degree_centre: Vec2 = centre - @as(Vec2, .{ 0, 0.25 * half_size });
    drawCentredText(f, s, degree_centre, &degree_text, 0.9 * half_size, degree_color);
    var names_buffer: [16]u8 = undefined;
    const names: []const u8 = bufPrint(&names_buffer, "{s} {s}", .{ note.letter, note.solfege }) catch "";
    const names_centre: Vec2 = centre + @as(Vec2, .{ 0, 0.45 * half_size });
    drawCentredText(f, s, names_centre, names, 0.42 * half_size, degree_color);
}

/// A chord: its shape - a square for a major chord, a circle for the others - in its root's color, dimmed until it
/// sounds, and its numeral.
fn drawChord(
    f: *z.Frame,
    s: *State,
    layout: Layout,
    chord: ScaleChord,
    is_lit: bool,
) void {
    const centre: Vec2 = layout.chordCentre(chord);
    const half_size: f32 = layout.chordHalfSize(chord);
    const fill_color: Color = colorOfDegree(chord.root_degree, is_lit);
    drawShape(f, centre, shapeOfChord(chord), half_size, fill_color, strokeThickness(layout));
    const name_color: Color = if (is_lit) lit_text_color else text_color;
    drawCentredText(f, s, centre, chord.name, 0.7 * half_size, name_color);
}

fn draw(f: *z.Frame, s: *State, layout: Layout) void {
    z.clearViewport(f, background);
    const legend: []const u8 = "root: arrow   third: zigzag   fifth: dashes";
    f.gl.text(.{ 8, 8 }, legend, .{ .size = 14, .color = dim_text_color, .font = &s.font });
    // The chords' triangles first, under everything.
    for (scale_chords) |chord| {
        drawChordTriangles(f, layout, chord, isChordSounding(s, chord));
    }
    drawCirclePath(f, layout);
    // The lines next, so that the notes and the boxes are drawn over their ends.
    for (scale_chords) |chord| {
        const chord_degrees: [3]u8 = chord.degrees();
        const is_chord_lit: bool = isChordSounding(s, chord);
        drawChordLine(f, layout, chord, chord_degrees[0], .root, is_chord_lit);
        drawChordLine(f, layout, chord, chord_degrees[1], .third, is_chord_lit);
        drawChordLine(f, layout, chord, chord_degrees[2], .fifth, is_chord_lit);
    }
    for (scale_notes) |note| {
        drawNote(f, s, layout, note, isDegreeSounding(s, note.degree));
    }
    for (scale_chords) |chord| {
        drawChord(f, s, layout, chord, isChordSounding(s, chord));
    }
}

/// The layout for the window's size now: worked out again only when the size changes, since `Layout.ofWindow` tries
/// dozens of layouts to find it.
fn layoutOf(f: *z.Frame, s: *State) Layout {
    const window_size: Vec2 = .{ f.window.widthf(), f.window.heightf() };
    const is_same_size: bool = window_size[0] == s.layout_window_size[0] and window_size[1] == s.layout_window_size[1];
    if (s.layout) |kept_layout| {
        if (is_same_size) {
            return kept_layout;
        }
    }
    const layout: Layout = .ofWindow(f);
    s.layout = layout;
    s.layout_window_size = window_size;
    return layout;
}

fn update(f: *z.Frame, s: *State) void {
    // A black screen with a start button, until it is pressed and the audio runs (`z.showAudioStartScreen`).
    if (z.showAudioStartScreen(f, &s.font)) {
        return;
    }
    const layout: Layout = layoutOf(f, s);
    readKeys(f, s);
    readPointers(f, s, layout);
    draw(f, s, layout);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - the major scale in thirds",
            .width = 720,
            .height = 760,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
