//! examples/audio_scale_star_hands - a scale played with two hands: the left hand chooses a chord, the right hand plays
//! its notes. One scale - a tonic and a mode, C Ionian to begin with - is shown several ways at once, and every view
//! lights the same notes as they sound, in the same colors: each degree of the scale has its color in every key, the
//! tonic red, so that what a note does in the key, not which note it is, is what the eye learns.
//!
//! The window
//!
//!     +---------+----------------------------------------+---------+
//!     | options |  [ I ]  [ V ]  [ vi ]  [ IV ]  editor   | the     |
//!     +---------+                                        | twelve  |
//!     | key's   |                                        | notes   |
//!     | window  |                 the star               +---------+
//!     |         |                                        | what    |
//!     +---------+                                        | sounds  |
//!     | chooser |                                        |         |
//!     +---------+----------------------------------------+---------+
//!     |                        keyboard                      | [ ] |
//!     +------------------------------------------------------+-----+
//!
//!     the editor        the progression the track plays, a row of 2 to 16 boxes along the star's top
//!                       (`drawProgressionEditor`)
//!     the star          the main diagram, for the right hand: the scale's seven notes on a curve in thirds, and its
//!                       seven chords round them (`StarLayout`)
//!     the key's window  the scale's chords as the circle of fifths' chord wheel arranges them, each drawn as its
//!                       guitar chord (`FifthsLayout`)
//!     the chooser       the seven chords again, as buttons for the left hand's thumb (`ChooserLayout`)
//!     the twelve notes  the octave's twelve pitch classes on a circle in order of pitch, the sounding ones joined and
//!                       named as a chord (`ChromaticLayout`, `nameOfChord`)
//!     what sounds       the notes sounding as a Lissajous figure, their chord's numeral over it and its function in
//!                       the key under it - Tonic, Dominant (`drawChordCurve`, `drawChordNumeral`, `drawFunctionName`)
//!     the keyboard      the scale's notes from the tonic to the tonic, laid out as a piano lays them (`drawKeyboard`)
//!     the options       a panel along the left, opened from the top left and closed by a tap beside it
//!                       (`buildOptions`): the scale, the progression track, the volumes and the display's choices
//!
//! The parts are laid out for the window's shape (`WindowParts`): on a phone held upright, the left column becomes a
//! band across the top and the sounding box a strip under the star. The bottom right corner is left to the page's
//! fullscreen button.
//!
//! The scale
//!
//! A scale is a tonic - A to G#, a sharp spelled as the tonic's letter raised - and a mode: the seven church modes and
//! four more, harmonic and melodic minor, harmonic major, Phrygian dominant (`Scale`, `Mode`). Each degree is spelled
//! with its own letter, so that a scale names each letter once - F# Ionian's seventh is E#, G# Ionian's F## - and
//! carries a solfege syllable fixed to the letter, as French names notes. On each degree stands a triad, the degree and
//! the notes a third and a fifth above it in the scale (`ScaleChord`); its quality - major, minor, diminished or
//! augmented - is read from its semitones, and its numeral from its degree and quality: I, ii, vii. A progression may
//! borrow a chord from outside the scale - III major where the key has iii minor - which is offered beside its root's
//! own chord and, while held, raises or lowers the one note that differs (`alterationsForChord`).
//!
//! The star
//!
//! The notes stand on a curve in thirds - 1 3 5 7 2 4 6 - so that any three neighbours make a chord: 1 3 5 is I, 2 4 6
//! is ii. The curve is an ellipse whose bottom is cut off by a straight line, its height chosen so that the whole
//! curve is seven equal steps long (`StarCurve`): every note is a step from the next, along the line or along the arc.
//! As the star rests, 1, 3 and 5 stand on the line under the index, middle and ring fingers - the chosen chord's notes,
//! drawn a fifth larger than the others, the tonic larger still. The white path joining the notes is the curve itself,
//! arcs above and the line below, and halfway along each link sits a small copy of the note between its two ends in the
//! scale - the 2 between 1 and 3 - so that a melody up the scale walks along the path (`NoteProxy`).
//!
//! Each chord stands at its third's place, a triplet of its three notes' shapes, its own in front (`ChordTriplet`):
//! the chords of one side - the major side as the star rests - on a ring outside the curve, the others on a ring
//! inside, the diminished chord outside. A chord's region is two fans from it to the arcs its notes span, root to third
//! and third to fifth; every link of the curve is faced by one chord outside and one inside, so the white arc is where
//! their regions meet and none cross (`drawChordShapes`). Lines run from a chord to its notes: an arrow to its root, a
//! zigzag to its third, dashes to its fifth. The layout makes everything as large as the room allows at every one of
//! the star's seven turns, no two targets nearer than their clearance (`StarLayout.settled`).
//!
//! The chosen chord's notes are outlined on the star by their part in it - root red, third yellow, fifth cyan - and its
//! button in white (`drawChordOutlines`). Where the options say so, the star instead turns, in 0.04 seconds, to bring
//! the chosen chord's notes into the row, so that the same three fingers play whichever chord is chosen, its chords
//! trading sides so that the chosen one stands outside, below its notes (`aimStar`); while the star moves, it plays
//! nothing.
//!
//! Playing
//!
//! Every finger plays what it touches and holds it until it lifts, following it as it slides (`readPointers`,
//! `targetAt`): a note of the star, or its proxy; a chord of the star, at full strength; a chord of the chooser or of
//! the key's window, at half strength, choosing it as well; a key of the keyboard; a note on the circle of twelve. The
//! digits 1 to 7 play the degrees. A chord starts note by note - root, then third, then fifth, a strum's delay apart,
//! 0.1 seconds unless the options say otherwise - so that its notes are heard (`holdChordDegrees`). A note sounds while
//! anything holds it, as strongly as its strongest hold, and stops when the last lets go (`DegreeHolds`). The notes are
//! Shepard tones, each sounding in every octave at once, so that notes differ in pitch class and not in height; two
//! pedals - the chosen chord's root and the tonic - can be held low beneath everything (`updatePedals`).
//!
//! The progression track
//!
//! The track plays the progression in the editor's boxes, along the star's top: a row of 2 to 16, as chosen in the
//! options, the empty ones passed over. A progression chosen in the options - a common one, or a song's, which also
//! sets the song's key - is placed in the boxes (`placeChosenProgression`); a chord dragged from anywhere it plays -
//! the star, the chooser, the key's window, a borrowed chord's button, another box - and dropped on a box replaces that
//! box's chord, and the track plays it from its next turn (`carryChords`, `dropChord`). The track sends its chords
//! travelling to their buttons on the chooser, one a bar at its tempo, a ghost of each button growing as it comes
//! (`drawProgressionTrack`); the box playing is outlined in white. By default the track waits at each chord for the
//! player to take it. The coming chord's notes are outlined on the star too, the outlines closing in on the notes as
//! the chord arrives, and every outline pulses on the beat. With "play the chords", the track chooses each chord itself
//! as it falls due, silently, the star following the song while the player plays its melody (`playProgressionChords`).
//!
//! The guitar chords
//!
//! Each chord of the key's window is drawn as a guitar chord chart, its fingering found by a search over every way to
//! play the chord within four frets in standard tuning - the root lowest, all three notes, four fingers at most, a
//! barre counting one - the cheapest by position, strings, fingers, stretch and open strings kept (`guitarChordOf`).
//! The open-position chords come out as every chart has them. Each dot is in its note's color; a note sounding is
//! ringed on every chart, and every other place on a chart where a sounding note could be played shows as a ring, so
//! that a chord played elsewhere - Am7 on the keyboard - shows over the charts how a guitar would play it.
//!
//! The file
//!
//! The file reads from its vocabulary to its frame: the params, every color, size, speed, default and limit in one
//! place (`params`); the scale - the degrees' colors, notes, chords and the circle of thirds; the pedals; shapes and
//! their sizes; the chooser's curve and the star's; the star's layout; the window's parts, the chooser and the circle
//! of twelve; guitar chords and the key's window; choosing a chord; the app's state; playing - holding and letting go
//! of notes; reading the input and the options; the chord's curve; naming the chord; drawing; the outlines; and the
//! frame, which runs them in turn.
const std = @import("std");
// Names used often enough to be worth using bare: from the standard library, the engine (`z`) and its math
// (`zm`). Each is the same declaration under a shorter name.
const Allocator = std.mem.Allocator;
const bufPrint = std.fmt.bufPrint;
const splitScalar = std.mem.splitScalar;
const asBytes = std.mem.asBytes;
const indexOfScalar = std.mem.indexOfScalar;
const eql = std.mem.eql;
const endsWith = std.mem.endsWith;
const startsWith = std.mem.startsWith;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const Vec2 = zm.Vec2;
const float = zm.float;
const sinTurns = zm.sinTurns;
const cosTurns = zm.cosTurns;
const length = zm.length;
const assert = zm.assert;
const clamp = zm.clamp;
const smoothstep = zm.smoothstep;
const exp = zm.exp;
const exp2 = zm.exp2;
const log2 = zm.log2;
const sqrt = zm.sqrt;
const inf = zm.inf;
const maxInt = zm.maxInt;
const gcd = zm.gcd;
const pi = zm.pi;
const float64 = zm.float64;
const splat2 = zm.splat2;

/// The font every text is drawn in: Atkinson Hyperlegible Mono, made for legibility, its letters distinct at small
/// sizes - embedded in the app.
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

// ---- The params ----

/// The app's tunable values in one place: every color, size, speed, default and limit the code reads and never
/// changes, grouped by topic. Each is read where it is needed - `params.colors.background` - and never passed.
const params = struct {
    /// The colors: the window's, the text's and the marks', each degree's own, and the outlines'.
    const colors = struct {
        /// The window's background: a near-black, blue-grey, against which the degrees' colors read clearly.
        const background: Color = .{ .r = 16, .g = 17, .b = 22, .a = 255 };
        /// Text and white marks: a soft white.
        const text: Color = .{ .r = 235, .g = 235, .b = 240, .a = 255 };
        /// Text that matters less, and a chart's fret number: a mid grey.
        const dim_text: Color = .{ .r = 150, .g = 156, .b = 170, .a = 255 };
        /// The thin lines of the boxes round the diagrams and the circle of twelve: a dark grey.
        const note_path: Color = .{ .r = 70, .g = 74, .b = 90, .a = 255 };
        /// The notes' outlines and the circle of thirds' path: a white a little softer than the text's.
        const outline: Color = .{ .r = 225, .g = 228, .b = 236, .a = 255 };
        /// A chosen chord's note's own outline: black, inside its colored one.
        const chosen_note_outline: Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
        /// Text on a lit note or chord, which is filled with its full color: dark, since some of the colors are light.
        const lit_text: Color = .{ .r = 16, .g = 17, .b = 22, .a = 255 };

        /// Each degree's color, as a rainbow keyboard colors its white keys from C: red, orange, yellow, green, cyan,
        /// blue, violet. A note is filled with its color, dimmed until it sounds; a chord takes its root's color.
        const degrees = [7]Color{
            .rgbHex(0xF52A2A),
            .rgbHex(0xFFA514),
            .rgbHex(0xFFF200),
            .rgbHex(0x18E018),
            .rgbHex(0x18E6F0),
            .rgbHex(0x1464FF),
            .rgbHex(0xA83CF0),
        };

        /// The boxes round the left hand's diagrams (`window.left_diagram_box_inset`): the star's note path's color,
        /// quiet on the background.
        const left_diagram_box: Color = note_path;

        /// A chord's outline: black, so that the chords - small among the notes - stand apart from them.
        const chord_outline: Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };

        /// The colors the outlines give a note by its part in a chord: its root red, its third yellow, its fifth cyan -
        /// the colors of the chord's own lines to its notes (`drawChordLine`): the arrow, the zigzag, the dashes.
        const role_outlines = [3]Color{
            .{ .r = 235, .g = 52, .b = 52, .a = 255 },
            .{ .r = 250, .g = 222, .b = 40, .a = 255 },
            .{ .r = 0, .g = 222, .b = 236, .a = 255 },
        };

        /// A black key of the keyboard: a little lighter than the background, so that it reads as a key against it.
        const black_key: Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };

        /// A white key the scale does not use: grey, a little lighter than the boxes' lines.
        const unused_white_key: Color = .{ .r = 92, .g = 96, .b = 108, .a = 255 };

        /// The light gray of a chart's strings and frets.
        const guitar_line: Color = .{ .r = 196, .g = 200, .b = 210, .a = 255 };
    };

    /// How far toward the background a color is drawn while what it fills is silent.
    const dimming = struct {
        /// How far toward the background a color is drawn while its note or chord is silent: lit, it is drawn whole.
        const resting: f32 = 0.45;

        /// How far toward the background a chord's fans are drawn (`drawChordShapes`): faint while the chord is
        /// silent, a little less faint while it sounds.
        const Fan = struct {
            /// While the chord is silent.
            resting: f32,
            /// While it sounds.
            lit: f32,
        };

        /// The fan to the arc from the root to the third is the more opaque of a chord's two: the third is what makes a
        /// chord major or minor.
        const root_third_fan: Fan = .{ .resting = 0.8, .lit = 0.6 };

        /// The fan to the arc from the third to the fifth, fainter.
        const third_fifth_fan: Fan = .{ .resting = 0.9, .lit = 0.76 };
    };

    /// The options' values as the app starts (`initState`), each named after the field it starts.
    const defaults = struct {
        /// How hard the chord held on the chooser strikes its notes, by default, as a share of the other notes'
        /// strength (`State.chooser_chord_volume`, set in the options): 0.3 of it, so that the left thumb's chord
        /// sounds well beneath what the right hand plays (`HoldLayer.thumb`).
        const chooser_chord_volume: f32 = 0.3;

        /// A pedal's loudness by default, as its voice's volume (`Pedal.volume`, set in the options): 0, silent - the
        /// pedals sound only once their sliders are raised.
        const pedal_volume: f32 = 0;

        /// The options' first choice of how many boxes, an index into `progression.box_counts`: 4.
        const progression_box_count_choice: i32 = 2;

        /// The progression's tempo, in beats a minute (`State.progression_beats_per_minute`, set in the options).
        const progression_beats_per_minute: f32 = 90;

        /// The delay between a chord's notes as it starts (`State.chord_strum_seconds`, set in the options): 0.1
        /// seconds, quick enough to be one chord, slow enough to hear its notes come in.
        const chord_strum_seconds: f32 = 0.1;
    };

    /// Playing: how hard a note is struck, how far a finger moves before it changes what it plays or carries a chord,
    /// and the keys that play the degrees.
    const playing = struct {
        /// How hard every note is struck: half the instrument's full level, so that a chord of three stays clear of
        /// clipping.
        const note_velocity: f32 = 0.5;

        /// The keys that play each degree while held: the top row's digits and the keypad's.
        const digit_keys = [7]z.KeyboardKey{ .one, .two, .three, .four, .five, .six, .seven };
        /// The keypad's digits, which play the degrees as the top row's do (`digit_keys`).
        const keypad_keys = [7]z.KeyboardKey{ .kp_1, .kp_2, .kp_3, .kp_4, .kp_5, .kp_6, .kp_7 };

        /// How far a pointer must move from where it took its target before it takes another: 6 pixels. Every point of
        /// the star, the chooser, the key's window and the circle belongs to its nearest target, so boundaries run
        /// everywhere, and a finger resting near one moves a pixel or two back and forth between touch events - each
        /// time it crossed, the note it held was let go and the next one struck, many times a second, heard as crackle.
        /// A finger sliding on moves far more than this, and changes target as soon as it crosses; one resting keeps
        /// what it holds.
        const target_switch_distance: f32 = 6;

        /// How far a finger carrying a chord goes from where it came down before the chord is shown following it, and
        /// before a box under it takes the chord when it lifts: 12 pixels - a tap's wobble does not carry a chord
        /// anywhere.
        const chord_drag_start_distance: f32 = 12;
    };

    /// The pedals' sound (`generatePedal`).
    const pedal = struct {
        /// The pedals: notes held low beneath everything while their checkboxes at the top are ticked, as an organist
        /// holds notes with the feet - one on the chosen chord's root, following the left hand, the other on the
        /// scale's tonic, unchanging. Each is a Shepard tone like the notes the hands play, but lower: the same pitch
        /// class sounding in every octave at once under a bell of loudness, the bell centred two octaves down - at
        /// 100 Hz rather than the instrument's 400. It keeps the notes' character, a pitch class with no height of its
        /// own, and sits beneath them. Each plays as a voice of its own (`generatePedal`), beside the instrument's
        /// notes.
        const bell_centre_hz: f64 = 100;

        /// The bell's width, its partials and their reach: as the Shepard instrument's (`z.mixer.shepard_*`) - one
        /// octave's standard deviation, ten partials an octave apart, five octaves either side of the centre.
        const bell_width_octaves: f64 = 1;
        /// Ten partials, an octave apart.
        const partial_count: usize = 10;
        /// The partials' reach: five octaves either side of the bell's centre.
        const reach_octaves: f64 = 5;

        /// How long a pedal takes to rise from silence to full: 30 ms, so that it starts without a click.
        const attack_seconds: f32 = 0.03;
    };

    /// The notes' and chords' sizes, in size units, and the shares of them drawn (`ShapedSize`).
    const sizes = struct {
        /// How far apart the three shapes of a chord's triplet stand on the star, as a share of a shape's width: a
        /// third, so that each hides two thirds of the one behind it (`ChordTriplet`).
        const chord_triplet_step_share: f32 = 1.0 / 3.0;

        /// A note's size: two units.
        const note_size_in_units: f32 = 2;
        /// The chosen chord's three notes - its root, third and fifth, at the places of 1, 3 and 5 under the right
        /// hand - are its heroes, drawn a fifth larger than the others.
        const hero_note_size_in_units: f32 = 2.4;
        /// The tonic beside the other notes, in every diagram - the star, the chooser, the key's window, the circle of
        /// the twelve: 30% larger, the scale's home found at a glance.
        const tonic_size_share: f32 = 1.3;
        /// How large a note is drawn beside the room the star's layout keeps for it (`StarLayout.noteHalfSize`): 95%,
        /// and the tonic 90%.
        const note_drawn_share: f32 = 0.95;
        /// The tonic's, a little smaller still, as it is the larger.
        const tonic_drawn_share: f32 = 0.9;
        /// A chord's size: one unit.
        const chord_size_in_units: f32 = 1;
        /// The scale's two main chords', a quarter larger.
        const main_chord_size_in_units: f32 = 1.25;
        /// The diminished chord's, a quarter smaller.
        const diminished_chord_size_in_units: f32 = 0.75;
        /// The largest of the chords' sizes: what the chooser's spacing must allow for.
        const largest_chord_size_in_units: f32 = main_chord_size_in_units;
    };

    /// The star's path and its turning (`drawNotePath`, `StarTransition`).
    const star = struct {
        /// The straight pieces each link of the star's curve is drawn in - the white path (`drawNotePath`) and the
        /// chords' fans' edges along it (`drawChordFan`), the same pieces, so that a fan meets the path exactly.
        const curve_pieces_per_link: usize = 24;

        /// How long the star takes to turn to a newly chosen chord, its chords trading sides with it: 0.04 seconds,
        /// under three frames at 60 a second - quick enough to follow the hand, slow enough to be seen moving.
        const transition_duration_seconds: f32 = 0.04;

        /// The circle of thirds' thickness beside the notes' outlines: 1.4 times.
        const note_path_thickness_share: f32 = 1.4;
    };

    /// The small copies of the notes halfway along the star's links (`NoteProxy`).
    const note_proxy = struct {
        /// How much of the room between a proxy and the notes either side of it the proxy takes for touches: three
        /// quarters; the rest, by the notes' edges, stays theirs.
        const room_share: f32 = 0.75;

        /// A proxy's size beside its note's: 22%.
        const size_share: f32 = 0.22;

        /// How far a touch reaches a proxy: within 1.8 times its half-size - more than its little size, so that a
        /// finger sliding along the link meets it, and less than halfway to the notes on either side.
        const reach: f32 = 1.8;

        /// The opacity of a proxy's fill, out of 255: faint beside the notes.
        const alpha: u8 = 150;
    };

    /// The window's parts: their shares of it and the room kept between and inside them (`WindowParts`).
    const window = struct {
        /// The room left between the keyboard's end and the fullscreen button, beyond the margin.
        const keyboard_gap_before_button: f32 = 16;

        /// The left hand's share of the window: its column - or its band, on a screen held upright - a quarter, leaving
        /// the star, where the right hand plays, the rest. The chooser's buttons are as large as its width allows: at a
        /// phone's proportions, 900 by 415, their size unit is 17.3 at a share of 0.21, 20.6 at this one - a fifth
        /// larger, room for their names - and no larger beyond it, the column's height then the limit.
        const chooser_share: f32 = 0.252;

        /// The key's window on the circle of fifths (`drawFifths`): its share of the left hand's column, at the top -
        /// 65%, room for its guitar chords - the chooser the rest below, 35%, its curve squished flatter to fit
        /// (`ChooserLayout.vertical_squish`).
        const fifths_share: f32 = 0.65;

        /// The circle of the twelve notes, at the top right: the side of its square as a share of the window's width.
        const chromatic_share: f32 = 0.2;

        /// The sounding box's height on a window held upright, as a share of the content's width: 30%.
        const upright_sounding_share: f32 = 0.3;

        /// The space between the left hand's column and the star, as a share of the content's width: 4%.
        const star_gap_share: f32 = 0.04;

        /// The space the header's window keeps after its text: its own padding, and a little more.
        const header_padding: f32 = 16;

        /// How far inside its part each of the left hand's diagrams is drawn: its box 3 pixels in - so that the key's
        /// window's and the chooser's, one above the other, do not touch - and its buttons 5 pixels in, clear of the
        /// box. Measured at a phone's proportions, 900 by 415, both diagrams then fit a size unit of 19.3, the two in
        /// balance with half the column's height each; 8 pixels in, 18.5.
        const left_diagram_box_inset: f32 = 3;
        /// The room kept inside each box, between its line and what it holds, in pixels.
        const left_diagram_padding: f32 = 5;

        /// How much of the circle's side the star stops short of the content's right edge: all of it - the star's room
        /// ends where the circle's square begins. Its top right corner holds the 7 and its chord now that the curve no
        /// longer pulls the 7 down beside the row (`warpAt`), and the star, fitted for every turn, would reach into the
        /// circle there.
        const star_under_chromatic_share: f32 = 1.0;

        /// A borrowed chord's button's size, as a share of its root's chord's.
        const borrowed_button_share: f32 = 0.6;

        /// The options panel's width, as a share of the window's - 70% - and the least it is: 460 pixels, for its
        /// labels.
        const options_panel_share: f32 = 0.7;
        /// The least the panel is: 460 pixels, room for its labels.
        const options_panel_least_width: f32 = 460;
    };

    /// The keyboard's keys (`drawKeyboard`).
    const keyboard = struct {
        /// A black key's width and height beside a white key's: 60% of each.
        const black_key_width_share: f32 = 0.6;
        const black_key_height_share: f32 = 0.6;

        /// How far a sounding key rises above the keyboard, as a share of its height: 30%.
        const sounding_key_rise_share: f32 = 0.3;
    };

    /// The outlines of the chosen chord's notes and of the coming chord's (`drawChordOutlines`).
    const outline = struct {
        /// The outlines' sizes, as shares of the note's half-size: the gap between a note and its outline; the chosen
        /// chord's outline's thickness, and the coming chord's, thinner; and how far out the coming chord's outline
        /// starts, closing in on its note as the chord travels to its button.
        const gap_share: f32 = 0.18;
        /// The chosen chord's outlines' thickness.
        const chosen_share: f32 = 0.26;
        /// The coming chord's, thinner.
        const coming_share: f32 = 0.07;
        /// How far out the coming chord's outline starts, closing in on its note as the chord comes.
        const coming_reach_share: f32 = 0.9;
        /// The coming chord's button's outline beside its notes': twice as thick, and setting out five times as far.
        const coming_button_thickness_factor: f32 = 2;
        const coming_button_reach_factor: f32 = 5;

        /// The share of a bar the coming chord's outlines show for, on every view - the star's notes and button, the
        /// keyboard's keys, the circle's notes: its second half, the outlines appearing at its middle and closing in by
        /// its end, as the chord arrives.
        const coming_shown_share: f32 = 0.5;
    };

    /// The progression track and its editor (`advanceProgression`, `drawProgressionEditor`).
    const progression = struct {
        /// The beats each chord of a progression lasts: a bar of four.
        const beats_per_chord: f64 = 4;

        /// How many boxes the editor shows, as the options offer them - the progressions' lengths and the bars' usual
        /// groupings - and their labels there.
        const box_counts = [_]u8{ 2, 3, 4, 6, 8, 12, 16 };
        const box_count_labels = [_][]const u8{
            "2 boxes",
            "3 boxes",
            "4 boxes",
            "6 boxes",
            "8 boxes",
            "12 boxes",
            "16 boxes",
        };

        /// How far short of its arrival the track holds a chord awaited, following the player (`advanceProgression`): a
        /// millionth of a beat - so the chord is still the one on its way, drawn at its button, not yet the one to
        /// play.
        const hold_beats: f64 = 1e-6;

        /// How fast the chord the track waits for pulses, and how much it grows (`waitingScale`): three times a
        /// second - quicker than the beat, so that it reads as a call to play it rather than as the music's pulse - up
        /// to a fifth larger.
        const waiting_pulses_per_second: f32 = 3;
        const waiting_pulse_growth: f32 = 0.2;

        /// The playhead's width, in pixels (`drawProgressionEditor`).
        const playhead_width: f32 = 2;
    };

    /// The guitar chords: the tuning, the frets searched and the charts (`guitarChordOf`, `drawGuitarChord`).
    const guitar = struct {
        /// The guitar's six strings in standard tuning, the lowest first - E A D G B E - as MIDI keys, E2 to E4.
        const string_keys = [6]u8{ 40, 45, 50, 55, 59, 64 };

        /// The frets a chord's fingering spans at most: four, the hand's reach - a window from its lowest fret pressed.
        const window_frets: u8 = 4;

        /// The highest fret a fingering's window starts at: the 12th, an octave up the neck.
        const highest_window: u8 = 12;

        /// How much larger a chart's own notes are drawn than a plain dot: 30%, whole, even where they overlap.
        const chart_note_scale: f32 = 1.3;
    };

    /// The dots moving along the lines between pitch neighbours in the left hand's column (`drawColumnStar`).
    const column_dots = struct {
        /// The dots' spacing in the left hand's column, in the chooser's size units: the chooser's and the key's
        /// window's steps in pitch, at the size of their buttons.
        const spacing_units: f32 = 0.5;

        /// How many times a second the dots of a line between pitch neighbours move on by one dot's spacing.
        const dots_per_second: f32 = 3;

        /// How far toward the background a column star's dots are drawn while neither of their notes sounds: 20%.
        const resting_dimming: f32 = 0.2;
    };

    /// What sounds: its figure's turning and the band naming its function (`drawChordCurve`).
    const sounding = struct {
        /// How fast a three-note curve turns, in turns a second: slow enough to follow its shape as it turns.
        const curve_turns_per_second: f32 = 0.08;

        /// The sounding box's bottom band, where the function's name is written under the figure, as a share of its
        /// height: 20%.
        const function_name_band_share: f32 = 0.2;
    };

    /// How many of each the state and the drawing have room for.
    const limits = struct {
        /// The room for one progression's label in the options' list: its name, its numbers and its chords' names in
        /// the key.
        const progression_label_capacity: usize = 96;

        /// The room one mode's label takes in the header's list (`writeModeLabels`): a line of its name and
        /// alterations, and a line of seven chord names of at most four bytes each - a letter, an accidental and a
        /// degree sign of two.
        const mode_label_capacity: usize = 96;

        /// The most boxes the progression editor holds (`State.progression_boxes`): the most it shows.
        const progression_box_most: usize = progression.box_counts[progression.box_counts.len - 1];

        /// The most pointers held at once: the ten touches the engine tracks, and the mouse.
        const most_pointers: usize = 11;

        /// The most notes waiting at once: a chord's third and fifth for every pointer, and two over.
        const most_pending_holds: usize = 2 * most_pointers + 2;

        /// How many columns the first line of a mode's label spans: its name at the left, its alterations at the
        /// right - the font is monospaced, so the alterations line up down the list.
        const mode_label_columns: usize = 28;

        /// The most borrowed chords offered at once (`offeredBorrowedChords`).
        const most_offered_borrowed_chords: usize = 4;

        /// The most points a curve is drawn through: 48 for each swing of its fastest note, and the fastest of any
        /// notes of the scale `curveNotes` can pick swings 27 times - E, F and D stacked from E, 15 : 16 : 27.
        const most_curve_points: usize = 48 * 27 + 1;

        /// The most keys the keyboard has with a degree: nine white keys and six black ones.
        const most_outlined_keys: usize = 15;
    };
};

// ---- The scale ----

/// A degree's color, whole while it sounds and dimmed while it does not.
fn colorOfDegree(degree: u8, is_lit: bool) Color {
    const whole_color: Color = params.colors.degrees[degree - 1];
    return if (is_lit) whole_color else whole_color.lerp(params.colors.background, params.dimming.resting);
}

/// The degrees of a scale, 1 (its tonic) to 7, for walking through them.
const all_degrees = [7]u8{ 1, 2, 3, 4, 5, 6, 7 };

/// The degree `steps` scale steps above `degree`, within one octave: 6 and 2 steps up is 1.
fn degreeAbove(degree: u8, steps: u8) u8 {
    return (degree - 1 + steps) % 7 + 1;
}

/// The natural notes' pitch classes, C to B: C 0, D 2, E 4, F 5, G 7, A 9, B 11 - the white keys of a piano.
const natural_semitones = [7]u8{ 0, 2, 4, 5, 7, 9, 11 };

/// A note's name by its letter and its accidental: double flat, flat, natural, sharp or double sharp - two semitones
/// below the natural note to two above it. And its solfege syllable, fixed to the letter as French names notes - do
/// is always C - with the same accidental: re# is D sharp. A natural tonic's scales need no double accidental; a few
/// on a sharp tonic do - G# Ionian's seventh is F##.
const spelled_note_names = [7][5][]const u8{
    .{ "Cbb", "Cb", "C", "C#", "C##" },
    .{ "Dbb", "Db", "D", "D#", "D##" },
    .{ "Ebb", "Eb", "E", "E#", "E##" },
    .{ "Fbb", "Fb", "F", "F#", "F##" },
    .{ "Gbb", "Gb", "G", "G#", "G##" },
    .{ "Abb", "Ab", "A", "A#", "A##" },
    .{ "Bbb", "Bb", "B", "B#", "B##" },
};
/// The solfege syllables, by letter and accidental, as `spelled_note_names` gives the letters' names.
const spelled_solfege_names = [7][5][]const u8{
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
const Mode = enum(u4) {
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
    fn label(mode: Mode) []const u8 {
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
    fn semitonesAboveTonic(mode: Mode) [7]u8 {
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
const ChordQuality = enum { major, minor, diminished, augmented };

/// The Roman numerals of the triads, by degree: upper case for a major triad, upper case with a plus for an augmented
/// one, lower case for a minor one, lower case with a degree sign for a diminished one.
const major_numerals = [7][]const u8{ "I", "II", "III", "IV", "V", "VI", "VII" };
/// The augmented triads' numerals: upper case with a plus.
const augmented_numerals = [7][]const u8{ "I+", "II+", "III+", "IV+", "V+", "VI+", "VII+" };
/// The minor triads' numerals: lower case.
const minor_numerals = [7][]const u8{ "i", "ii", "iii", "iv", "v", "vi", "vii" };
/// The diminished triads' numerals: lower case with a degree sign.
const diminished_numerals = [7][]const u8{
    "i\u{00b0}",
    "ii\u{00b0}",
    "iii\u{00b0}",
    "iv\u{00b0}",
    "v\u{00b0}",
    "vi\u{00b0}",
    "vii\u{00b0}",
};

/// A chord of the scale: the degree of its root and its quality.
const ScaleChord = struct {
    /// The degree the chord is built on, 1 to 7.
    root_degree: u8,
    /// Its quality, from its semitones: major, minor, diminished or augmented.
    quality: ChordQuality,

    /// The chord's three notes, as degrees: its root, the third above it, the fifth above it - each two scale steps
    /// above the one before, wrapping past 7 back to 1.
    fn degrees(chord: ScaleChord) [3]u8 {
        const root: u8 = chord.root_degree;
        return .{ root, degreeAbove(root, 2), degreeAbove(root, 4) };
    }

    /// Whether the chord is drawn on the minor side: inside the circle, as a circle - the chords whose third is minor.
    /// An augmented chord's is major: it sits with the major ones.
    fn isMinorSide(chord: ScaleChord) bool {
        return chord.quality == .minor or chord.quality == .diminished;
    }

    /// The chord's name: its root's degree as a Roman numeral, in the case and with the sign of its quality.
    fn numeral(chord: ScaleChord) []const u8 {
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
const Scale = struct {
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
    fn of(tonic_letter: u8, mode: Mode) Scale {
        return ofTonic(tonic_letter, 0, mode);
    }

    /// The scale on the tonic `tonic_letter` with `tonic_accidental` - 1 for a sharp - in `mode`. A triad's quality is
    /// read from its thirds: the semitones from its root up to its third, then to its fifth - four and seven a major
    /// triad, three and seven a minor one, three and six the diminished one.
    fn ofTonic(tonic_letter: u8, tonic_accidental: i8, mode: Mode) Scale {
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
    fn tonicPitchClass(scale: *const Scale) u8 {
        const tonic_semitone: i16 = @as(i16, natural_semitones[scale.tonic_letter]) + scale.tonic_accidental;
        return @intCast(@mod(tonic_semitone, 12));
    }

    /// The triads on the seven degrees whose semitones above the tonic are `semitones`.
    fn chordsOfSemitones(semitones: [7]u8) [7]ScaleChord {
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
    fn altered(scale: Scale, alterations: [7]i8) Scale {
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
    fn alterationsForChord(scale: *const Scale, chord: ScaleChord) [7]i8 {
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
    fn chordOf(scale: *const Scale, degree: u8) ScaleChord {
        return scale.chords[degree - 1];
    }

    /// The pitch class of `degree`, C as 0 to B as 11: the tonic's pitch class and the degree's semitones above it,
    /// round the octave.
    fn pitchClassOfDegree(scale: *const Scale, degree: u8) u4 {
        return @intCast((scale.tonicPitchClass() + scale.semitones[degree - 1]) % 12);
    }

    /// The degree at pitch class `pitch_class`, or null for the five the scale does not use.
    fn degreeOfPitchClass(scale: *const Scale, pitch_class: u4) ?u8 {
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
    const Spelling = struct {
        /// The letter, C as 0 to B as 6.
        letter: u8,
        /// The accidental, shifted by two: 0 a double flat to 4 a double sharp.
        accidental: u8,
    };

    /// How `degree` is spelled in `scale` (`Spelling`).
    fn spellingOf(scale: *const Scale, degree: u8) Spelling {
        const letter: u8 = (scale.tonic_letter + degree - 1) % 7;
        const pitch_class: u8 = scale.pitchClassOfDegree(degree);
        // -2 to +2 semitones from the natural note, shifted to 0 to 4.
        const accidental: u8 = (pitch_class + 12 + 2 - natural_semitones[letter]) % 12;
        return .{ .letter = letter, .accidental = accidental };
    }

    /// The name of `degree`'s note, spelled in the scale: F# in D major, Bb in F major.
    fn noteName(scale: *const Scale, degree: u8) []const u8 {
        const spelling: Spelling = scale.spellingOf(degree);
        return spelled_note_names[spelling.letter][spelling.accidental];
    }

    /// The solfege syllable of `degree`'s note, fixed to its letter, with its accidental.
    fn solfegeName(scale: *const Scale, degree: u8) []const u8 {
        const spelling: Spelling = scale.spellingOf(degree);
        return spelled_solfege_names[spelling.letter][spelling.accidental];
    }

    /// The MIDI key of `degree`: the tonic in the octave of middle C (MIDI key 60 to 71), the degree's semitones above
    /// it. A Shepard note ignores the octave - only the key's pitch class chooses its partials - but the keys stay
    /// those of one real octave, so that another instrument plays them as they are.
    fn midiKeyOfDegree(scale: *const Scale, degree: u8) u8 {
        const tonic_key: u8 = 60 + scale.tonicPitchClass();
        return tonic_key + scale.semitones[degree - 1];
    }

    /// Whether `chord` is one of the scale's two main chords, drawn larger: the tonic's own triad, and its relative -
    /// the triad that shares two of its notes from a third below: vi for a major tonic, III for a minor or diminished
    /// one.
    fn isMainChord(scale: *const Scale, chord: ScaleChord) bool {
        const tonic_chord: ScaleChord = scale.chordOf(1);
        const relative_degree: u8 = if (tonic_chord.quality == .major) 6 else 3;
        return chord.root_degree == 1 or chord.root_degree == relative_degree;
    }
};

/// The scale the app starts in: C major.
const c_major: Scale = .of(0, .ionian);

/// Where a degree sits on the circle of thirds, counted clockwise from the top: 0 for 1, then 1 for 3, 2 for 5, 3 for
/// 7, 4 for 2, 5 for 4, 6 for 6. Walking the circle adds two degrees a place, so the place of a degree undoes that
/// walk: multiplying by 4 undoes multiplying by 2, since 2 x 4 = 8, which is 1 more than a whole circle of 7.
fn circlePlaceOfDegree(degree: u8) u8 {
    return (4 * (degree - 1)) % 7;
}

/// The degree at a place of the circle of thirds, the walk `circlePlaceOfDegree` undoes: two degrees a place from 1.
fn degreeAtPlace(circle_place: u8) u8 {
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

// ---- The pedals ----

/// A pedal's state, inside its voice (`z.mixer.generator_state_capacity`, 64 bytes, at most - this is 64): where its
/// lowest partial is in its cycle, in turns, and how far it moves a frame, kept and wrapped in 64 bits as the
/// instrument's are; the level its attack has reached; and each partial's amplitude, the lowest's first.
const PedalState = struct {
    /// Where the lowest partial is in its cycle, in turns, wrapped to 0 to 1.
    phase_turns: f64,
    /// How far the lowest partial moves a frame, in turns: its frequency over the sample rate.
    phase_step_turns: f64,
    /// The level the attack has reached, 0 to 1.
    level: f32,
    /// Each partial's amplitude under the bell, the lowest's first.
    partial_amplitudes: [params.pedal.partial_count]f32,
};

/// A pedal's state for `pitch_class`, as the Shepard instrument works out a note's: the pitch class in middle C's
/// octave, moved whole octaves down to the reach's lower end - between five and four octaves below the bell's centre -
/// for the lowest partial; then each partial an octave above the last, its amplitude the bell's height there - the
/// Gaussian `exp(-d^2 / 2)` of its distance from the centre in widths - over the bell's area, so that the amplitudes
/// add to 1 whatever the pitch class.
fn pedalStateOf(pitch_class: u4) PedalState {
    const bell_area: f64 = params.pedal.bell_width_octaves * sqrt(@as(f64, 2 * pi));
    const semitones_from_a440: f64 = float(@as(u8, pitch_class)) + 60 - 69;
    const key_frequency: f64 = 440 * exp2(semitones_from_a440 / 12);
    const octaves_from_centre: f64 = log2(key_frequency / params.pedal.bell_centre_hz);
    const octaves_above_reach_start: f64 = octaves_from_centre + params.pedal.reach_octaves;
    const lowest_octaves_from_centre: f64 =
        octaves_above_reach_start - @floor(octaves_above_reach_start) - params.pedal.reach_octaves;
    const lowest_frequency: f64 = params.pedal.bell_centre_hz * exp2(lowest_octaves_from_centre);
    var state: PedalState = .{
        .phase_turns = 0,
        .phase_step_turns = lowest_frequency / float(z.mixer.sample_rate),
        .level = 0,
        .partial_amplitudes = undefined,
    };
    for (&state.partial_amplitudes, 0..) |*partial_amplitude, partial_index| {
        const partial_octaves_from_centre: f64 = lowest_octaves_from_centre + float(partial_index);
        const standard_deviations: f64 = partial_octaves_from_centre / params.pedal.bell_width_octaves;
        const bell_height: f64 = exp(-0.5 * standard_deviations * standard_deviations);
        partial_amplitude.* = @floatCast(bell_height / bell_area);
    }
    return state;
}

/// A pedal's frames: its partials summed, each an octave above the last, times the attack's level, the same in both
/// channels. One sine and one cosine a frame, for the lowest partial; each higher partial's from the one below by the
/// double-angle formulas - `sin 2a = 2 sin a cos a`, `cos 2a = cos^2 a - sin^2 a` - as the Shepard instrument's are.
/// It runs on the renderer's side, as every generator does: in the audio worklet on a page.
fn generatePedal(state_bytes: *anyopaque, frames: []f32, first_frame: u64) void {
    _ = first_frame;
    const state: *PedalState = @ptrCast(@alignCast(state_bytes));
    const attack_step: f32 = 1.0 / (params.pedal.attack_seconds * float(z.mixer.sample_rate));
    const frame_count: usize = frames.len / 2;
    for (0..frame_count) |frame_index| {
        const lowest_phase: f32 = @floatCast(state.phase_turns);
        var partial_sine: f32 = sinTurns(lowest_phase);
        var partial_cosine: f32 = cosTurns(lowest_phase);
        var sample: f32 = 0;
        for (state.partial_amplitudes) |amplitude| {
            sample += amplitude * partial_sine;
            const doubled_sine: f32 = 2 * partial_sine * partial_cosine;
            const doubled_cosine: f32 = partial_cosine * partial_cosine - partial_sine * partial_sine;
            partial_sine = doubled_sine;
            partial_cosine = doubled_cosine;
        }
        sample *= state.level;
        frames[frame_index * 2] = sample;
        frames[frame_index * 2 + 1] = sample;
        state.level = @min(1, state.level + attack_step);
        state.phase_turns += state.phase_step_turns;
        state.phase_turns -= @floor(state.phase_turns);
    }
}

/// A pedal: whether its checkbox is ticked, the voice playing it - `.none` while it is silent - and the pitch class
/// it plays.
const Pedal = struct {
    /// Its loudness, as its voice's volume: 0 silent - the voice ended.
    volume: f32 = params.defaults.pedal_volume,
    /// The voice playing it: `.none` while it is silent.
    voice: z.mixer.Voice = .none,
    /// The pitch class it plays, C as 0; null before it first sounds.
    pitch_class: ?u4 = null,
    /// The volume the voice playing was last given: a change of `volume` reaches it at the next frame.
    voice_volume: f32 = 0,

    /// Keeps the pedal playing `wanted_pitch_class` - or silent, for null. When it changes, the voice playing fades out
    /// (`stopVoice`, 5 ms) and a new one rises over its attack (`params.pedal.attack_seconds`). A pedal whose voice is
    /// not playing - the mixer had no slot free for it, or its voice was ended elsewhere - is started again, at the
    /// next frame that finds it so.
    fn keep(pedal: *Pedal, f: *z.Frame, wanted_pitch_class: ?u4) void {
        const is_voice_playing: bool = pedal.voice != .none and f.mixer.isPlaying(pedal.voice);
        const is_same_pitch_class: bool = wanted_pitch_class == pedal.pitch_class;
        const is_silence_wanted: bool = wanted_pitch_class == null;
        if (is_same_pitch_class and is_voice_playing) {
            // The volume followed as its slider moves: the mixer moves the voice's gains over its next block, without
            // a click.
            const has_volume_changed: bool = pedal.voice_volume != pedal.volume;
            if (has_volume_changed) {
                f.mixer.setVolume(pedal.voice, pedal.volume);
                pedal.voice_volume = pedal.volume;
            }
            return;
        }
        if (is_same_pitch_class and is_silence_wanted) {
            return;
        }
        if (is_voice_playing) {
            f.mixer.stopVoice(pedal.voice);
        }
        pedal.voice = .none;
        pedal.pitch_class = wanted_pitch_class;
        const pitch_class: u4 = wanted_pitch_class orelse return;
        const state: PedalState = pedalStateOf(pitch_class);
        const generator: z.mixer.Generator = .{ .generate = &generatePedal, .initial_state = asBytes(&state) };
        pedal.voice = f.mixer.play(.{ .generator = generator }, .{ .volume = pedal.volume });
        pedal.voice_volume = pedal.volume;
    }
};

// ---- Shapes and sizes ----

/// The shape a note or a chord is drawn as: a square on the major side of the scale - the chords I, IV and V, and the
/// notes 1, 4 and 5, whose own chords they are - and a circle on the minor side: ii, iii, vi and vii, and the notes 2,
/// 3, 6 and 7.
const Shape = enum { square, circle };

/// A chord's shape: a square for a major chord, a circle for the minor side's.
fn shapeOfChord(chord: ScaleChord) Shape {
    return if (chord.isMinorSide()) .circle else .square;
}

/// A note's shape in `scale`: its own chord's - the chord built on it - so that in the major scale 1, 4 and 5 are
/// squares like I, IV and V.
fn shapeOfDegree(scale: *const Scale, degree: u8) Shape {
    return shapeOfChord(scale.chordOf(degree));
}

/// A shape where it stands: its centre and its shape.
const PlacedShape = struct {
    /// Where its centre is.
    centre: Vec2,
    /// Square or circle.
    shape: Shape,
};

/// A shape and its size, in size units: the half-side of a square or the radius of a circle. Here the notes are the
/// large targets - the right hand's three fingers rest on them - at two units, and the chords the small ones, at one:
/// the scale's two main chords (`Scale.isMainChord`: I and vi in the major scale) a quarter larger, and the diminished
/// one, the least used, a quarter smaller.
const ShapedSize = struct {
    /// Square or circle.
    shape: Shape,
    /// Its half-side or radius, in size units.
    size_in_units: f32,
};

/// A chord a progression borrows from outside the scale: the step it is at, and its quality there.
const ProgressionBorrowing = struct {
    /// The step of the progression it is at, from 0.
    step: u8,
    /// Its quality there, other than the scale's chord's on that degree.
    quality: ChordQuality,
};

/// The key of a song's recording, for playing along with it in tune: the key as musicians name it, and the scale to
/// choose for the progression's numbers to give the recording's chords. The numbers count from the relative major, as
/// Nashville numbers do - Hotel California's 6-3-5-2 is Bm-F#-A-E counted from D - so a minor song's scale is its
/// relative major's tonic, Ionian, not its own tonic in Aeolian; a major song's is its own tonic.
const SongKey = struct {
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
const Progression = struct {
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
fn progressionChord(
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
const progressions = [_]Progression{
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
const mode_count: usize = std.enums.values(Mode).len;

/// A chord's name as its letters show it: its root's spelling in the key, then "m" for a minor triad, a degree sign
/// for the diminished one, nothing for a major one - C, Dm, and B with the degree sign. The two parts are copied one
/// after the other into `buffer`: a spelling is a letter and at most two accidentals, the suffix at most two bytes, so
/// eight bytes always hold the name.
fn chordLetterName(buffer: *[8]u8, scale: *const Scale, chord: ScaleChord) []const u8 {
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

/// A chord's size in units (`ShapedSize`) in `scale`: its main chords larger, its diminished one smaller, the others
/// one unit.
fn chordSizeInUnits(scale: *const Scale, chord: ScaleChord) f32 {
    if (scale.isMainChord(chord)) {
        return params.sizes.main_chord_size_in_units;
    }
    return if (chord.quality == .diminished)
        params.sizes.diminished_chord_size_in_units
    else
        params.sizes.chord_size_in_units;
}

/// A chord's shape and size together, as `largestUnitApart` takes them.
fn shapedSizeOfChord(scale: *const Scale, chord: ScaleChord) ShapedSize {
    return .{ .shape = shapeOfChord(chord), .size_in_units = chordSizeInUnits(scale, chord) };
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

/// The largest size unit at which two chords' triplets (`StarLayout.chordTripletShapes`), each shape at its chord's
/// size in units, are at least `clearance` units apart: the smallest limit any two of their shapes set
/// (`largestUnitApart`).
fn largestUnitApartTriplets(
    first: [3]PlacedShape,
    first_size_in_units: f32,
    second: [3]PlacedShape,
    second_size_in_units: f32,
    clearance: f32,
) f32 {
    var size_unit: f32 = inf(f32);
    for (first) |first_shape| {
        const first_shaped: ShapedSize = .{ .shape = first_shape.shape, .size_in_units = first_size_in_units };
        for (second) |second_shape| {
            const second_shaped: ShapedSize = .{ .shape = second_shape.shape, .size_in_units = second_size_in_units };
            const offset: Vec2 = second_shape.centre - first_shape.centre;
            size_unit = @min(size_unit, largestUnitApart(offset, first_shaped, second_shaped, clearance));
        }
    }
    return size_unit;
}

// ---- The chooser's curve ----

/// The pull of the star's curve toward its bottom line at `offset_from_bottom` turns from its bottom, either side: from
/// 1 - onto the line - to 0, not at all. Within a seventh of a turn of the bottom - the places of 1, 3 and 5 -
/// everything is on the line; beyond, the pull fades out by two sevenths, smoothly (a smoothstep, whose slope is 0 at
/// both ends, so that the curve bends into the line without a corner). The same on both sides: the place after 5, the
/// 7, stands on the curve as the place before 1 does, clear of the row - not pulled down beside it.
fn warpAt(offset_from_bottom: f32) f32 {
    const seventh: f32 = 1.0 / 7.0;
    const turns_from_bottom: f32 = @abs(offset_from_bottom);
    if (turns_from_bottom <= seventh) {
        return 1;
    }
    return 1 - smoothstep(seventh, 2 * seventh, turns_from_bottom);
}

/// The star's turn with nothing chosen: the place of 3 at the bottom of the screen (half a turn from the top), so that
/// 1, 3 and 5 lie along the bottom - 1 to the left of 3, 5 to its right, the places running counterclockwise - under
/// the right hand's index, middle and ring fingers. Place `k` is at `turn - k / 7`; place 1 at half a turn needs a turn
/// of a half and a seventh.
const three_at_bottom_turns: f32 = 0.5 + 1.0 / 7.0;

/// A bulge to the right on the chooser's curve (`chooserCurveDirection`): the place, at the star's rest, where it is
/// whole, and how far it moves the chord there.
const RightBulge = struct {
    /// The place, 0 to 6, counted as the star's places are, from its rest (`three_at_bottom_turns`).
    place: f32,
    /// How far right it moves the chord there, as a share of the curve's x radius.
    amount: f32,
};

/// The places whose chords the chooser moves to the right: 6's, at the left, 0.14 of the curve's x radius - some 7%
/// of its width - and 2's, at the top right, 0.38. On the plain curve these two lie far out to the side, apart from
/// the chords they share notes with; moved in toward the right, each stands closer over them, and the shape joining
/// the chords of the notes sounding (`drawChooserPolygon`) is fuller.
const right_bulges = [2]RightBulge{
    .{ .place = 6, .amount = 0.14 },
    .{ .place = 4, .amount = 0.38 },
};

/// How far right the point at `angle_turns` moves, as a share of the curve's x radius: each bulge's amount times how
/// much of it the point takes - at its place as the star rests, all of it; a place away, none; a raised cosine between,
/// `(1 + cos(pi d / w)) / 2` for a distance `d` within the width `w`, a seventh of a turn. Like the warp, it depends on
/// the angle alone.
fn rightBulgeOffset(angle_turns: f32) f32 {
    const bulge_width_turns: f32 = 1.0 / 7.0;
    var offset: f32 = 0;
    for (right_bulges) |bulge| {
        const bulge_angle_turns: f32 = three_at_bottom_turns - bulge.place / 7;
        const turns_apart: f32 = angle_turns - bulge_angle_turns;
        const wrapped_turns_apart: f32 = turns_apart - @round(turns_apart);
        const distance_turns: f32 = @abs(wrapped_turns_apart);
        if (distance_turns < bulge_width_turns) {
            const weight: f32 = 0.5 * (1 + cosTurns(0.5 * distance_turns / bulge_width_turns));
            offset += bulge.amount * weight;
        }
    }
    return offset;
}

/// The direction from the chooser's centre of the point at `angle_turns` on its curve, as a fraction of the radii: the
/// ellipse's direction, warped near the bottom (`warpAt`), and moved right where the bulges are (`rightBulgeOffset`).
/// The chooser's chords sit on it at the star's places, near enough the star's own curve (`StarCurve`) for the hand
/// to find them where it expects.
///
/// On a plain ellipse the three places along the bottom, where 1, 3 and 5 sit under the right hand, lie on an arc: the
/// middle one lowest. The fingers rest in a row, so the bottom is flattened:
///
///         plain ellipse                      warped
///          .       .                          .       .
///       1     5                             .           .
///          3                               1     3     5         the row
///
/// The pull acts on the direction's y only, so the row keeps its spacing across - evenly spaced, since an ellipse's x
/// at a seventh of a turn either side of the bottom is the same distance out - and the warp depends on the angle, not
/// on which note is there: as the star turns, each note slides into its place and out.
fn chooserCurveDirection(angle_turns: f32) Vec2 {
    const direction: Vec2 = .{ sinTurns(angle_turns), -cosTurns(angle_turns) };
    const turns_past_bottom: f32 = angle_turns - 0.5;
    const offset_from_bottom: f32 = turns_past_bottom - @round(turns_past_bottom);
    const pull: f32 = warpAt(offset_from_bottom);
    const bulge: f32 = rightBulgeOffset(angle_turns);
    return .{ direction[0] + bulge, direction[1] + pull * (1 - direction[1]) };
}

// ---- The star's curve ----

/// The length of the arc of an ellipse of width radius 1 and height radius `height_share`, between the angles `from`
/// and `to` from its bottom, by Simpson's rule over `intervals` intervals (an even number): the point at angle `t` is
/// `(sin t, height_share cos t)`, moving at `sqrt(cos^2 t + height_share^2 sin^2 t)` as `t` grows.
fn ellipseArcLength(height_share: f32, from: f32, to: f32, intervals: usize) f32 {
    const spacing: f32 = (to - from) / float(intervals);
    var weighted_sum: f32 = 0;
    for (0..intervals + 1) |point_index| {
        const angle: f32 = from + float(point_index) * spacing;
        const across: f32 = @cos(angle);
        const upright: f32 = height_share * @sin(angle);
        const speed: f32 = sqrt(across * across + upright * upright);
        const is_end: bool = point_index == 0 or point_index == intervals;
        const weight: f32 = if (is_end) 1 else if (point_index % 2 == 1) 4 else 2;
        weighted_sum += weight * speed;
    }
    return weighted_sum * spacing / 3;
}

/// The star's curve: an ellipse with its bottom cut off by a straight line, the notes spaced equally along it.
///
///                 .  - ~ -  .
///             .                 .
///          4                       2          the arc: four notes, five equal steps along it
///        .                           .
///       6                             7
///        .                           .
///          1 ---------- 3 ---------- 5        the line: 1, 3 and 5, a step apart
///
/// The line is where 1, 3 and 5 stand in a row under the right hand's fingers; the arc carries the other four. Its
/// height is chosen so that the arc from 5 round to 1 is exactly five times half the line: then the whole curve is
/// seven equal steps long, and seven notes a seventh of its length apart stand one step from each other all round -
/// along the line, from 1 to 3 and from 3 to 5, and along the arc. A place on the star is a fraction of the curve's
/// length, clockwise from its top, as a turn's fraction is of a turn: place `k` is `k / 7` of the length round from
/// the star's rotation, and the star turns by sliding every note along the curve, onto the line and off it.
///
/// Its shape depends only on the ellipse's proportions, its height beside its width; it is kept in units of the
/// ellipse's width radius, and scaled by it to the screen (`StarLayout.pointAtFractionalPlace`). Its points are
/// measured from its own middle - halfway between the arc's top and the line, above the ellipse's centre - about which
/// the chords' rings are scaled copies of it: the line as far from that middle as the top, a ring outside clears the
/// row by as much as it clears the top.
const StarCurve = struct {
    /// The ellipse's height radius beside its width radius.
    height_share: f32,
    /// The angle at which the line cuts the ellipse, in radians from its bottom: the line's ends are the ellipse's
    /// points `cut_angle` either side of the bottom.
    cut_angle: f32,
    /// The step between neighbouring notes along the curve: half the line's length, `sin(cut_angle)` in units of the
    /// width radius.
    step: f32,
    /// The curve's middle below the ellipse's centre, in units of the width radius - negative, as it lies above it:
    /// halfway between the arc's top, at `-height_share`, and the line, at `height_share cos(cut_angle)`.
    middle_height: f32,
    /// The arc's length from the line's end up to each of `arc_sample_count` angles, evenly spaced from the cut to
    /// the ellipse's top, in units of the width radius: the table a length along the arc is turned back into an
    /// angle by (`angleAtArcLength`).
    arc_lengths: [arc_sample_count]f32,

    /// The arc's lengths kept: 65 angles from the cut to the top, enough that a length turned back into an angle is
    /// within a hair of the true one.
    const arc_sample_count: usize = 65;

    /// The intervals the arc's length is measured in by Simpson's rule, while the cut is sought.
    const length_intervals: usize = 64;

    /// The halvings that find the cut: 40, far finer than a pixel.
    const cut_halvings: usize = 40;

    /// The curve for an ellipse of `radii`. The cut is sought by halving: the arc above the line shortens and the
    /// line lengthens as the cut rises, so the arc's length less five half-lines falls through 0 once, between a cut
    /// at the bottom and one near the top.
    fn ofRadii(radii: Vec2) StarCurve {
        const height_share: f32 = radii[1] / radii[0];
        var lowest_cut: f32 = 0.01;
        var highest_cut: f32 = pi - 0.05;
        for (0..cut_halvings) |_| {
            const trial_cut: f32 = (lowest_cut + highest_cut) / 2;
            const arc_length: f32 = 2 * ellipseArcLength(height_share, trial_cut, pi, length_intervals);
            const steps_length: f32 = 5 * @sin(trial_cut);
            if (arc_length > steps_length) {
                lowest_cut = trial_cut;
            } else {
                highest_cut = trial_cut;
            }
        }
        const cut_angle: f32 = (lowest_cut + highest_cut) / 2;
        var arc_lengths: [arc_sample_count]f32 = undefined;
        arc_lengths[0] = 0;
        const sample_spacing: f32 = (pi - cut_angle) / float(arc_sample_count - 1);
        for (1..arc_sample_count) |sample_index| {
            const sample_start: f32 = cut_angle + float(sample_index - 1) * sample_spacing;
            const sample_length: f32 = ellipseArcLength(height_share, sample_start, sample_start + sample_spacing, 2);
            arc_lengths[sample_index] = arc_lengths[sample_index - 1] + sample_length;
        }
        return .{
            .height_share = height_share,
            .cut_angle = cut_angle,
            .step = @sin(cut_angle),
            .middle_height = 0.5 * height_share * (@cos(cut_angle) - 1),
            .arc_lengths = arc_lengths,
        };
    }

    /// The angle up the arc at which its length from the line's end is `arc_length`: the table's two samples either
    /// side of it, and the angle between them in proportion.
    fn angleAtArcLength(curve: *const StarCurve, arc_length: f32) f32 {
        const sample_spacing: f32 = (pi - curve.cut_angle) / float(arc_sample_count - 1);
        var upper_index: usize = 1;
        while (upper_index < arc_sample_count - 1 and curve.arc_lengths[upper_index] < arc_length) {
            upper_index += 1;
        }
        const lower_length: f32 = curve.arc_lengths[upper_index - 1];
        const upper_length: f32 = curve.arc_lengths[upper_index];
        const share_between: f32 = clamp((arc_length - lower_length) / (upper_length - lower_length), 0, 1);
        return curve.cut_angle + (float(upper_index - 1) + share_between) * sample_spacing;
    }

    /// The point `arc_turns` of the curve's length round from its top, clockwise, from the curve's middle in units of
    /// the width radius - the screen's y growing downward. Measured from the line's middle, at the bottom, half a
    /// turn round: within a step either side, on the line; further, up the arc on that side.
    fn unitPointAt(curve: *const StarCurve, arc_turns: f32) Vec2 {
        const point_from_ellipse_centre: Vec2 = curve.unitPointFromEllipseCentre(arc_turns);
        return point_from_ellipse_centre - Vec2{ 0, curve.middle_height };
    }

    /// The same point from the ellipse's centre (`unitPointAt`).
    fn unitPointFromEllipseCentre(curve: *const StarCurve, arc_turns: f32) Vec2 {
        const turns_past_bottom: f32 = arc_turns - 0.5;
        const turns_from_bottom: f32 = turns_past_bottom - @round(turns_past_bottom);
        // Before the bottom, clockwise, is the right side; after it, the left.
        const along_from_bottom: f32 = turns_from_bottom * 7 * curve.step;
        const side: f32 = if (along_from_bottom < 0) 1 else -1;
        const distance_from_bottom: f32 = @abs(along_from_bottom);
        const line_height: f32 = curve.height_share * @cos(curve.cut_angle);
        if (distance_from_bottom <= curve.step) {
            return .{ side * distance_from_bottom, line_height };
        }
        const angle: f32 = curve.angleAtArcLength(distance_from_bottom - curve.step);
        return .{ side * @sin(angle), curve.height_share * @cos(angle) };
    }
};

// ---- The star's layout ----

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
/// Since it tries dozens of layouts, the app keeps the one chosen until the window's size changes (`windowLayoutOf`).
const StarLayout = struct {
    /// The curve's middle, on the screen: the rings are scaled about it.
    centre: Vec2,
    /// The half-width and the half-height of the ellipse the notes sit on, cut off at its bottom (`StarCurve`).
    note_ellipse_radii: Vec2,
    /// The curve for those radii: kept with them, made again wherever they change (`setRadii`).
    curve: StarCurve,
    /// Where place 0 - the degree 1 - sits, in turns clockwise from the top: 0, or a quarter turn.
    rotation_turns: f32,
    /// The chords' ellipses, as multiples of the notes': the major chords' outside, the others' inside.
    outer_chord_scale: f32,
    /// The ring inside the curve, as a multiple of the notes' curve.
    inner_chord_scale: f32,
    /// A note's half-size, in units of this: the half-side of its square, or its circle's radius.
    size_unit: f32,
    /// The place, on the unturned circle, of the root of the chord whose notes are the heroes
    /// (`params.sizes.hero_note_size_in_units`): the chosen chord's. Its notes are at that place and the two after it.
    hero_root_place: u8,
    /// The scale the star shows: its chords' qualities decide their sides, shapes and sizes, and so the layout.
    scale: Scale,
    /// Which chords are outside: 0 for the major ones, as with I chosen, 1 for the minor side's - ii, iii, vi and vii -
    /// as with one of them chosen, so that the chosen chord is always outside, at the bottom; between, while the two
    /// trade places, each chord part of the way from its ellipse to the other's (`chordCentre`).
    minor_side_outside_fraction: f32,

    /// The sizes of the chords' rings the layout tries (`ofRoom`), as multiples of the notes' curve, keeping the one
    /// that lets everything be largest: outside, 1.8 to 2.45 - the chords outside well clear of the notes, their fans
    /// long, the notes' curve some two thirds of the room.
    const outer_chord_scales = [_]f32{ 1.8, 1.95, 2.1, 2.25, 2.45 };
    /// Inside, 0.4 to 0.7.
    const inner_chord_scales = [_]f32{ 0.4, 0.5, 0.6, 0.7 };
    /// The height of the line of text at the top, and the gap kept along the window's edges.
    const header_height: f32 = 34;
    /// The gap kept along the window's edges, in pixels.
    const margin: f32 = 6;
    /// The corner a page's fullscreen button covers: the button's 52 pixels and its 10 from the window's edges.
    const fullscreen_button_reach: f32 = 62;
    /// The rounds `settled` takes to settle the places and the sizes together.
    const settling_rounds: usize = 5;

    /// The star's layout in `whole_room`, its part of the window, for `scale`.
    fn ofRoom(whole_room: z.Rectangle, button_corner: Vec2, scale: Scale) StarLayout {
        // The fullscreen button's corner left free along the right edge, or along the bottom: the room cut short a
        // margin before the button's left side, or before its top, wherever the room reaches past them.
        var room_beside_button: z.Rectangle = whole_room;
        room_beside_button.width = @min(whole_room.width, button_corner[0] - margin - whole_room.x);
        var room_above_button: z.Rectangle = whole_room;
        room_above_button.height = @min(whole_room.height, button_corner[1] - margin - whole_room.y);
        const rooms = [2]z.Rectangle{ room_beside_button, room_above_button };
        const rotations = [1]f32{three_at_bottom_turns};
        var best: ?StarLayout = null;
        for (rooms) |room| {
            for (rotations) |rotation_turns| {
                for (outer_chord_scales) |outer_chord_scale| {
                    for (inner_chord_scales) |inner_chord_scale| {
                        const scales: ChordScales = .{ .outer = outer_chord_scale, .inner = inner_chord_scale };
                        const candidate: StarLayout = settled(room, rotation_turns, scales, scale);
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
        /// The ring outside the curve, as a multiple of the notes'.
        outer: f32,
        /// The ring inside it.
        inner: f32,
    };

    /// The layout with the figure turned by `rotation_turns` and its chords' ellipses at `scales`, its places and its
    /// sizes settled together in `room`.
    fn settled(
        room: z.Rectangle,
        rotation_turns: f32,
        scales: ChordScales,
        scale: Scale,
    ) StarLayout {
        // First guess: no size at all, and the figure as large as the room.
        var star: StarLayout = .{
            .centre = .{ room.x + room.width / 2, room.y + room.height / 2 },
            .note_ellipse_radii = .{ room.width, room.height },
            .curve = .ofRadii(.{ room.width, room.height }),
            .rotation_turns = rotation_turns,
            .outer_chord_scale = scales.outer,
            .inner_chord_scale = scales.inner,
            .size_unit = 0,
            .hero_root_place = 0,
            .scale = scale,
            .minor_side_outside_fraction = 0,
        };
        star.fitToRoom(room);
        for (0..settling_rounds) |_| {
            star.size_unit = star.largestSizeUnitAtEveryTurn();
            star.fitToRoom(room);
        }
        return star;
    }

    /// The layout with the figure turned on by `turns`: every note and chord `turns` further round its ellipse.
    fn turnedBy(star: StarLayout, turns: f32) StarLayout {
        var turned: StarLayout = star;
        turned.rotation_turns += turns;
        return turned;
    }

    /// The figure's seven turns, one for each chord a left finger may choose: the turn that brings the chord's root to
    /// place 0 (`starTurnForChord`). Each is a whole number of sevenths of a turn back.
    const turn_count: usize = 7;

    /// The turn, in turns, of the chord whose root is `step` places round: `step` sevenths.
    fn turnOfStep(step: usize) f32 {
        return float(step) / 7;
    }

    /// The layout turned to the chord whose root is at place `step`, that chord's notes the heroes: as it is drawn once
    /// that chord is chosen.
    fn turnedToChordStep(star: StarLayout, step: usize) StarLayout {
        var turned: StarLayout = star.turnedBy(turnOfStep(step));
        turned.hero_root_place = @intCast(step);
        const chosen_chord: ScaleChord = star.scale.chordOf(degreeAtPlace(@intCast(step)));
        turned.minor_side_outside_fraction = if (chosen_chord.isMinorSide()) 1 else 0;
        return turned;
    }

    /// The largest size unit at which no two targets come too near, at every one of the figure's seven turns: the
    /// ellipse's radii differ, so the gaps between neighbours change as the figure turns, and the size must suit all.
    fn largestSizeUnitAtEveryTurn(star: StarLayout) f32 {
        var size_unit: f32 = inf(f32);
        for (0..turn_count) |step| {
            size_unit = @min(size_unit, star.turnedToChordStep(step).largestSizeUnit());
        }
        return size_unit;
    }

    /// Whether a degree's note is one of the heroes: one of the three places from the heroes' root on.
    fn isHeroNote(star: StarLayout, degree: u8) bool {
        const places_from_hero_root: u8 = (circlePlaceOfDegree(degree) + 7 - star.hero_root_place) % 7;
        return places_from_hero_root < 3;
    }

    /// A note's size in units: a hero's, or a plain note's - the tonic's 30% larger (`params.sizes.tonic_size_share`).
    fn noteSizeInUnits(star: StarLayout, degree: u8) f32 {
        const size_in_units: f32 = if (star.isHeroNote(degree))
            params.sizes.hero_note_size_in_units
        else
            params.sizes.note_size_in_units;
        return if (degree == 1) params.sizes.tonic_size_share * size_in_units else size_in_units;
    }

    /// A note's half-size in pixels, as drawn: the half-side of its square, or its circle's radius - its size in units
    /// times the unit, and a little less (`params.sizes.note_drawn_share`, `params.sizes.tonic_drawn_share`): the
    /// layout keeps room for its full size (`largestSizeUnit` reads `noteSizeInUnits`), so that the gaps between the
    /// notes are wider than the layout's clearances.
    fn noteHalfSize(star: StarLayout, degree: u8) f32 {
        const drawn_share: f32 = if (degree == 1) params.sizes.tonic_drawn_share else params.sizes.note_drawn_share;
        return drawn_share * star.noteSizeInUnits(degree) * star.size_unit;
    }

    /// A note's half-size were it no hero: what the drawing's details are measured in.
    fn plainNoteHalfSize(star: StarLayout) f32 {
        return params.sizes.note_size_in_units * star.size_unit;
    }

    /// A chord's half-size in pixels.
    fn chordHalfSize(star: StarLayout, chord: ScaleChord) f32 {
        return chordSizeInUnits(&star.scale, chord) * star.size_unit;
    }

    /// The three shapes of a chord's triplet (`ChordTriplet`), all the chord's size, front first: its own shape - a
    /// square for a major chord, a circle for the others - at the left; its third's note's shape at the chord's centre;
    /// its fifth's at the right, each `params.sizes.chord_triplet_step_share` of a shape's width from the one before
    /// it.
    fn chordTripletShapes(star: StarLayout, chord: ScaleChord) [3]PlacedShape {
        const centre: Vec2 = star.chordCentre(chord);
        const step: Vec2 = .{ params.sizes.chord_triplet_step_share * 2 * star.chordHalfSize(chord), 0 };
        const degrees: [3]u8 = chord.degrees();
        return .{
            .{ .centre = centre - step, .shape = shapeOfChord(chord) },
            .{ .centre = centre, .shape = shapeOfDegree(&star.scale, degrees[1]) },
            .{ .centre = centre + step, .shape = shapeOfDegree(&star.scale, degrees[2]) },
        };
    }

    /// The fourteen targets: seven notes, then seven chords; and the places a fit must hold - each target at each of
    /// the figure's seven turns.
    const target_count: usize = 14;
    /// Every target at every turn: what a fit must hold in the room.
    const fit_point_count: usize = turn_count * target_count;

    /// Stretches the figure to fill `room`, at the sizes it has now and at every one of its turns: on each axis, the
    /// ellipses' radius and the figure's centre such that, whichever chord is chosen, the figure's outermost note or
    /// chord touches the room's edges at most (`fitAxis`).
    fn fitToRoom(star: *StarLayout, room: z.Rectangle) void {
        var place_offsets: [fit_point_count]Vec2 = undefined;
        var half_sizes: [fit_point_count]f32 = undefined;
        for (0..turn_count) |step| {
            const turned: StarLayout = star.turnedToChordStep(step);
            const first_point: usize = step * target_count;
            for (all_degrees, 0..) |degree, note_index| {
                place_offsets[first_point + note_index] = turned.noteCentre(degree) - turned.centre;
                half_sizes[first_point + note_index] = turned.noteHalfSize(degree);
            }
            for (star.scale.chords, 0..) |chord, chord_index| {
                place_offsets[first_point + 7 + chord_index] = turned.chordCentre(chord) - turned.centre;
                half_sizes[first_point + 7 + chord_index] = turned.chordHalfSize(chord);
            }
        }
        // The places, as multiples of the radii now: what each axis's radius scales.
        var coefficients: [2][fit_point_count]f32 = undefined;
        inline for (0..2) |axis| {
            for (0..fit_point_count) |point_index| {
                const radius: f32 = star.note_ellipse_radii[axis];
                coefficients[axis][point_index] = place_offsets[point_index][axis] / radius;
            }
        }
        const fit_x: AxisFit = fitAxis(&coefficients[0], &half_sizes, room.width);
        const fit_y: AxisFit = fitAxis(&coefficients[1], &half_sizes, room.height);
        star.setRadii(.{ fit_x.radius, fit_y.radius });
        star.centre = .{ room.x + fit_x.centre_from_start, room.y + fit_y.centre_from_start };
    }

    /// One axis of a fit: the ellipses' radius along it, and where the figure's centre falls, from the room's start.
    const AxisFit = struct {
        /// The radius along the axis.
        radius: f32,
        /// Where the figure's centre falls, measured from the room's start on the axis.
        centre_from_start: f32,
    };

    /// The largest radius at which targets placed at `coefficients x radius` from the centre, each `half_sizes` to
    /// either side, span no more than `room_length`, and the centre that puts that span in the middle of the room.
    /// The span only grows with the radius, so the largest is found by halving an interval that holds it, 32 times.
    fn fitAxis(
        coefficients: *const [fit_point_count]f32,
        half_sizes: *const [fit_point_count]f32,
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
        /// The lowest point, from the centre: below it, so negative.
        low: f32,
        /// The highest point, from the centre.
        high: f32,
    };

    /// The span the targets reach along one axis at `radius`: the lowest of their near edges and the highest of their
    /// far edges, measured from the figure's centre.
    fn spanAt(
        coefficients: *const [fit_point_count]f32,
        half_sizes: *const [fit_point_count]f32,
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
    /// Between a chord and its own three notes: more, so that the lines between them have room to show.
    const own_note_clearance_in_units: f32 = 0.55;

    /// The largest size unit at which none of the fourteen targets comes nearer another than its clearance, at the
    /// places the curve gives them now: the smallest of the limits every pair sets (`largestUnitApart`). A chord counts
    /// as its triplet's three shapes (`chordTripletShapes`), spread at the size the last round found: the rounds that
    /// settle the layout spread them anew each time, the size and the spread settling together (`settled`).
    fn largestSizeUnit(star: StarLayout) f32 {
        var size_unit: f32 = inf(f32);
        for (all_degrees, 0..) |degree, note_index| {
            const note_centre: Vec2 = star.noteCentre(degree);
            const note_shape: ShapedSize = .{
                .shape = shapeOfDegree(&star.scale, degree),
                .size_in_units = star.noteSizeInUnits(degree),
            };
            for (all_degrees[note_index + 1 ..]) |other_degree| {
                const other_shape: ShapedSize = .{
                    .shape = shapeOfDegree(&star.scale, other_degree),
                    .size_in_units = star.noteSizeInUnits(other_degree),
                };
                const offset: Vec2 = star.noteCentre(other_degree) - note_centre;
                size_unit = @min(size_unit, largestUnitApart(offset, note_shape, other_shape, clearance_in_units));
            }
            for (star.scale.chords) |chord| {
                const is_own_note: bool = indexOfScalar(u8, &chord.degrees(), degree) != null;
                const clearance: f32 = if (is_own_note) own_note_clearance_in_units else clearance_in_units;
                const triplet_size_in_units: f32 = shapedSizeOfChord(&star.scale, chord).size_in_units;
                for (star.chordTripletShapes(chord)) |placed_shape| {
                    const chord_shape: ShapedSize = .{
                        .shape = placed_shape.shape,
                        .size_in_units = triplet_size_in_units,
                    };
                    const offset: Vec2 = placed_shape.centre - note_centre;
                    size_unit = @min(size_unit, largestUnitApart(offset, note_shape, chord_shape, clearance));
                }
            }
        }
        for (star.scale.chords, 0..) |chord, chord_index| {
            const triplet_size_in_units: f32 = shapedSizeOfChord(&star.scale, chord).size_in_units;
            for (star.scale.chords[chord_index + 1 ..]) |other_chord| {
                const other_triplet_size_in_units: f32 = shapedSizeOfChord(&star.scale, other_chord).size_in_units;
                size_unit = @min(size_unit, largestUnitApartTriplets(
                    star.chordTripletShapes(chord),
                    triplet_size_in_units,
                    star.chordTripletShapes(other_chord),
                    other_triplet_size_in_units,
                    clearance_in_units,
                ));
            }
        }
        return size_unit;
    }

    /// The point at place `circle_place` of 7 on the star's curve scaled by `scale`: place `k` is `k / 7` of the
    /// curve's length round from the figure's rotation (`pointAtFractionalPlace`).
    fn pointAtPlace(star: StarLayout, circle_place: u8, scale: f32) Vec2 {
        return star.pointAtFractionalPlace(float(circle_place), scale);
    }

    /// The point at a place that may lie between two - `place` 2.5 halfway from place 2 to place 3 - on the star's
    /// curve scaled by `scale` about its centre: `place / 7` of the curve's length back from the star's rotation
    /// (`StarCurve.unitPointAt`).
    fn pointAtFractionalPlace(star: StarLayout, place: f32, scale: f32) Vec2 {
        const arc_turns: f32 = star.rotation_turns - place / 7;
        const unit_point: Vec2 = star.curve.unitPointAt(arc_turns);
        return star.centre + unit_point * splat2(star.note_ellipse_radii[0] * scale);
    }

    /// Sets the ellipse's radii, and makes its curve again for them.
    fn setRadii(star: *StarLayout, radii: Vec2) void {
        star.note_ellipse_radii = radii;
        star.curve = .ofRadii(radii);
    }

    /// A note's centre: at its place on the star's curve.
    fn noteCentre(star: StarLayout, degree: u8) Vec2 {
        return star.pointAtPlace(circlePlaceOfDegree(degree), 1);
    }

    /// A chord's centre: at its third's place, on the outer ring for a chord of the side that is outside, the inner for
    /// the other - or, while the sides trade places, the fraction `minor_side_outside_fraction` of the way from one to
    /// the other. A chord's shape fans out from it to the two links of the curve its notes span - root to third,
    /// third to fifth (`drawChordShapes`) - and every link is faced by one chord outside the curve and one inside it:
    ///
    ///     link        1-3   3-5   5-7   7-2   2-4   4-6   6-1
    ///     outside     I     I     V     V     -     IV    IV        the major side outside, as the star rests
    ///     inside      vi    iii   iii   -     ii    ii    vi
    ///
    /// So each chord stands at its third's place, between its two links: its two fans meet its neighbours' only at
    /// the notes they share, and the shapes inside and outside the curve meet only along its arc. The diminished chord,
    /// whose links a major or a minor chord already faces on one side, stands on the outer ring at its third's place
    /// too, and fans out only to the one link no other chord faces outside - 2 to 4, its third to its fifth, with the
    /// major side outside; 7 to 2, its root to its third, with the minor side outside (`drawChordShapes`).
    fn chordCentre(star: StarLayout, given_chord: ScaleChord) Vec2 {
        // Placed as the layout's scale places the chord on its root - the chosen scale's: a chord a borrowed one has
        // altered, III where iii was, stays where iii stands rather than moving to the other ring while held.
        const chord: ScaleChord = star.scale.chords[given_chord.root_degree - 1];
        const third_degree: u8 = chord.degrees()[1];
        const inner: f32 = star.inner_chord_scale;
        const outer: f32 = star.outer_chord_scale;
        // How far out the chord's own side is: the minor side's fraction for a minor-side chord, the rest for a major.
        const minor_outward: f32 = star.minor_side_outside_fraction;
        const side_outward: f32 = if (chord.isMinorSide()) minor_outward else 1 - minor_outward;
        const third_place: f32 = float(circlePlaceOfDegree(third_degree));
        if (chord.quality == .diminished) {
            return star.pointAtFractionalPlace(third_place, outer);
        }
        const scale: f32 = inner + (outer - inner) * side_outward;
        return star.pointAtFractionalPlace(third_place, scale);
    }
};

// ---- The window: the keyboard, the chooser and the star ----

/// Whether the note of `pitch_class` is a black key on a piano: C#, D#, F#, G# and A#.
fn isBlackPitchClass(pitch_class: u4) bool {
    return switch (pitch_class) {
        1, 3, 6, 8, 10 => true,
        else => false,
    };
}

/// The keyboard as a piano's (`drawKeyboard`, `WindowParts.keyboardDegreeAt`): the octave from the scale's tonic to
/// the tonic above, every key of it, white and black, where a piano has it - so that the scale shows as the keys to
/// play, whatever its key and mode. A key the scale uses takes its degree's color and plays it; the others play
/// nothing, the white ones grey and the black ones black. A tonic on a white key starts and ends the keyboard, eight
/// white keys: C to C in C, D to D in D Dorian. A tonic on a black key - A# - starts and ends the octave on black
/// keys, so a white key frames each end, the one below the tonic and the one above the tonic above, as a piano has
/// them round its black keys: nine white keys, the two framing ones outside the octave and silent.
///
///         A# major, A# to A#:
///          _ A#  _ C#_ D#  _ F#_ G#_ A#  _
///         | |1| | |  | |  | |  | | |1| |
///         | |_| | |__| |__| |__|_|_|_| |
///         |  A |B |C2 |D3 |E |F5 |G6|A7|B |      white keys A and B framing, grey; C, D, F, G, A in the
///         |____|__|___|___|__|___|__|__|__|      scale - B#, C##, E#, F##, G## as it spells them
///
/// Each key is counted in semitones from the tonic: 0 the tonic, 12 the tonic above; -1 and 13 the framing keys.
const PianoLayout = struct {
    /// The tonic's pitch class, C as 0.
    tonic_pitch_class: u4,
    /// The first white key's semitones from the tonic: 0, the tonic itself, or -1 below a black tonic.
    first_white_semitones: i8,
    /// How many white keys: 8, or 9 round a black tonic.
    white_count: u8,

    /// The layout for `scale`'s tonic.
    fn ofScale(scale: *const Scale) PianoLayout {
        const tonic_pitch_class: u4 = @intCast(scale.tonicPitchClass());
        const is_black_tonic: bool = isBlackPitchClass(tonic_pitch_class);
        return .{
            .tonic_pitch_class = tonic_pitch_class,
            .first_white_semitones = if (is_black_tonic) -1 else 0,
            .white_count = if (is_black_tonic) 9 else 8,
        };
    }

    /// The pitch class of the key `semitones` from the tonic.
    fn pitchClassAt(layout: PianoLayout, semitones: i8) u4 {
        return @intCast(@mod(@as(i16, layout.tonic_pitch_class) + semitones, 12));
    }

    /// The semitones from the tonic of the white key `white_index`, counted from the left: each white key a whole
    /// step above the one before it, but a half step after E and after B, where a piano has no black key.
    fn whiteSemitones(layout: PianoLayout, white_index: usize) i8 {
        var semitones: i8 = layout.first_white_semitones;
        for (0..white_index) |_| {
            const pitch_class: u4 = layout.pitchClassAt(semitones);
            semitones += if (pitch_class == 4 or pitch_class == 11) 1 else 2;
        }
        return semitones;
    }

    /// Whether a black key follows the white key `white_index`: a whole step on to the next white key.
    fn hasBlackAfter(layout: PianoLayout, white_index: usize) bool {
        if (white_index + 1 >= layout.white_count) {
            return false;
        }
        const pitch_class: u4 = layout.pitchClassAt(layout.whiteSemitones(white_index));
        return pitch_class != 4 and pitch_class != 11;
    }

    /// The degree the key `semitones` from the tonic plays in `scale`: its pitch class's degree, within the octave
    /// from the tonic to the tonic above; null outside it, and for a note the scale does not use.
    fn degreeAt(layout: PianoLayout, scale: *const Scale, semitones: i8) ?u8 {
        if (semitones < 0 or semitones > 12) {
            return null;
        }
        return scale.degreeOfPitchClass(layout.pitchClassAt(semitones));
    }
};

/// `rectangle` shrunk by `inset` on every side.
fn insetRectangle(rectangle: z.Rectangle, inset: f32) z.Rectangle {
    return .{
        .x = rectangle.x + inset,
        .y = rectangle.y + inset,
        .width = rectangle.width - 2 * inset,
        .height = rectangle.height - 2 * inset,
    };
}

/// The progression editor's band's height (`WindowParts.editor`): a tenth of the window's, within 30 and 64 pixels.
fn editorHeight(window_height: f32) f32 {
    return clamp(0.1 * window_height, 30, 64);
}

/// The window's parts: the left hand's column in 21% of it (`params.window.chooser_share`) - on the left, or across the
/// top of a screen held upright - with the key's window on the circle of fifths and the chooser; the circle of the
/// twelve notes at the top right; and the star between them, below the line of text at the top, a margin from the line
/// between.
const WindowParts = struct {
    /// The key's window on the circle of fifths (`drawFifths`), at the top of the left hand's column - or at the left
    /// of its band - and the chooser below it, or to its right.
    fifths: z.Rectangle,
    /// The chooser's part: the left hand's column below the key's window.
    chooser: z.Rectangle,
    /// The circle of the twelve notes and the chord's name (`drawChromaticCircle`), in a square at the top right.
    chromatic: z.Rectangle,
    /// The star's part: what the other parts leave in the middle, below the progression editor.
    star: z.Rectangle,
    /// The progression editor's band (`drawProgressionEditor`): across the top of the star's column, its boxes in a
    /// row, the star a margin below.
    editor: z.Rectangle,
    /// The thin keyboard along the bottom (`drawKeyboard`), and the fullscreen button's top left corner.
    keyboard: z.Rectangle,
    /// The box where what sounds is shown: its Lissajous figure (`drawChordCurve`) and its name (`drawChordNumeral`) -
    /// below the circle's square, at the right, on a window wider than tall; at the bottom of the star's part on one
    /// held upright.
    sounding: z.Rectangle,
    /// The top left corner of the page's fullscreen button's corner, at the bottom right, which plays nothing.
    button_corner: Vec2,
    /// Where the header's box ends on the right: its text and its padding (`buildOptionsButton`) - the options' button
    /// and the scale's name take touches to its left, the star to its right (`isInHeader`).
    header_right: f32,

    /// The window's parts for its size now: the keyboard along the bottom, then the chooser and the star above it,
    /// side by side on a window wider than tall and one above the other on a taller one.
    fn ofWindow(f: *z.Frame, header_content_right: f32) WindowParts {
        // The header's box as drawn (`buildOptionsButton`): its text and padding, or 360 pixels before its text is
        // measured.
        const header_box_right: f32 = if (header_content_right > 0)
            header_content_right + params.window.header_padding
        else
            StarLayout.margin + 360;
        const width: f32 = f.window.widthf();
        const height: f32 = f.window.heightf();
        const top: f32 = StarLayout.header_height + StarLayout.margin;
        const margin: f32 = StarLayout.margin;
        const button_reach: f32 = StarLayout.fullscreen_button_reach;
        const button_corner: Vec2 = .{ width - button_reach, height - button_reach };
        // The keyboard: a thin strip along the bottom, 7.2% of the window's height within 19 and 43 pixels, ending
        // well before the fullscreen button.
        const keyboard_height: f32 = clamp(0.072 * height, 19, 43);
        const keyboard: z.Rectangle = .{
            .x = margin,
            .y = height - margin - keyboard_height,
            .width = button_corner[0] - 2 * margin - params.window.keyboard_gap_before_button,
            .height = keyboard_height,
        };
        // The star and the chooser above it, the star's part ending a little above the keyboard, so that the chord
        // at the bottom of the star stands clear of the keys.
        const star_lift: f32 = 0.04 * height;
        const content: z.Rectangle = .{
            .x = margin,
            .y = top,
            .width = width - 2 * margin,
            .height = keyboard.y - margin - top - star_lift,
        };
        if (content.width >= content.height) {
            // The left hand's column, the key's window above the chooser; the circle's square at the top right; the
            // star between, narrowed by the circle's side.
            const column_width: f32 = params.window.chooser_share * content.width;
            const fifths_height: f32 = params.window.fifths_share * content.height;
            const chromatic_side: f32 = @min(params.window.chromatic_share * content.width, content.height);
            // The circle's square in the content's top right corner, boxed as the left diagrams are, the sounding box
            // below it, as wide, down to the content's bottom; the star stops at their left side
            // (`params.window.star_under_chromatic_share`).
            const star_right_inset: f32 = params.window.star_under_chromatic_share * chromatic_side;
            // The star a little away from the column, which its boxes close off: 4% of the width between them.
            const star_left_gap: f32 = params.window.star_gap_share * content.width;
            // The star up to the window's top where the header's text ends before it - the header only as wide as its
            // text - and below the header's line where a long scale's name reaches over it.
            const star_x: f32 = content.x + column_width + star_left_gap;
            const header_right: f32 = header_content_right + params.window.header_padding + margin;
            const is_star_beside_header: bool = header_content_right > 0 and header_right <= star_x;
            // The progression editor across the column's top, the star below it.
            const column_top: f32 = if (is_star_beside_header) margin else content.y;
            const star_width: f32 = content.width - column_width - star_right_inset - star_left_gap;
            const editor: z.Rectangle = .{
                .x = star_x,
                .y = column_top,
                .width = star_width,
                .height = editorHeight(height),
            };
            const star_top: f32 = editor.y + editor.height + margin;
            return .{
                .fifths = .{ .x = content.x, .y = content.y, .width = column_width, .height = fifths_height },
                .chooser = .{
                    .x = content.x,
                    .y = content.y + fifths_height,
                    .width = column_width,
                    .height = content.height - fifths_height,
                },
                .chromatic = .{
                    .x = content.x + content.width - chromatic_side,
                    .y = content.y,
                    .width = chromatic_side,
                    .height = chromatic_side,
                },
                .sounding = .{
                    .x = content.x + content.width - chromatic_side,
                    .y = content.y + chromatic_side,
                    .width = chromatic_side,
                    .height = content.height - chromatic_side,
                },
                .star = .{
                    .x = star_x,
                    .y = star_top,
                    .width = star_width,
                    .height = content.y + content.height - star_top,
                },
                .editor = editor,
                .keyboard = keyboard,
                .button_corner = button_corner,
                .header_right = header_box_right,
            };
        }
        // Held upright: the band across the top - the key's window, the chooser, the circle's square - the star below,
        // and below it, across, the sounding box: the star is as wide as the window lets it be, and has height to
        // spare.
        const band_height: f32 = params.window.chooser_share * content.height;
        const fifths_width: f32 = 0.36 * content.width;
        const chromatic_side: f32 = band_height;
        const sounding_height: f32 = params.window.upright_sounding_share * content.width;
        // The progression editor between the band and the star.
        const editor: z.Rectangle = .{
            .x = content.x,
            .y = content.y + band_height + margin,
            .width = content.width,
            .height = editorHeight(height),
        };
        const star_top: f32 = editor.y + editor.height + margin;
        const star_height: f32 = content.y + content.height - star_top - sounding_height;
        return .{
            .fifths = .{ .x = content.x, .y = content.y, .width = fifths_width, .height = band_height },
            .chooser = .{
                .x = content.x + fifths_width,
                .y = content.y,
                .width = content.width - fifths_width - chromatic_side,
                .height = band_height,
            },
            .chromatic = .{
                .x = content.x + content.width - chromatic_side,
                .y = content.y,
                .width = chromatic_side,
                .height = chromatic_side,
            },
            .star = .{
                .x = content.x,
                .y = star_top,
                .width = content.width,
                .height = star_height,
            },
            .editor = editor,
            .sounding = .{
                .x = content.x,
                .y = star_top + star_height,
                .width = content.width,
                .height = sounding_height,
            },
            .keyboard = keyboard,
            .button_corner = button_corner,
            .header_right = header_box_right,
        };
    }

    /// Whether `point` belongs to the star: not the keyboard's band, the left hand's column, the circle's square or
    /// the sounding box - every other point is the star's, its nearest target taking it (`targetAt`).
    fn isInStarArea(parts: WindowParts, point: Vec2) bool {
        const is_elsewhere: bool = parts.isBelowStar(point) or parts.isInChooser(point) or
            parts.isInFifths(point) or parts.isInChromatic(point) or parts.isInSounding(point) or
            parts.isInEditor(point);
        return !is_elsewhere;
    }

    /// Whether `point` is on the progression editor's band.
    fn isInEditor(parts: WindowParts, point: Vec2) bool {
        return parts.editor.contains(point);
    }

    /// The editor's box `box_index` of `box_count`, in a row across its band: as wide as the band allows the row, a
    /// tenth of a box between two, but at most 1.6 times the band's height - square enough for a chord's button -
    /// the row centred.
    fn editorBox(parts: WindowParts, box_count: usize, box_index: usize) z.Rectangle {
        const band: z.Rectangle = parts.editor;
        const count: f32 = float(box_count);
        const gap_share: f32 = 0.1;
        const fitted_width: f32 = band.width / (count + gap_share * (count - 1));
        const box_width: f32 = @min(fitted_width, 1.6 * band.height);
        const gap: f32 = gap_share * box_width;
        const row_width: f32 = count * box_width + (count - 1) * gap;
        const row_x: f32 = band.x + 0.5 * (band.width - row_width);
        return .{
            .x = row_x + float(box_index) * (box_width + gap),
            .y = band.y,
            .width = box_width,
            .height = band.height,
        };
    }

    /// The editor's box at `point`, of `box_count`, or null between and beside them.
    fn editorBoxAt(parts: WindowParts, box_count: usize, point: Vec2) ?usize {
        for (0..box_count) |box_index| {
            if (parts.editorBox(box_count, box_index).contains(point)) {
                return box_index;
            }
        }
        return null;
    }

    /// Whether `point` is below the star: on the keyboard, or in the margin around it.
    fn isBelowStar(parts: WindowParts, point: Vec2) bool {
        return point[1] >= parts.star.y + parts.star.height;
    }

    /// The degree of the piano key at `point` on the keyboard, laid out for `scale` (`PianoLayout`): a black key over
    /// the keyboard's upper part, where a black key stands over the boundary nearest the point; else the white key
    /// under it. Null for a key the scale does not use, and beside the keyboard, where the fullscreen button is.
    fn keyboardDegreeAt(parts: WindowParts, scale: *const Scale, point: Vec2) ?u8 {
        const keyboard: z.Rectangle = parts.keyboard;
        const offset_x: f32 = point[0] - keyboard.x;
        if (offset_x < 0 or offset_x >= keyboard.width) {
            return null;
        }
        const layout: PianoLayout = .ofScale(scale);
        const white_width: f32 = keyboard.width / float(layout.white_count);
        const is_black_height: bool = point[1] < keyboard.y + params.keyboard.black_key_height_share * keyboard.height;
        if (is_black_height) {
            const boundary_index: usize = @round(offset_x / white_width);
            const half_black_width: f32 = 0.5 * params.keyboard.black_key_width_share * white_width;
            const is_near_boundary: bool = @abs(offset_x - float(boundary_index) * white_width) < half_black_width;
            if (is_near_boundary and boundary_index >= 1 and layout.hasBlackAfter(boundary_index - 1)) {
                return layout.degreeAt(scale, layout.whiteSemitones(boundary_index - 1) + 1);
            }
        }
        const white_index: usize = @floor(offset_x / white_width);
        return layout.degreeAt(scale, layout.whiteSemitones(white_index));
    }

    /// Whether `point` is on the header: in the band along the top, above the parts - which all start at the same
    /// height, the key's window's top, in both orientations - and left of the header's box's right edge. Beside the
    /// box the band is the star's, which reaches up into it where the header leaves room (`ofWindow`), and at the
    /// right the circle's square's.
    fn isInHeader(parts: WindowParts, point: Vec2) bool {
        return point[1] < parts.fifths.y and point[0] < parts.header_right;
    }

    /// Whether `point` is on the key's window on the circle of fifths.
    fn isInFifths(parts: WindowParts, point: Vec2) bool {
        return parts.fifths.contains(point);
    }

    /// Whether `point` is on the circle of the twelve notes' square.
    fn isInChromatic(parts: WindowParts, point: Vec2) bool {
        return parts.chromatic.contains(point);
    }

    /// Whether `point` is in the sounding box, which plays nothing.
    fn isInSounding(parts: WindowParts, point: Vec2) bool {
        return parts.sounding.contains(point);
    }

    /// Whether `point` is in the chooser's part.
    fn isInChooser(parts: WindowParts, point: Vec2) bool {
        return parts.chooser.contains(point);
    }
};

/// The chooser: the seven chords alone, laid out as the star's notes are - on the star's own curve, flattened at the
/// bottom (`chooserCurveDirection`), at the star's turn with nothing chosen - each chord at the place of its root: I
/// where 1 is, at the bottom's left, iii where 3 is and V where 5 is, the three on one line as the star's 1, 3 and 5. A
/// chord built on a note is where the note is, so the two figures read alike, and the notes sounding, joined on the
/// chooser (`drawChooserPolygon`), make the star's own shape. Its chords are larger than the star's, as targets for the
/// left hand: as large as the closest two places allow, with room between them even for the chosen chord, drawn a
/// quarter larger.
const ChooserLayout = struct {
    /// The curve's centre in the chooser's room.
    centre: Vec2,
    /// The curve's radii: the star's curve scaled to fit the chooser's room, by one scale on both axes.
    radii: Vec2,
    /// A chord's half-size is its size in units (`chordSizeInUnits`) times this.
    size_unit: f32,
    /// The star's turn with nothing chosen, which the chooser's places follow.
    rotation_turns: f32,
    /// The scale whose chords the chooser shows.
    scale: Scale,

    /// The rounds `ofRoom` settles the curve's fit and the chords' size in: each depends on the other.
    const settling_rounds: usize = 3;
    /// The space left between two neighbours at their largest, as a share of their sizes added: 5%.
    const neighbour_margin: f32 = 1.05;
    /// How much of its height the star's curve keeps in the chooser: 0.7, squished from top to bottom.
    const vertical_squish: f32 = 0.56;

    /// The chosen chord's size beside the others' (`drawChooserChord`), which the spacing must leave room for.
    const chosen_chord_scale: f32 = 1.25;

    /// The chooser in `room`, its chords at the star's places for `rotation_turns`, sized for `scale`: as large as
    /// the room allows. The places on a unit curve first; then, in rounds, the radii that fit their extent and the
    /// chords' outer halves into the room on each axis, and the chords' size that the closest two places allow -
    /// two of the largest chords, one of them chosen, with 10% between them.
    fn ofRoom(room: z.Rectangle, rotation_turns: f32, scale: Scale) ChooserLayout {
        var unit_points: [7]Vec2 = undefined;
        var lowest: Vec2 = @splat(inf(f32));
        var highest: Vec2 = @splat(-inf(f32));
        for (&unit_points, 0..) |*unit_point, place| {
            const angle_turns: f32 = rotation_turns - float(place) / 7;
            const curve_point: Vec2 = chooserCurveDirection(angle_turns);
            // Squished from top to bottom: the chooser need not match the star exactly, and a flatter curve leaves
            // less empty space between its rows of chords.
            unit_point.* = .{ curve_point[0], vertical_squish * curve_point[1] };
            lowest = @min(lowest, unit_point.*);
            highest = @max(highest, unit_point.*);
        }
        const unit_half_extent: Vec2 = (highest - lowest) * splat2(0.5);
        const unit_middle: Vec2 = (highest + lowest) * splat2(0.5);
        const room_half_size: Vec2 = .{ room.width / 2, room.height / 2 };
        const room_centre: Vec2 = .{ room.x + room.width / 2, room.y + room.height / 2 };
        const largest_half_size_in_units: f32 = chosen_chord_scale * params.sizes.largest_chord_size_in_units;
        // Each pair of chords at their own sizes - the larger of the two chosen, a quarter larger - with the margin
        // between them: their distance on the unit curve per size unit they need. The smallest of these sets the size.
        var size_unit: f32 = 0;
        var radii: Vec2 = room_half_size / unit_half_extent;
        for (0..settling_rounds) |_| {
            const largest_half_size: f32 = largest_half_size_in_units * size_unit;
            const fitting_half_size: Vec2 = room_half_size - splat2(largest_half_size);
            // One scale for both axes, the smaller fit: the curve keeps its own proportions, the star's, rather than
            // being stretched to fill its room - which put space between the buttons and none in them.
            const axis_fits: Vec2 = fitting_half_size / unit_half_extent;
            radii = @splat(@min(axis_fits[0], axis_fits[1]));
            var smallest_unit_allowed: f32 = inf(f32);
            for (unit_points, 0..) |unit_point, place| {
                const chord_size: f32 = chordSizeInUnits(&scale, scale.chords[degreeAtPlace(@intCast(place)) - 1]);
                for (unit_points[place + 1 ..], place + 1..) |other_unit_point, other_place| {
                    const other_chord: ScaleChord = scale.chords[degreeAtPlace(@intCast(other_place)) - 1];
                    const other_size: f32 = chordSizeInUnits(&scale, other_chord);
                    const larger_size: f32 = @max(chord_size, other_size);
                    const smaller_size: f32 = @min(chord_size, other_size);
                    const pair_in_units: f32 = (chosen_chord_scale * larger_size + smaller_size) * neighbour_margin;
                    const distance_between: f32 = length((unit_point - other_unit_point) * radii);
                    smallest_unit_allowed = @min(smallest_unit_allowed, distance_between / pair_in_units);
                }
            }
            size_unit = smallest_unit_allowed;
        }
        return .{
            // The curve's middle, not its centre, at the room's: its flattened bottom makes the two differ.
            .centre = room_centre - unit_middle * radii,
            .radii = radii,
            .size_unit = size_unit,
            .rotation_turns = rotation_turns,
            .scale = scale,
        };
    }

    /// A chord's centre in the chooser: at its root's place on the curve - squished as the chooser's is - where the
    /// star has the root's note.
    fn chordCentre(chooser: ChooserLayout, chord: ScaleChord) Vec2 {
        const root_place: u8 = circlePlaceOfDegree(chord.root_degree);
        const angle_turns: f32 = chooser.rotation_turns - float(root_place) / 7;
        const curve_point: Vec2 = chooserCurveDirection(angle_turns);
        const squished_point: Vec2 = .{ curve_point[0], vertical_squish * curve_point[1] };
        return chooser.centre + squished_point * chooser.radii;
    }

    /// A chord's half-size in pixels, in the chooser.
    fn chordHalfSize(chooser: ChooserLayout, chord: ScaleChord) f32 {
        return chordSizeInUnits(&chooser.scale, chord) * chooser.size_unit;
    }

    /// The chord nearest `point`, by the distance to its shape: the whole chooser is divided among the seven.
    fn nearestChord(chooser: ChooserLayout, point: Vec2) u8 {
        var nearest_index: u8 = 0;
        var nearest_distance: f32 = inf(f32);
        for (chooser.scale.chords, 0..) |chord, chord_index| {
            const half_size: f32 = chooser.chordHalfSize(chord);
            const chord_centre: Vec2 = chooser.chordCentre(chord);
            const chord_distance: f32 = distanceToShape(point, chord_centre, shapeOfChord(chord), half_size);
            if (chord_distance < nearest_distance) {
                nearest_index = @intCast(chord_index);
                nearest_distance = chord_distance;
            }
        }
        return nearest_index;
    }
};

/// Everything's place in the window: its two parts, the star's layout with nothing chosen, and the chooser's.
/// The circle of the twelve notes, in its part of the window (`drawChromaticCircle`): its centre, its radius, and the
/// half-size of the notes on it - the scale's, in their shapes; the others are small dots. Each pitch class sits at its
/// semitones above the tonic, a twelfth of a turn each, the tonic at the top: an interval is a fixed angle in any key.
const ChromaticLayout = struct {
    /// The circle's centre.
    centre: Vec2,
    /// The circle's radius, the notes' centres on it.
    radius: f32,
    /// A note's half-size on it, at rest: the half-side of its square, or its circle's radius.
    note_half_size: f32,

    /// The circle in `area`: notes on a circle with room for their own size round it - twelve round, neighbours 0.52
    /// radii apart.
    fn ofArea(area: z.Rectangle) ChromaticLayout {
        const shorter_side: f32 = @min(area.width, area.height);
        return .{
            .centre = .{ area.x + area.width / 2, area.y + area.height / 2 },
            .radius = 0.37 * shorter_side,
            .note_half_size = 0.085 * shorter_side,
        };
    }

    /// Where pitch class `pitch_class` sits, in `scale`: at its semitones above the tonic, clockwise from the top.
    fn placeOf(chromatic: ChromaticLayout, scale: *const Scale, pitch_class: u4) Vec2 {
        const tonic_pitch_class: u8 = scale.pitchClassOfDegree(1);
        const semitones_above_tonic: u8 = (@as(u8, pitch_class) + 12 - tonic_pitch_class) % 12;
        const angle_turns: f32 = float(semitones_above_tonic) / 12;
        const direction: Vec2 = .{ sinTurns(angle_turns), -cosTurns(angle_turns) };
        return chromatic.centre + direction * splat2(chromatic.radius);
    }

    /// A scale's note at rest is drawn this much of its size: three quarters - a note sounding, whole.
    const resting_note_scale: f32 = 0.75;

    /// The degree of the scale's note nearest `point`, by the distance to its shape at rest - as the star's and the
    /// chooser's targets are found: every point of the circle's part belongs to one of the seven, so a press anywhere
    /// near a note plays it, the five other pitch classes' dots and the circle's middle included.
    fn degreeAt(chromatic: ChromaticLayout, scale: *const Scale, point: Vec2) u8 {
        const resting_half_size: f32 = resting_note_scale * chromatic.note_half_size;
        var nearest_degree: u8 = 1;
        var nearest_distance: f32 = inf(f32);
        for (all_degrees) |degree| {
            const place: Vec2 = chromatic.placeOf(scale, scale.pitchClassOfDegree(degree));
            const note_shape: Shape = shapeOfDegree(scale, degree);
            const distance_to_note: f32 = distanceToShape(point, place, note_shape, resting_half_size);
            if (distance_to_note < nearest_distance) {
                nearest_distance = distance_to_note;
                nearest_degree = degree;
            }
        }
        return nearest_degree;
    }
};

// ---- Guitar chords ----

/// A chord as fingered on a guitar in standard tuning (`guitarChordOf`): each string's fret, the lowest string first -
/// 0 an open string, null a string not played; the fret its diagram's window starts at, the lowest pressed; and the
/// finger laid flat across that fret, if the fingering needs one, a barre.
const GuitarChord = struct {
    /// Each string's fret, the lowest string first: 0 open, null not played.
    frets: [6]?u8,
    /// The first fret of the diagram's window of four: the lowest pressed, or 1.
    window_start: u8,
    /// The finger laid flat across the window's first fret, if the fingering needs one.
    barre: ?Barre,

    /// A finger laid flat across `fret`, from string `from_string` up to the highest.
    const Barre = struct {
        /// The fret it lies across.
        fret: u8,
        /// The lowest string it covers, 0 the lowest of the six.
        from_string: u8,
    };
};

/// A fingering being sought (`guitarChordOf`): the best found so far, and its cost.
const GuitarSearch = struct {
    /// The chord's pitch classes: root, third, fifth.
    chord_pitch_classes: [3]u4,
    /// The best fingering found so far.
    best: GuitarChord,
    /// What it costs (`guitarChordCost`); infinite before any is found.
    best_cost: f32,
};

/// Whether `pitch_class` is one of the chord's.
fn isChordPitchClass(chord_pitch_classes: [3]u4, pitch_class: u4) bool {
    return indexOfScalar(u4, &chord_pitch_classes, pitch_class) != null;
}

/// The pitch class string `string_index` sounds at `fret`.
fn guitarPitchClass(string_index: usize, fret: u8) u4 {
    return @intCast((params.guitar.string_keys[string_index] + fret) % 12);
}

/// The barre a fingering in the window from `window_start` can use: a finger flat across the window's first fret,
/// from the lowest string pressed there up - possible where two strings or more are pressed there and every string
/// above the first of them is pressed too, none open or left out, the finger lying across them all. Null if not.
fn guitarBarre(window_start: u8, frets: [6]?u8) ?GuitarChord.Barre {
    var from_string: ?u8 = null;
    var strings_at_fret: usize = 0;
    for (frets, 0..) |maybe_fret, string_index| {
        const fret: u8 = maybe_fret orelse continue;
        if (fret == window_start) {
            strings_at_fret += 1;
            if (from_string == null) {
                from_string = @intCast(string_index);
            }
        }
    }
    const first_string: u8 = from_string orelse return null;
    if (strings_at_fret < 2) {
        return null;
    }
    for (frets[first_string..]) |maybe_fret| {
        const fret: u8 = maybe_fret orelse return null;
        if (fret == 0) {
            return null;
        }
    }
    return .{ .fret = window_start, .from_string = first_string };
}

/// What a fingering costs, or null if it is not one to play (`guitarChordOf`'s rules):
///
///     3 for each fret of its window's start          the lower on the neck, the easier
///     2 for each string not played                   the fuller, the better
///     1 for each finger                              the fewer, the easier
///     1 for each fret the hand stretches             from the lowest fret pressed to the highest
///     -1 for each open string                        open strings ring
///     1 for a barre                                  a finger flat across the neck is harder than pressing one string
///
/// A fingering counts in one window only, the one starting at its lowest fret pressed; one with none pressed, in the
/// first.
fn guitarChordCost(chord_pitch_classes: [3]u4, window_start: u8, frets: [6]?u8) ?f32 {
    var lowest_pitch_class: ?u4 = null;
    var heard: [3]bool = @splat(false);
    var played_count: usize = 0;
    var open_count: usize = 0;
    var pressed_count: usize = 0;
    var lowest_pressed: u8 = maxInt(u8);
    var highest_pressed: u8 = 0;
    for (frets, 0..) |maybe_fret, string_index| {
        const fret: u8 = maybe_fret orelse continue;
        const pitch_class: u4 = guitarPitchClass(string_index, fret);
        if (lowest_pitch_class == null) {
            lowest_pitch_class = pitch_class;
        }
        heard[indexOfScalar(u4, &chord_pitch_classes, pitch_class).?] = true;
        played_count += 1;
        if (fret == 0) {
            open_count += 1;
        } else {
            pressed_count += 1;
            lowest_pressed = @min(lowest_pressed, fret);
            highest_pressed = @max(highest_pressed, fret);
        }
    }
    if (lowest_pitch_class != chord_pitch_classes[0]) {
        return null;
    }
    if (!heard[0] or !heard[1] or !heard[2]) {
        return null;
    }
    const counted_window: u8 = if (pressed_count == 0) 1 else lowest_pressed;
    if (counted_window != window_start) {
        return null;
    }
    // The fingers: one a string pressed, or, with a barre, one for the barre and one for each string pressed above it.
    var finger_count: usize = pressed_count;
    var barre_cost: f32 = 0;
    if (guitarBarre(window_start, frets)) |_| {
        var above_barre: usize = 0;
        for (frets) |maybe_fret| {
            const fret: u8 = maybe_fret orelse continue;
            if (fret > window_start) {
                above_barre += 1;
            }
        }
        const barre_finger_count: usize = 1 + above_barre;
        if (barre_finger_count < finger_count) {
            finger_count = barre_finger_count;
            barre_cost = 1;
        }
    }
    if (finger_count > 4) {
        return null;
    }
    const position_cost: f32 = if (pressed_count == 0) 0 else 3 * float(window_start);
    const strings_cost: f32 = 2 * float(6 - played_count);
    const stretch_cost: f32 = if (pressed_count == 0) 0 else float(highest_pressed - lowest_pressed);
    const fingers_cost: f32 = float(finger_count) + barre_cost;
    return position_cost + strings_cost + fingers_cost + stretch_cost - float(open_count);
}

/// Tries every choice for the strings from `string_index` up, the lower ones already chosen in `frets`: not played -
/// only while every string below is not played either - open, or pressed within the window from `window_start`, each
/// only where it sounds one of the chord's notes; and, all six chosen, weighs the fingering (`guitarChordCost`).
fn searchGuitarStrings(
    search: *GuitarSearch,
    window_start: u8,
    string_index: usize,
    frets: *[6]?u8,
) void {
    if (string_index == 6) {
        const cost: f32 = guitarChordCost(search.chord_pitch_classes, window_start, frets.*) orelse return;
        if (cost < search.best_cost) {
            search.best_cost = cost;
            search.best = .{
                .frets = frets.*,
                .window_start = window_start,
                .barre = guitarBarre(window_start, frets.*),
            };
        }
        return;
    }
    const is_any_played_below: bool = for (frets[0..string_index]) |fret| {
        if (fret != null) {
            break true;
        }
    } else false;
    if (!is_any_played_below) {
        frets[string_index] = null;
        searchGuitarStrings(search, window_start, string_index + 1, frets);
    }
    if (isChordPitchClass(search.chord_pitch_classes, guitarPitchClass(string_index, 0))) {
        frets[string_index] = 0;
        searchGuitarStrings(search, window_start, string_index + 1, frets);
    }
    var fret: u8 = window_start;
    while (fret < window_start + params.guitar.window_frets) : (fret += 1) {
        if (isChordPitchClass(search.chord_pitch_classes, guitarPitchClass(string_index, fret))) {
            frets[string_index] = fret;
            searchGuitarStrings(search, window_start, string_index + 1, frets);
        }
    }
    frets[string_index] = null;
}

/// The chord of `chord_pitch_classes` - root, third, fifth - as best fingered on a guitar in standard tuning. Every
/// fingering is tried, window by window up the neck (`searchGuitarStrings`), that:
///
///     plays the root as its lowest note             the chord heard from its root, as charts show a chord
///     plays all three of the chord's notes           and no other
///     leaves out only the lowest strings             strummed from the lowest played to the highest
///     presses frets within four of the lowest        the hand's reach
///     needs four fingers at most                     one finger laid flat across the lowest fret counting once
///
/// and the one costing least kept (`guitarChordCost`): the chords of the open position - C, G, D, A, E, Am, Em, Dm -
/// as every chart has them, and the others as barre chords up the neck.
fn guitarChordOf(chord_pitch_classes: [3]u4) GuitarChord {
    var search: GuitarSearch = .{
        .chord_pitch_classes = chord_pitch_classes,
        .best = .{ .frets = @splat(null), .window_start = 1, .barre = null },
        .best_cost = inf(f32),
    };
    var window_start: u8 = 1;
    while (window_start <= params.guitar.highest_window) : (window_start += 1) {
        var frets: [6]?u8 = @splat(null);
        searchGuitarStrings(&search, window_start, 0, &frets);
    }
    return search.best;
}

comptime {
    // The open position's chords, as every chart has them - and F as the full barre chord.
    @setEvalBranchQuota(20_000_000);
    const checks = [_]struct { pitch_classes: [3]u4, frets: [6]?u8 }{
        .{ .pitch_classes = .{ 0, 4, 7 }, .frets = .{ null, 3, 2, 0, 1, 0 } },
        .{ .pitch_classes = .{ 7, 11, 2 }, .frets = .{ 3, 2, 0, 0, 0, 3 } },
        .{ .pitch_classes = .{ 2, 6, 9 }, .frets = .{ null, null, 0, 2, 3, 2 } },
        .{ .pitch_classes = .{ 9, 1, 4 }, .frets = .{ null, 0, 2, 2, 2, 0 } },
        .{ .pitch_classes = .{ 4, 8, 11 }, .frets = .{ 0, 2, 2, 1, 0, 0 } },
        .{ .pitch_classes = .{ 9, 0, 4 }, .frets = .{ null, 0, 2, 2, 1, 0 } },
        .{ .pitch_classes = .{ 4, 7, 11 }, .frets = .{ 0, 2, 2, 0, 0, 0 } },
        .{ .pitch_classes = .{ 2, 5, 9 }, .frets = .{ null, null, 0, 2, 3, 1 } },
        .{ .pitch_classes = .{ 5, 9, 0 }, .frets = .{ 1, 3, 3, 2, 1, 1 } },
    };
    for (checks) |check| {
        const found: GuitarChord = guitarChordOf(check.pitch_classes);
        for (found.frets, check.frets) |found_fret, expected_fret| {
            if (found_fret != expected_fret) {
                @compileError("a guitar chord is not fingered as charts finger it");
            }
        }
    }
}

/// The key's window on the circle of fifths: the key's seven chords as the circle of fifths' chord wheel shows them,
/// each drawn as its button's shape - a square for a major chord, a circle for the others - holding its guitar chord
/// (`drawGuitarChord`), its name above it:
///
///                                  vii         the diminished chord, over iii
///                     vi
///           ii                     iii         the minors, each over its relative major, a minor third below it
///                     I
///           IV                     V           the majors, a fifth apart: the subdominant left, the dominant right
///
/// As on the wheel, the majors make the inner row, the minors the row outside it, each over its relative major, and
/// the diminished chord the outer. The rows bend down at their sides, IV and V a little lower than I: the step from
/// 4 to 5 in the star of steps (`drawColumnStar`), straight from IV to V, passes under I. The diminished chord stands
/// over iii, to the right, so that its step to I passes beside vi. The cells are placed by degree, so that every key
/// and mode keeps the shape, its cells showing the scale's own chords; and as large as the box allows (`ofArea`).
const FifthsLayout = struct {
    /// I's middle: the other cells' are placed from it.
    origin: Vec2,
    /// A chord's shape's half-size: the half-side of its square, or its circle's radius - what every other length
    /// of the window is a share of.
    half_size: f32,
    /// The scale whose chords the window shows: the chosen one.
    scale: Scale,
    /// The scale's chords as fingered on a guitar, the first degree's first (`guitarChordOf`): found once, with the
    /// window.
    guitar_chords: [7]GuitarChord,

    /// The space between two shapes side by side, in half-sizes: room for the star of steps' dots.
    const gap_share: f32 = 0.15;

    /// The height of a chord's name, above its shape, in half-sizes.
    const name_share: f32 = 0.5;

    /// The space between a chord's name and the shape above it, in half-sizes.
    const row_gap_share: f32 = 0.1;

    /// How much lower the rows' sides stand than their middles, in half-sizes: I's half-height and a little more,
    /// so that the line from IV to V passes under I.
    const side_drop_share: f32 = 1.2;

    /// The distance between two columns, and between two rows, in half-sizes.
    const column_share: f32 = 2 + gap_share;
    /// Between two rows: a shape, the name above the one over it and a little room.
    const row_share: f32 = 2 + name_share + row_gap_share;

    /// A cell of the window: the chord on `degree`, in row `row` - 0 the majors' - and column `column`, -1 the left,
    /// 1 the right.
    const Cell = struct {
        /// The chord's degree, 1 to 7.
        degree: u8,
        /// Its row: 0 the majors', 1 the minors', 2 the diminished chord's.
        row: u8,
        /// Its column: -1 the left, 0 the middle, 1 the right.
        column: i8,
    };
    /// The seven cells, by the wheel: IV, I and V; ii, vi and iii over them; vii over iii.
    const cells = [7]Cell{
        .{ .degree = 4, .row = 0, .column = -1 },
        .{ .degree = 1, .row = 0, .column = 0 },
        .{ .degree = 5, .row = 0, .column = 1 },
        .{ .degree = 2, .row = 1, .column = -1 },
        .{ .degree = 6, .row = 1, .column = 0 },
        .{ .degree = 3, .row = 1, .column = 1 },
        .{ .degree = 7, .row = 2, .column = 1 },
    };

    /// A cell's middle from I's, in half-sizes: its column across, its row up, its side's drop down.
    fn unitCellCentre(cell: Cell) Vec2 {
        const side_drop: f32 = if (cell.column != 0) side_drop_share else 0;
        return .{ float(cell.column) * column_share, side_drop - float(cell.row) * row_share };
    }

    /// The window filling `area`, for `scale`: its cells' shapes, with their names above, measured for a half-size
    /// of 1, and the half-size the larger at which their extent fits the area on both axes, centred in it.
    fn ofArea(area: z.Rectangle, scale: Scale) FifthsLayout {
        var lowest: Vec2 = @splat(inf(f32));
        var highest: Vec2 = @splat(-inf(f32));
        for (cells) |cell| {
            const unit_centre: Vec2 = unitCellCentre(cell);
            lowest = @min(lowest, unit_centre - Vec2{ 1, 1 + name_share });
            highest = @max(highest, unit_centre + Vec2{ 1, 1 });
        }
        const unit_extent: Vec2 = highest - lowest;
        const half_size: f32 = @min(area.width / unit_extent[0], area.height / unit_extent[1]);
        const unit_middle: Vec2 = (lowest + highest) * splat2(0.5);
        const area_middle: Vec2 = .{ area.x + 0.5 * area.width, area.y + 0.5 * area.height };
        var guitar_chords: [7]GuitarChord = undefined;
        for (&guitar_chords, scale.chords) |*guitar_chord, chord| {
            const degrees: [3]u8 = chord.degrees();
            guitar_chord.* = guitarChordOf(.{
                scale.pitchClassOfDegree(degrees[0]),
                scale.pitchClassOfDegree(degrees[1]),
                scale.pitchClassOfDegree(degrees[2]),
            });
        }
        return .{
            .origin = area_middle - unit_middle * splat2(half_size),
            .half_size = half_size,
            .scale = scale,
            .guitar_chords = guitar_chords,
        };
    }

    /// A cell's middle on the window.
    fn cellCentre(fifths: FifthsLayout, cell: Cell) Vec2 {
        return fifths.origin + unitCellCentre(cell) * splat2(fifths.half_size);
    }

    /// A chord's shape's half-size on the window.
    fn shapeHalfSize(fifths: FifthsLayout) f32 {
        return fifths.half_size;
    }

    /// The height of a chord's name above its shape.
    fn nameHeight(fifths: FifthsLayout) f32 {
        return name_share * fifths.half_size;
    }

    /// The box a chord's guitar chord is drawn in, inside its shape: most of its square, or of the square inside its
    /// circle.
    fn diagramBox(fifths: FifthsLayout, cell: Cell, shape: Shape) z.Rectangle {
        const inside_share: f32 = switch (shape) {
            .square => 0.9,
            .circle => 0.7,
        };
        const half_side: f32 = inside_share * fifths.half_size;
        const centre: Vec2 = fifths.cellCentre(cell);
        return .{
            .x = centre[0] - half_side,
            .y = centre[1] - half_side,
            .width = 2 * half_side,
            .height = 2 * half_side,
        };
    }

    /// The cell of the chord on `degree`.
    fn cellOfDegree(degree: u8) Cell {
        for (cells) |cell| {
            if (cell.degree == degree) {
                return cell;
            }
        }
        unreachable;
    }

    /// The chord nearest `point`, by the distance to its cell's middle: the whole window is divided among the seven.
    fn nearestChord(fifths: FifthsLayout, point: Vec2) u8 {
        var nearest_degree: u8 = 1;
        var nearest_distance: f32 = inf(f32);
        for (cells) |cell| {
            const distance_to_cell: f32 = length(point - fifths.cellCentre(cell));
            if (distance_to_cell < nearest_distance) {
                nearest_distance = distance_to_cell;
                nearest_degree = cell.degree;
            }
        }
        return nearest_degree - 1;
    }
};

/// Everything the window's parts hold, laid out for its size and the chosen scale (`windowLayoutOf`): worked out
/// again only when the size, the scale or the header's width changes, and kept between frames.
const WindowLayout = struct {
    /// The window's parts (`WindowParts`).
    parts: WindowParts,
    /// The star at rest, as the layout sized it: each frame turns it as it is shown (`starForChoice`).
    star: StarLayout,
    /// The chooser in its part.
    chooser: ChooserLayout,
    /// The circle of twelve in its square.
    chromatic: ChromaticLayout,
    /// The key's window in its part.
    fifths: FifthsLayout,
};

// ---- Choosing a chord ----

/// The turn of the star that brings a chord's root to place 0 - where the note 1 sits with nothing chosen - and so its
/// third to place 1 and its fifth to place 2, where 3 and 5 sit: the chord's three notes under the same three fingers
/// whichever chord is chosen. The places run counterclockwise, so a root at place `p` is turned on `p` sevenths of a
/// turn clockwise.
fn starTurnForChord(chord: ScaleChord) f32 {
    return float(circlePlaceOfDegree(chord.root_degree)) / 7;
}

/// The star's move from one chosen chord to the next: a turn, and its chords trading sides with it, both over
/// `params.star.transition_duration_seconds` from the moment of the choice. Everything shown in between is a straight
/// line from where the move started to where it ends, at the fraction of the time gone (`fraction`).
const StarTransition = struct {
    /// When the chord was chosen, on the frame's clock.
    started_seconds: f32,
    /// The star's turn when the chord was chosen - where it was shown then, even mid-move - and the chosen chord's.
    turn_from: f32,
    /// The turn it is moving to.
    turn_to: f32,
    /// Which side's chords were outside when the chord was chosen, and which will be (`StarLayout`'s
    /// `minor_side_outside_fraction`: 0 the major chords, 1 the minor side's).
    minor_side_outside_from: f32,
    /// Which side's chords it is moving to have outside.
    minor_side_outside_to: f32,

    /// At rest with the tonic's chord chosen, in a scale whose tonic chord is `tonic_chord`: no turn, and the tonic
    /// chord's side outside - the major chords for a major tonic chord, the minor side's for a minor or diminished one.
    /// Its start lies before the app's: no move is under way at the first frame.
    fn atRestOnTonic(tonic_chord: ScaleChord) StarTransition {
        const minor_side_outside: f32 = if (tonic_chord.isMinorSide()) 1 else 0;
        return .{
            .started_seconds = -1,
            .turn_from = 0,
            .turn_to = 0,
            .minor_side_outside_from = minor_side_outside,
            .minor_side_outside_to = minor_side_outside,
        };
    }

    /// How far the move has gone at `now_seconds`: 0 when the chord was chosen, 1 once the duration has passed.
    fn fraction(transition: StarTransition, now_seconds: f32) f32 {
        const elapsed_seconds: f32 = now_seconds - transition.started_seconds;
        return clamp(elapsed_seconds / params.star.transition_duration_seconds, 0, 1);
    }

    /// Whether the star is between two chords at `now_seconds`: turning, its chords trading sides.
    fn isUnderWay(transition: StarTransition, now_seconds: f32) bool {
        return transition.fraction(now_seconds) < 1;
    }

    /// The star's turn as shown at `now_seconds`.
    fn shownTurn(transition: StarTransition, now_seconds: f32) f32 {
        const turn_change: f32 = transition.turn_to - transition.turn_from;
        return transition.turn_from + turn_change * transition.fraction(now_seconds);
    }

    /// The chords' sides as shown at `now_seconds`.
    fn shownMinorSideOutside(transition: StarTransition, now_seconds: f32) f32 {
        const side_change: f32 = transition.minor_side_outside_to - transition.minor_side_outside_from;
        return transition.minor_side_outside_from + side_change * transition.fraction(now_seconds);
    }
};

// ---- The app's state ----

/// What a pointer plays: a note, by its degree, or a chord, by its index in the scale's chords - from the star, or a
/// note from the keyboard - or the chord it holds on the chooser, at half strength (`HoldLayer.thumb`).
const PlayTarget = union(enum) {
    /// A note of the star, its proxy, a key or a note on the circle: its degree, held at full strength.
    note: u8,
    /// A chord of the star: its index, the tonic's 0, its three notes held at full strength.
    chord: u8,
    /// A chord of the chooser or of the key's window: its index, held at the thumb's strength, and chosen.
    chooser_chord: u8,
    /// A borrowed chord's small button beside its root's chord (`offeredBorrowedChords`): the chord itself, its root
    /// and its quality - held at the thumb's strength, the scale sounding altered for it while it is held.
    borrowed_chord: ScaleChord,
    /// A finger that began on the dropdowns, or while a dropdown's list was open: it belongs to them until it lifts,
    /// and plays nothing - the finger that picks an item from a list is still down after the list has closed, over
    /// whatever lay beneath it.
    ignored: void,
};

/// The two ways a note is held, which sound at two strengths: by the left thumb holding a chord on the chooser, at
/// half strength, and by everything else - a finger on the star or the keyboard, a digit - at full strength.
const HoldLayer = enum { thumb, full };

/// How many things hold a degree's note, in each of the two ways (`HoldLayer`).
const DegreeHolds = struct {
    /// Holds at the thumb's strength: a chooser's chord, a borrowed one.
    thumb: u8 = 0,
    /// Holds at full strength: everything else.
    full: u8 = 0,
};

/// How a degree's note sounds now: not at all, at the thumb's half strength, or at full strength - full as soon as
/// anything holds it fully, whatever the thumb does.
const NoteStrength = enum { silent, thumb, full };

/// A pointer holding a target: a finger, by the identifier the platform gives it for as long as it touches - the
/// same from frame to frame, wherever it moves - or the mouse.
const PointerHold = struct {
    /// The pointer holding: a touch's identifier, or the mouse's (`mouse_pointer_id`).
    pointer_id: i32,
    /// What it holds.
    target: PlayTarget,
    /// Where the pointer stood when it took its target - null when it may take a new one at once, as when the star
    /// has just turned under it (`readPointers`).
    anchor: ?Vec2,
};

/// A chord's third or fifth not yet sounding: held by its chord already, it starts at `due_seconds`, a strum's delay
/// after the root - the third one delay after it, the fifth two - so that the chord is heard note by note, root,
/// third, fifth, and then together (`holdChordDegrees`).
const PendingHold = struct {
    /// The note waiting.
    degree: u8,
    /// The strength it will be held at.
    layer: HoldLayer,
    /// When it starts, on the frame's clock.
    due_seconds: f32,
};

/// The mouse's identifier among the pointers: one no touch is given, touches being numbered up from 0.
const mouse_pointer_id: i32 = -1;

/// A pointer down this frame: its identifier and where it is.
const PointerDown = struct {
    /// Its identifier: a touch's, or the mouse's.
    pointer_id: i32,
    /// Where it is, in the window's logical pixels.
    position: Vec2,
};

/// A chord a finger carries toward the progression editor's boxes (`readPointers`): the chord it came down on - on the
/// star, the chooser, the key's window, a borrowed chord's button or a box - where it came down, and where it is now.
/// Lifted over a box, the box takes the chord (`dropChord`).
const ChordDrag = struct {
    pointer_id: i32,
    chord: ScaleChord,
    start: Vec2,
    position: Vec2,

    /// Whether the finger has gone from where it came down (`params.playing.chord_drag_start_distance`).
    fn hasLeftStart(drag: ChordDrag) bool {
        return length(drag.position - drag.start) > params.playing.chord_drag_start_distance;
    }
};

/// Everything the app keeps from one frame to the next: the font and the UI; the scale - the chosen one, and the one
/// sounding, which a borrowed chord alters; the window's layout; what every pointer holds and how often each note
/// is held; the pedals; the progression track; the star's move; and the options' choices.
const State = struct {
    /// The font every text is drawn in (`atkinson_mono_ttf`).
    font: z.Font,
    /// The engine's UI: the options' button at the top left and the panel it opens (`buildOptions`).
    ui_host: z.UiHost,
    /// For each degree, how many things hold its note down, in each of the two ways (`DegreeHolds`): its digit, each
    /// finger on the note, each finger on a chord that contains it - and the thumb's chord on the chooser. The note
    /// sounds once however many hold it, at the strength the holds call for (`strengthOfDegree`), and stops only
    /// when all let go.
    holds: [7]DegreeHolds,
    /// Which degrees their keys hold, so that a key's release is matched with its press.
    is_held_by_digit_key: [7]bool,
    /// What each pointer holds, while it is down: a slot each, free when null.
    pointer_holds: [params.limits.most_pointers]?PointerHold,
    /// The window's layout last worked out, and the window's size it was worked out for (`windowLayoutOf`).
    window_layout: ?WindowLayout,
    /// The window's size the kept layout was made for (`window_layout`).
    layout_window_size: Vec2,
    /// The header's text's right edge the kept layout was made for (`header_content_right`).
    layout_header_content_right: f32,
    /// The scale chosen in the options: its tonic and its mode, and all that follows from them (`Scale`). The window's
    /// layout follows it - where each chord and note stands, its shape and its side.
    chosen_scale: Scale,
    /// The scale sounding: the chosen one, with any alterations a borrowed chord held asks for (`applyAlterations`) -
    /// what is played and named.
    scale: Scale,
    /// The two pedals (`Pedal`): one on the chosen chord's root, one on the scale's tonic (`updatePedals`).
    root_pedal: Pedal,
    /// The pedal on the scale's tonic.
    tonic_pedal: Pedal,
    /// Whether the options' panel is open over the page (`buildOptions`).
    is_options_open: bool,
    /// The progression whose track the chooser shows, as its place in the options' list: 0 none, the chooser's star
    /// shown instead; 1 the first of `progressions` (`drawProgressionTrack`).
    progression_choice: i32,
    /// The progression editor's boxes (`drawProgressionEditor`): the chord each holds, null for an empty box. The track
    /// plays the boxes that hold a chord, in order, over and over (`trackChord`). A progression picked in the list
    /// fills them (`placeChosenProgression`); a chord dragged onto a box replaces its own (`dropChord`).
    progression_boxes: [params.limits.progression_box_most]?ScaleChord,
    /// The options' choice of how many boxes the editor shows: an index into `params.progression.box_counts`, set to
    /// fit a progression picked in the list (`placeChosenProgression`) and the player's to change after.
    progression_box_count_choice: i32,
    /// The chords being carried toward the boxes, one a finger at most (`ChordDrag`).
    chord_drags: [params.limits.most_pointers]?ChordDrag,
    /// The pointers down last frame, by their identifiers: a pointer not among them came down this frame - only such a
    /// pointer picks up a chord to carry, not a finger gliding onto one.
    pointer_ids_last_frame: [params.limits.most_pointers]?i32,
    /// The progression's tempo, in beats a minute, set in the options.
    progression_beats_per_minute: f32,
    /// The beats gone since the progression was chosen, counted at its tempo frame by frame (`advanceProgression`).
    progression_beat: f64,
    /// Whether the track follows the player, set in the options and on at the start: the chord on its way waits at its
    /// button until the player plays it, and one played before it arrives starts at once (`takeProgressionChord`) - so
    /// that the track can follow music it is not in time with, the player keeping that music's time.
    progression_waits_for_player: bool,
    /// Following the player, the track's chords played so far, in order from its first: the next awaited is this one.
    progression_chords_taken: usize,
    /// Whether the track chooses its chords itself, set in the options: each chosen as it falls due, the star turning
    /// to it, without a sound (`playProgressionChords`) - so that the player can play the melody on the star while
    /// the star follows the song.
    progression_plays_chords: bool,
    /// The track's chords it has chosen so far, counted from its first - the last is the one chosen now; 0 for none.
    progression_played_chord_count: usize,
    /// Whether the scale sounding is altered by a borrowed chord the track chose (`playProgressionChords`), for it to
    /// put back when the next chord is the scale's own.
    has_track_altered_scale: bool,
    /// Where the header's text ends, in window pixels - the options button and the scale's name - as last drawn
    /// (`buildOptionsButton`); 0 before it is.
    header_content_right: f32,
    /// Whether the star turns to the chord chosen, set in the options, off at the start (`starAimFor`): off, it stays
    /// at rest, the tonic chord's notes along its bottom line, whatever is chosen.
    turns_star: bool,
    /// Whether the star's notes show their solfege syllables beside their letters, set in the options: off at the
    /// start (`drawNote`).
    shows_solfege: bool,
    /// The chords' thirds and fifths waiting to start, a strum's delay after their roots (`PendingHold`).
    pending_holds: [params.limits.most_pending_holds]?PendingHold,
    /// The delay between a chord's notes as it starts - the root, the third this long after it, the fifth this long
    /// after the third (`holdChordDegrees`) - set in the options, from `params.defaults.chord_strum_seconds`; 0 starts
    /// the three at once.
    chord_strum_seconds: f32,
    /// The options' list of progressions, its labels written in the current key (`writeProgressionLabels`).
    progression_label_buffers: [progressions.len + 1][params.limits.progression_label_capacity]u8,
    /// The track dropdown's labels, written once at the start: "off", then each progression's name, numbers and
    /// chords in the chosen key (`writeProgressionLabels`).
    progression_labels: [progressions.len + 1][]const u8,
    /// The header's mode list, its labels written each frame for the tonic chosen (`writeModeLabels`): each mode's
    /// name and the notes it alters from the major scale, then its seven chords on the tonic.
    mode_label_buffers: [mode_count][params.limits.mode_label_capacity]u8,
    mode_labels: [mode_count][]const u8,
    /// Whether one of the header's lists was open at the last frame (`buildHeader`): a press then is the list's, which
    /// only the frame's UI knows, so that `onInput` leaves the pointers to the frame.
    is_header_list_open: bool,
    /// Whether the page's JavaScript handles are being debugged (`z.audio_device.setHandleDebugging`).
    is_debugging_handles: bool,
    /// The chord the thumb holds on the chooser, as a share of the other notes' strength (`soundStrengthChange`).
    chooser_chord_volume: f32,
    /// Whether the sound's diagnostics are shown: on a page, the engine's panel at the top - the path to the speaker,
    /// how often the output ran dry, the mixer's margin - for finding what a glitch was.
    is_showing_audio_stats: bool,
    /// The chord the left hand chose, by its index in the scale's chords - I to begin with - and the star's move to it.
    chosen_chord_index: u8,
    /// The star's move toward where it stands for the chord chosen (`aimStar`).
    transition: StarTransition,
    /// Whether the star was turning at the last frame's reading of the pointers (`readPointers`).
    was_star_moving: bool,
    /// Whether the screen has reported a touch. A browser also turns a touch into the mouse's press and movement,
    /// so that pages written for a mouse work on a phone; once a touch has been seen, the mouse is ignored, and each
    /// finger counts once, as itself.
    has_seen_touch: bool,
};

/// The app's start: its font and its UI, nothing held, C major with I chosen; the sound started, with the Shepard
/// instrument.
fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 32);
    s.* = .{
        .font = font,
        .ui_host = z.UiHost.init(gpa, font),
        .holds = @splat(.{}),
        .is_held_by_digit_key = @splat(false),
        .pointer_holds = @splat(null),
        .window_layout = null,
        .layout_window_size = .{ 0, 0 },
        .layout_header_content_right = 0,
        .chosen_scale = c_major,
        .scale = c_major,
        .root_pedal = .{},
        .tonic_pedal = .{},
        .is_showing_audio_stats = false,
        .is_options_open = false,
        .progression_choice = 0,
        .progression_boxes = @splat(null),
        .progression_box_count_choice = params.defaults.progression_box_count_choice,
        .chord_drags = @splat(null),
        .pointer_ids_last_frame = @splat(null),
        .progression_beats_per_minute = params.defaults.progression_beats_per_minute,
        .progression_beat = 0,
        .progression_waits_for_player = true,
        .progression_chords_taken = 0,
        .progression_plays_chords = false,
        .progression_played_chord_count = 0,
        .has_track_altered_scale = false,
        .header_content_right = 0,
        .turns_star = false,
        .shows_solfege = false,
        .pending_holds = @splat(null),
        .chord_strum_seconds = params.defaults.chord_strum_seconds,
        .progression_label_buffers = undefined,
        .progression_labels = @splat(""),
        .mode_label_buffers = undefined,
        .mode_labels = @splat(""),
        .is_header_list_open = false,
        .is_debugging_handles = false,
        .chooser_chord_volume = params.defaults.chooser_chord_volume,
        .chosen_chord_index = 0,
        .transition = .atRestOnTonic(c_major.chordOf(1)),
        .was_star_moving = false,
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

// ---- Playing ----

/// How a degree's note sounds by its holds: full if anything holds it fully, the thumb's half if only the thumb's
/// chord does, silent if nothing does.
fn strengthOfDegree(s: *const State, degree: u8) NoteStrength {
    const degree_holds: DegreeHolds = s.holds[degree - 1];
    if (degree_holds.full > 0) {
        return .full;
    }
    return if (degree_holds.thumb > 0) .thumb else .silent;
}

/// Makes a degree's note sound at its new strength: released if it falls silent, struck again at the new strength if
/// that changes - the instrument lets a held note go when its key is struck again, so the note sounds once at its new
/// strength. So a note the thumb's chord holds softly is struck again fully when the right hand presses it too, and
/// struck again softly when the right hand lets it go - the full note fading out beneath, as released notes do.
fn soundStrengthChange(
    f: *z.Frame,
    s: *const State,
    degree: u8,
    before: NoteStrength,
    after: NoteStrength,
) void {
    if (before == after) {
        return;
    }
    // From full to the thumb's strength - the right hand lifting a note the chord still holds - the note rings on as it
    // is, as a piano's string rings on while another finger keeps its key down: striking it again, softer, would put
    // a new attack where a finger was lifted.
    if (before == .full and after == .thumb) {
        return;
    }
    const key: u8 = s.scale.midiKeyOfDegree(degree);
    // The thumb's strength, from its volume in the options: a share of the other notes'.
    const thumb_velocity: f32 = s.chooser_chord_volume * params.playing.note_velocity;
    switch (after) {
        .silent => _ = f.mixer.sendNote(.{ .key = key, .is_down = false }),
        .thumb => _ = f.mixer.sendNote(.{ .key = key, .is_down = true, .velocity = thumb_velocity }),
        .full => _ = f.mixer.sendNote(.{ .key = key, .is_down = true, .velocity = params.playing.note_velocity }),
    }
}

/// One more hold on a degree's note, in `layer`: the note starts, or sounds more strongly, if that changes how it
/// sounds (`soundStrengthChange`).
fn holdDegree(f: *z.Frame, s: *State, degree: u8, layer: HoldLayer) void {
    const before: NoteStrength = strengthOfDegree(s, degree);
    const degree_holds: *DegreeHolds = &s.holds[degree - 1];
    switch (layer) {
        .thumb => degree_holds.thumb += 1,
        .full => degree_holds.full += 1,
    }
    soundStrengthChange(f, s, degree, before, strengthOfDegree(s, degree));
}

/// One hold fewer on a degree's note, in `layer`: the note stops, or sounds more softly, if that changes how it
/// sounds.
fn releaseDegree(f: *z.Frame, s: *State, degree: u8, layer: HoldLayer) void {
    const before: NoteStrength = strengthOfDegree(s, degree);
    const degree_holds: *DegreeHolds = &s.holds[degree - 1];
    switch (layer) {
        .thumb => {
            assert(degree_holds.thumb > 0, @src());
            degree_holds.thumb -= 1;
        },
        .full => {
            assert(degree_holds.full > 0, @src());
            degree_holds.full -= 1;
        },
    }
    soundStrengthChange(f, s, degree, before, strengthOfDegree(s, degree));
}

/// Whether a degree's note sounds: something holds it, at either strength.
fn isDegreeSounding(s: *const State, degree: u8) bool {
    return strengthOfDegree(s, degree) != .silent;
}

/// Alters the scale sounding by `alterations` (`Scale.altered`) - those a borrowed chord held asks for, or none -
/// from the chosen scale. The layout stays as it is: only pitches and names change. A note held whose pitch moves is
/// let go and struck again at its new pitch, at the strength it is held at, so that what sounds is what is shown.
fn applyAlterations(f: *z.Frame, s: *State, alterations: [7]i8) void {
    const before: Scale = s.scale;
    const after: Scale = s.chosen_scale.altered(alterations);
    var is_moved: [7]bool = @splat(false);
    for (all_degrees) |degree| {
        const old_key: u8 = before.midiKeyOfDegree(degree);
        const new_key: u8 = after.midiKeyOfDegree(degree);
        const is_sounding: bool = isDegreeSounding(s, degree);
        if (old_key != new_key and is_sounding) {
            _ = f.mixer.sendNote(.{ .key = old_key, .is_down = false });
            is_moved[degree - 1] = true;
        }
    }
    s.scale = after;
    for (all_degrees, is_moved) |degree, was_moved| {
        if (was_moved) {
            soundStrengthChange(f, s, degree, .silent, strengthOfDegree(s, degree));
        }
    }
}

/// A borrowed chord a pointer holds other than `chord`; null when every one held is `chord`.
fn otherHeldBorrowedChord(s: *const State, chord: ScaleChord) ?ScaleChord {
    for (s.pointer_holds) |hold_slot| {
        const hold: PointerHold = hold_slot orelse continue;
        switch (hold.target) {
            .borrowed_chord => |held_chord| {
                if (held_chord.root_degree != chord.root_degree or held_chord.quality != chord.quality) {
                    return held_chord;
                }
            },
            .note, .chord, .chooser_chord, .ignored => {},
        }
    }
    return null;
}

/// How many pointers hold a borrowed chord.
fn borrowedChordHoldCount(s: *const State) usize {
    var count: usize = 0;
    for (s.pointer_holds) |hold_slot| {
        const hold: PointerHold = hold_slot orelse continue;
        if (hold.target == .borrowed_chord) {
            count += 1;
        }
    }
    return count;
}

/// A free slot for a waiting note, or null when all are taken.
fn freePendingSlot(s: *State) ?*?PendingHold {
    for (&s.pending_holds) |*pending_slot| {
        if (pending_slot.* == null) {
            return pending_slot;
        }
    }
    return null;
}

/// Holds a chord's three notes in `layer`, one after another: the root now, the third `chord_strum_seconds` later,
/// the fifth twice that - each waiting (`PendingHold`) until it starts (`startDueHolds`). All at once with a strum of
/// 0, and any note at once that finds no slot to wait in.
fn holdChordDegrees(f: *z.Frame, s: *State, degrees: [3]u8, layer: HoldLayer) void {
    const now_seconds: f32 = f.time.time;
    for (degrees, 0..) |degree, part_index| {
        const delay_seconds: f32 = float(part_index) * s.chord_strum_seconds;
        if (delay_seconds <= 0) {
            holdDegree(f, s, degree, layer);
            continue;
        }
        const pending_slot: *?PendingHold = freePendingSlot(s) orelse {
            holdDegree(f, s, degree, layer);
            continue;
        };
        pending_slot.* = .{ .degree = degree, .layer = layer, .due_seconds = now_seconds + delay_seconds };
    }
}

/// Removes one waiting note of `degree` in `layer`, if there is one: whether there was.
fn takePendingHold(s: *State, degree: u8, layer: HoldLayer) bool {
    for (&s.pending_holds) |*pending_slot| {
        const pending: PendingHold = pending_slot.* orelse continue;
        if (pending.degree == degree and pending.layer == layer) {
            pending_slot.* = null;
            return true;
        }
    }
    return false;
}

/// Lets go of a chord's three notes in `layer` (`holdChordDegrees`): a note still waiting stops waiting, never
/// started; a note sounding is let go. Notes wait and sound by degree and layer, as they are counted (`DegreeHolds`),
/// so a waiting note of another chord taken instead keeps the counts as they should be: that note starts now rather
/// than later, and this one's hold, left, is the one the other chord's release lets go.
fn releaseChordDegrees(f: *z.Frame, s: *State, degrees: [3]u8, layer: HoldLayer) void {
    for (degrees) |degree| {
        if (takePendingHold(s, degree, layer)) {
            continue;
        }
        releaseDegree(f, s, degree, layer);
    }
}

/// Starts every waiting note whose time has come (`PendingHold`): called once a frame, so that a note starts within a
/// frame of its time.
fn startDueHolds(f: *z.Frame, s: *State) void {
    const now_seconds: f32 = f.time.time;
    for (&s.pending_holds) |*pending_slot| {
        const pending: PendingHold = pending_slot.* orelse continue;
        if (pending.due_seconds <= now_seconds) {
            pending_slot.* = null;
            holdDegree(f, s, pending.degree, pending.layer);
        }
    }
}

/// Holds what a pointer plays: a note, or a chord's three notes, one after another (`holdChordDegrees`) - fully, or,
/// for a chord the thumb holds on the left hand's diagrams, at half strength.
fn holdTarget(f: *z.Frame, s: *State, target: PlayTarget) void {
    switch (target) {
        .note => |degree| holdDegree(f, s, degree, .full),
        .chord => |chord_index| holdChordDegrees(f, s, s.scale.chords[chord_index].degrees(), .full),
        .chooser_chord => |chord_index| holdChordDegrees(f, s, s.scale.chords[chord_index].degrees(), .thumb),
        .borrowed_chord => |chord| holdChordDegrees(f, s, chord.degrees(), .thumb),
        .ignored => {},
    }
}

/// Lets go of what a pointer played (`holdTarget`).
fn releaseTarget(f: *z.Frame, s: *State, target: PlayTarget) void {
    switch (target) {
        .note => |degree| releaseDegree(f, s, degree, .full),
        .chord => |chord_index| releaseChordDegrees(f, s, s.scale.chords[chord_index].degrees(), .full),
        .chooser_chord => |chord_index| releaseChordDegrees(f, s, s.scale.chords[chord_index].degrees(), .thumb),
        .borrowed_chord => |chord| {
            releaseChordDegrees(f, s, chord.degrees(), .thumb);
            // The scale back as chosen when no other borrowed chord is held - the hold let go of is still in its slot
            // as it is released, so one found is this one - or as another still held asks. Two fingers on the same
            // chord leave its alterations as they are.
            if (borrowedChordHoldCount(s) <= 1) {
                applyAlterations(f, s, @splat(0));
            } else if (otherHeldBorrowedChord(s, chord)) |other_chord| {
                applyAlterations(f, s, s.chosen_scale.alterationsForChord(other_chord));
            }
        },
        .ignored => {},
    }
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

// ---- Reading the input ----

/// The digit keys: a degree's digit or keypad key down holds its note; once neither is down any more, the note is let
/// go. A key still down when the scale changes, which lets go of every note (`changeScale`), holds its note again the
/// next frame, in the new scale.
fn readDigitKeys(f: *z.Frame, s: *State) void {
    for (params.playing.digit_keys, params.playing.keypad_keys, 0..) |digit_key, keypad_key, degree_index| {
        const degree: u8 = @intCast(degree_index + 1);
        const is_down: bool = z.isKeyDown(f.input, digit_key) or z.isKeyDown(f.input, keypad_key);
        if (is_down and !s.is_held_by_digit_key[degree_index]) {
            s.is_held_by_digit_key[degree_index] = true;
            holdDegree(f, s, degree, .full);
        } else if (s.is_held_by_digit_key[degree_index] and !is_down) {
            s.is_held_by_digit_key[degree_index] = false;
            releaseDegree(f, s, degree, .full);
        }
    }
}

/// A chord on the star as three of its notes overlapping, a little triplet (`drawChord`): in front, at the left, the
/// chord's own shape - a square for a major chord, a circle for the others - in its root's color, which carries its
/// numeral; behind it, a third of its width to the right, its third, in that note's shape and color; behind that, as
/// far again, its fifth. Each one behind is two thirds hidden by the one before it, and all three are the chord's
/// size. The three together are centred where the chord stands (`StarLayout.chordCentre`) - the third there, the root
/// a step to its left, the fifth a step to its right - so that the triplet takes the single button's place, and a
/// touch anywhere on it plays the chord (`nearestTarget`).
const ChordTriplet = struct {
    /// The root's, the third's and the fifth's: their degrees, their centres and their shapes - the root's the
    /// chord's own - front first; all three at `half_size`.
    degrees: [3]u8,
    /// Each shape's centre: the root's, the third's, the fifth's.
    centres: [3]Vec2,
    /// Each shape: the chord's own in front, then the third's and the fifth's notes'.
    shapes: [3]Shape,
    /// The chord's half-size, all three's.
    half_size: f32,

    /// `chord`'s triplet on `star` (`StarLayout.chordTripletShapes`).
    fn ofChord(star: StarLayout, chord: ScaleChord) ChordTriplet {
        const placed_shapes: [3]PlacedShape = star.chordTripletShapes(chord);
        var triplet: ChordTriplet = .{
            .degrees = chord.degrees(),
            .centres = undefined,
            .shapes = undefined,
            .half_size = star.chordHalfSize(chord),
        };
        for (placed_shapes, &triplet.centres, &triplet.shapes) |placed_shape, *centre, *shape| {
            centre.* = placed_shape.centre;
            shape.* = placed_shape.shape;
        }
        return triplet;
    }

    /// How far `point` is from the nearest of the three shapes: 0 inside any of them.
    fn distanceTo(triplet: ChordTriplet, point: Vec2) f32 {
        var nearest_distance: f32 = inf(f32);
        for (triplet.centres, triplet.shapes) |centre, shape| {
            nearest_distance = @min(nearest_distance, distanceToShape(point, centre, shape, triplet.half_size));
        }
        return nearest_distance;
    }
};

/// The note or chord nearest `point`, by the distance to its shape: every point of the window belongs to one, so that a
/// press anywhere plays - the window is divided among the fourteen targets, each taking the points nearer to it than
/// to any other. A point inside a shape is at distance 0 from it, and so belongs to it.
fn nearestTarget(star: StarLayout, point: Vec2) PlayTarget {
    var nearest: PlayTarget = .{ .note = 1 };
    var nearest_distance: f32 = inf(f32);
    for (all_degrees) |degree| {
        const note_centre: Vec2 = star.noteCentre(degree);
        const note_shape: Shape = shapeOfDegree(&star.scale, degree);
        const note_distance: f32 = distanceToShape(point, note_centre, note_shape, star.noteHalfSize(degree));
        if (note_distance < nearest_distance) {
            nearest = .{ .note = degree };
            nearest_distance = note_distance;
        }
    }
    for (star.scale.chords, 0..) |chord, chord_index| {
        const chord_distance: f32 = ChordTriplet.ofChord(star, chord).distanceTo(point);
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
    pointers: *[params.limits.most_pointers]PointerDown,
) []const PointerDown {
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

/// The star turned by `turns`, with its chords' sides at `minor_side_outside_fraction`, and the chosen chord's notes as
/// heroes.
fn starForChoice(
    window_layout: WindowLayout,
    s: *const State,
    turns: f32,
    minor_side_outside_fraction: f32,
) StarLayout {
    var star: StarLayout = window_layout.star.turnedBy(turns);
    star.hero_root_place = circlePlaceOfDegree(s.scale.chords[s.chosen_chord_index].root_degree);
    star.minor_side_outside_fraction = minor_side_outside_fraction;
    return star;
}

/// Where the star stands: its turn, and how far its minor side is out (`StarTransition`).
const StarAim = struct {
    /// Its turn, in turns.
    turn: f32,
    /// How far its minor side is out: 0 the major chords outside, 1 the minor side's.
    minor_side_outside: f32,
};

/// Where the star stands for the chord `chord_index` of `scale` chosen: at the chord's turn, its side outside, while
/// the star turns to the chord chosen (`turns_star`, set in the options); else at rest, at the tonic chord's - the
/// star the same whatever is chosen.
fn starAimFor(s: *const State, scale: *const Scale, chord_index: u8) StarAim {
    const aimed_chord_index: usize = if (s.turns_star) chord_index else 0;
    const aimed_chord: ScaleChord = scale.chords[aimed_chord_index];
    return .{
        .turn = starTurnForChord(aimed_chord),
        .minor_side_outside = if (aimed_chord.isMinorSide()) 1 else 0,
    };
}

/// Moves the star to `aim` from where it is shown now, even mid-move, the shorter way round - the aim's turn moved by
/// whole turns to within half a turn of the star's. A star already moving to the same place, or standing there, is
/// left to go on: a choice that leaves the star where it is starts no move, during which the fingers would find
/// nothing on it.
fn aimStar(f: *z.Frame, s: *State, aim: StarAim) void {
    const now_seconds: f32 = f.time.time;
    const shown_turn: f32 = s.transition.shownTurn(now_seconds);
    const shown_minor_side_outside: f32 = s.transition.shownMinorSideOutside(now_seconds);
    const nearest_turn: f32 = aim.turn + @round(shown_turn - aim.turn);
    const is_same_turn: bool = @abs(s.transition.turn_to - nearest_turn) < 1e-4;
    const is_same_side: bool = s.transition.minor_side_outside_to == aim.minor_side_outside;
    if (is_same_turn and is_same_side) {
        return;
    }
    s.transition = .{
        .started_seconds = now_seconds,
        .turn_from = shown_turn,
        .turn_to = nearest_turn,
        .minor_side_outside_from = shown_minor_side_outside,
        .minor_side_outside_to = aim.minor_side_outside,
    };
}

/// Chooses a chord: while the star turns to the chord chosen (`turns_star`), it starts turning toward the chord's turn
/// from where it is shown now, the shorter way round, and its chords start trading sides if the chosen chord's side is
/// not the one outside, so that the chosen chord ends outside, at the bottom, below its notes (`aimStar`); at rest, it
/// stays, and the chord's notes are outlined where they stand (`drawChordOutlines`). Choosing sounds nothing by itself;
/// the finger choosing holds the chord, at half strength (`targetAt`).
fn chooseChord(f: *z.Frame, s: *State, chord_index: u8) void {
    if (chord_index == s.chosen_chord_index) {
        return;
    }
    s.chosen_chord_index = chord_index;
    aimStar(f, s, starAimFor(s, &s.scale, chord_index));
}

/// Changes the scale played to `scale`. Every note is let go first, in the old scale - its keys are the old scale's -
/// except what the dropdowns' fingers hold, which is nothing; a finger or a digit key still down sounds again, in the
/// new scale, the next frame. The layouts are made again, the chords' qualities deciding their sides, shapes and
/// sizes. The chosen chord stays the same degree; if its side changed - a major chord now minor - the chords trade
/// sides over a move like a choice's, during which the star plays nothing.
fn changeScale(f: *z.Frame, s: *State, scale: Scale) void {
    for (&s.pointer_holds) |*hold_slot| {
        const hold: PointerHold = hold_slot.* orelse continue;
        if (hold.target == .ignored) {
            continue;
        }
        releaseTarget(f, s, hold.target);
        hold_slot.* = null;
    }
    for (&s.is_held_by_digit_key, all_degrees) |*is_held, degree| {
        if (is_held.*) {
            is_held.* = false;
            releaseDegree(f, s, degree, .full);
        }
    }
    s.chosen_scale = scale;
    s.scale = scale;
    s.window_layout = null;
    aimStar(f, s, starAimFor(s, &scale, s.chosen_chord_index));
}

/// Keeps the pedals as their checkboxes, the chosen chord and the scale want them: the root pedal on the chosen
/// chord's root, the tonic pedal on the scale's tonic - each while its box is ticked, silent otherwise (`Pedal.keep`).
fn updatePedals(f: *z.Frame, s: *State) void {
    const chosen_root: u8 = s.scale.chords[s.chosen_chord_index].root_degree;
    const root_pitch_class: ?u4 = if (s.root_pedal.volume > 0) s.scale.pitchClassOfDegree(chosen_root) else null;
    const tonic_pitch_class: ?u4 = if (s.tonic_pedal.volume > 0) s.scale.pitchClassOfDegree(1) else null;
    s.root_pedal.keep(f, root_pitch_class);
    s.tonic_pedal.keep(f, tonic_pitch_class);
}

/// A tonic the key dropdown lists: its letter, C as 0 to B as 6, and its accidental, 1 for a sharp.
const ListedTonic = struct {
    /// The letter, C as 0 to B as 6.
    letter: u8,
    /// The accidental: 0 natural, 1 sharp.
    accidental: i8,
};

/// The tonics the key dropdown lists, the twelve from A, each natural followed by its sharp where it has one: A, A#,
/// B, C, C#, D, D#, E, F, F#, G, G#.
const listed_tonics = [12]ListedTonic{
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
const listed_tonic_names = [12][]const u8{ "A", "A#", "B", "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#" };

/// The tonic a song's key is played in (`SongKey.ionian_tonic`), where the options offer it: the twelve listed; null
/// for any other spelling.
fn songKeyTonic(original_key: SongKey) ?ListedTonic {
    for (listed_tonic_names, listed_tonics) |tonic_name, tonic| {
        if (eql(u8, tonic_name, original_key.ionian_tonic)) {
            return tonic;
        }
    }
    return null;
}
/// The modes' names as the mode dropdown lists them, in the order of `Mode`'s values.
const listed_mode_names = [11][]const u8{
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
fn writeAlterations(buffer: []u8, mode: Mode) []const u8 {
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

/// Writes the header's mode list for the tonic chosen (`State.mode_labels`), each label two lines: the mode's name
/// with the notes it alters from the major scale at the right (`writeAlterations`), then its seven chords on that
/// tonic - C Dorian's are Cm, Dm, Eb, F, Gm, A diminished and Bb.
fn writeModeLabels(s: *State) void {
    for (&s.mode_label_buffers, &s.mode_labels, 0..) |*buffer, *label, mode_index| {
        const mode: Mode = @fromBackingInt(@intCast(mode_index));
        const scale: Scale = .ofTonic(s.chosen_scale.tonic_letter, s.chosen_scale.tonic_accidental, mode);
        var alteration_buffer: [32]u8 = undefined;
        const alterations: []const u8 = writeAlterations(&alteration_buffer, mode);
        const name: []const u8 = listed_mode_names[mode_index];
        const gap: usize = @max(2, params.limits.mode_label_columns -| (name.len + alterations.len));
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
        label.* = buffer[0..label_length];
    }
}

comptime {
    // Every scale on every listed tonic spells each degree with its own letter and at most two accidentals - the
    // speller's double flat to double sharp - and on a natural tonic at most one: the new scales' raised and lowered
    // notes need no double sharp there.
    @setEvalBranchQuota(40_000);
    for (listed_tonics) |tonic| {
        for (std.enums.values(Mode)) |mode| {
            const semitones: [7]u8 = mode.semitonesAboveTonic();
            for (semitones, 0..) |semitone, degree_index| {
                const letter: usize = (tonic.letter + degree_index) % 7;
                const tonic_pitch_class: i16 = @as(i16, natural_semitones[tonic.letter]) + tonic.accidental;
                const natural_offset: i16 = @as(i16, natural_semitones[letter]) - tonic_pitch_class;
                const accidental: i16 = @mod(@as(i16, semitone) - natural_offset + 6, 12) - 6;
                const most_accidental: i16 = if (tonic.accidental == 0) 1 else 2;
                if (accidental < -most_accidental or accidental > most_accidental) {
                    @compileError("a scale's degree needs more accidentals than the speller has: " ++ mode.label());
                }
            }
        }
    }
}

comptime {
    // The alterations borrowed chords ask for, checked when compiling: in C major, III raises 5 (G sharp), II raises 4
    // (F sharp), iv lowers 6 (A flat), the scale's own I asks nothing; in A Aeolian, V raises 7 (G sharp).
    const a_aeolian: Scale = .of(5, .aeolian);
    const checks = [_]struct { scale: Scale, chord: ScaleChord, alterations: [7]i8 }{
        .{
            .scale = c_major,
            .chord = .{ .root_degree = 3, .quality = .major },
            .alterations = .{ 0, 0, 0, 0, 1, 0, 0 },
        },
        .{
            .scale = c_major,
            .chord = .{ .root_degree = 2, .quality = .major },
            .alterations = .{ 0, 0, 0, 1, 0, 0, 0 },
        },
        .{
            .scale = c_major,
            .chord = .{ .root_degree = 4, .quality = .minor },
            .alterations = .{ 0, 0, 0, 0, 0, -1, 0 },
        },
        .{ .scale = c_major, .chord = .{ .root_degree = 1, .quality = .major }, .alterations = @splat(0) },
        .{
            .scale = a_aeolian,
            .chord = .{ .root_degree = 5, .quality = .major },
            .alterations = .{ 0, 0, 0, 0, 0, 0, 1 },
        },
    };
    for (checks) |check| {
        const alterations: [7]i8 = check.scale.alterationsForChord(check.chord);
        for (alterations, check.alterations) |found, expected| {
            if (found != expected) {
                @compileError("a borrowed chord's alterations are not the ones expected");
            }
        }
        // Altered, the scale's chord on the root is the borrowed chord.
        const altered_scale: Scale = check.scale.altered(alterations);
        if (altered_scale.chords[check.chord.root_degree - 1].quality != check.chord.quality) {
            @compileError("the altered scale's chord is not the borrowed chord");
        }
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

/// The header at the top left, in a window without title, border or background: the button that opens and closes the
/// options, then the scale chosen right there - the tonic's dropdown, and the mode's, whose list shows each mode in
/// two lines, its name with the notes it alters from the major scale, then its seven chords on the tonic
/// (`writeModeLabels`). As wide as they are (`header_content_right`, last frame's), so that the star can reach to the
/// window's top beside it (`WindowParts.ofWindow`). A scale picked in either list is taken at once (`changeScale`).
fn buildHeader(f: *z.Frame, s: *State, ui: z.ui_real.Ui) void {
    const content_width: f32 = s.header_content_right - StarLayout.margin;
    const toolbar_width: f32 = if (s.header_content_right > 0) content_width + params.window.header_padding else 360;
    ui.setNextWindowPos(.{ StarLayout.margin, 2 }, .{});
    ui.setNextWindowSize(.{ toolbar_width, StarLayout.header_height }, .{});
    const toolbar_flags: z.ui_real.WindowFlags = .{
        .no_title_bar = true,
        .no_resize = true,
        .no_move = true,
        .no_background = true,
        .no_scrollbar = true,
    };
    if (ui.window("options button", .{ .flags = toolbar_flags })) |toolbar| {
        defer toolbar.close();
        if (ui.button("options", .{})) {
            s.is_options_open = !s.is_options_open;
        }
        ui.sameLine(.{});
        var picked_scale: Scale = s.chosen_scale;
        // The tonic's place in the list, A to G#, differs from its letter's number, C to B. Each dropdown's label is
        // hidden (`##`): the box shows the choice itself.
        var tonic_index: i32 = 0;
        for (listed_tonics, 0..) |tonic, listed_index| {
            if (tonic.letter == s.chosen_scale.tonic_letter and tonic.accidental == s.chosen_scale.tonic_accidental) {
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
            picked_scale = .ofTonic(picked_tonic.letter, picked_tonic.accidental, s.chosen_scale.mode);
        }
        ui.sameLine(.{});
        writeModeLabels(s);
        var mode_index: i32 = @backingInt(s.chosen_scale.mode);
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
        s.header_content_right = ui.getItemRectMax()[0];
        s.is_header_list_open = ui.isComboOpen();
        const is_new_tonic: bool = picked_scale.tonic_letter != s.chosen_scale.tonic_letter or
            picked_scale.tonic_accidental != s.chosen_scale.tonic_accidental;
        if (is_new_tonic or picked_scale.mode != s.chosen_scale.mode) {
            changeScale(f, s, picked_scale);
        }
    }
}

/// A chord's half-size in the left hand's column: its size in units times the chooser's unit, and a quarter larger
/// while chosen - the chooser's spacing leaves room for it beside its neighbours, even the two main chords side by
/// side (`ChooserLayout.ofRoom`).
fn columnChordHalfSize(chooser: ChooserLayout, chord: ScaleChord, is_chosen: bool) f32 {
    const chosen_scale: f32 = if (is_chosen) ChooserLayout.chosen_chord_scale else 1;
    return chosen_scale * chooser.chordHalfSize(chord);
}

/// How many boxes the editor shows: 2 to 16, as chosen in the options or fitted to a progression picked.
fn progressionBoxCount(s: *const State) usize {
    return params.progression.box_counts[@intCast(s.progression_box_count_choice)];
}

/// How many chords the track plays, over and over: the editor's boxes that hold one.
fn trackStepCount(s: *const State) usize {
    var step_count: usize = 0;
    for (s.progression_boxes[0..progressionBoxCount(s)]) |box| {
        step_count += @intFromBool(box != null);
    }
    return step_count;
}

/// Whether there is a track: a box holds a chord.
fn hasTrack(s: *const State) bool {
    return trackStepCount(s) > 0;
}

/// The box holding the track's chord at `step`, counted round and round the boxes that hold a chord, the empty ones
/// passed over: its index among the boxes. Only while there is a track (`hasTrack`).
fn trackBoxIndex(s: *const State, step: usize) usize {
    const step_in_round: usize = step % trackStepCount(s);
    var filled_seen: usize = 0;
    for (s.progression_boxes[0..progressionBoxCount(s)], 0..) |box, box_index| {
        if (box == null) {
            continue;
        }
        if (filled_seen == step_in_round) {
            return box_index;
        }
        filled_seen += 1;
    }
    // The step counted round the boxes holding a chord falls on one of them: the count is theirs.
    unreachable;
}

/// The track's chord at `step` (`trackBoxIndex`).
fn trackChord(s: *const State, step: usize) ScaleChord {
    return s.progression_boxes[trackBoxIndex(s, step)].?;
}

/// The box whose chord plays now - the chord that arrived last, a bar each - or null before the first has arrived,
/// and without a track.
fn playingBoxIndex(s: *const State) ?usize {
    if (!hasTrack(s)) {
        return null;
    }
    const chords_arrived: usize = @trunc(s.progression_beat / params.progression.beats_per_chord);
    if (chords_arrived == 0) {
        return null;
    }
    return trackBoxIndex(s, chords_arrived - 1);
}

/// The options' choice of the fewest boxes that hold `chord_count` chords (`params.progression.box_counts`): 3 for
/// three, 6 for five, the box after them empty; the most there are for a longer progression, which fills them.
fn boxCountChoiceFor(chord_count: usize) i32 {
    for (params.progression.box_counts, 0..) |box_count, choice| {
        if (box_count >= chord_count) {
            return @intCast(choice);
        }
    }
    return params.progression.box_counts.len - 1;
}

/// Places the progression picked in the list in the editor's boxes: as many boxes as it has chords, or the fewest
/// offered that hold them (`boxCountChoiceFor`), and its chords in order from the first, the boxes after them empty -
/// so the track plays it as it is, a three-chord one in three bars; with nothing picked, every box empty and their
/// number kept. Its chords are taken in the scale chosen now, after a song's key has been set.
fn placeChosenProgression(s: *State) void {
    s.progression_boxes = @splat(null);
    if (s.progression_choice <= 0) {
        return;
    }
    const progression: Progression = progressions[@intCast(s.progression_choice - 1)];
    s.progression_box_count_choice = boxCountChoiceFor(progression.degrees.len);
    const placed_count: usize = @min(progression.degrees.len, progressionBoxCount(s));
    for (s.progression_boxes[0..placed_count], 0..) |*box, step| {
        box.* = progressionChord(&s.chosen_scale, progression, step);
    }
}

/// The boxes shown since the editor grew from `box_count_before` boxes: those empty take the progression picked in the
/// list, where it reaches them - a song longer than four chords carries on into them. The boxes shown before keep what
/// they hold, edited or not; boxes hidden by fewer keep theirs too, out of the track, until shown again.
fn extendChosenProgression(s: *State, box_count_before: usize) void {
    if (s.progression_choice <= 0) {
        return;
    }
    const progression: Progression = progressions[@intCast(s.progression_choice - 1)];
    const box_count: usize = progressionBoxCount(s);
    for (box_count_before..box_count) |box_index| {
        const is_reached: bool = box_index < progression.degrees.len;
        if (s.progression_boxes[box_index] == null and is_reached) {
            s.progression_boxes[box_index] = progressionChord(&s.chosen_scale, progression, box_index);
        }
    }
}

/// The chord a finger on `target` plays, if a chord: a star's, a chooser's or the key's window's - the chosen scale's
/// chord - or a borrowed one.
fn chordOfTarget(s: *const State, target: PlayTarget) ?ScaleChord {
    return switch (target) {
        .chord => |chord_index| s.chosen_scale.chords[chord_index],
        .chooser_chord => |chord_index| s.chosen_scale.chords[chord_index],
        .borrowed_chord => |chord| chord,
        .note, .ignored => null,
    };
}

/// A finger lifted while carrying a chord (`ChordDrag`): over one of the editor's boxes, the box takes the chord, the
/// track playing it from its next turn; anywhere else, or never having left where it came down, nothing.
fn dropChord(s: *State, parts: WindowParts, drag: ChordDrag) void {
    if (!drag.hasLeftStart()) {
        return;
    }
    const box_index: usize = parts.editorBoxAt(progressionBoxCount(s), drag.position) orelse return;
    s.progression_boxes[box_index] = drag.chord;
}

/// The borrowed chords offered to play: those the editor's boxes hold from outside the chosen scale - a progression's
/// borrowings (`Progression.borrowings`), or a borrowed chord dragged into a box - each once, at most four, written
/// into `buffer`. A box's chord the chosen scale has itself on that root is not offered: its own button plays it.
fn offeredBorrowedChords(
    s: *const State,
    buffer: *[params.limits.most_offered_borrowed_chords]ScaleChord,
) []const ScaleChord {
    var count: usize = 0;
    for (s.progression_boxes[0..progressionBoxCount(s)]) |box| {
        const chord: ScaleChord = box orelse continue;
        const is_scale_own: bool = s.chosen_scale.chords[chord.root_degree - 1].quality == chord.quality;
        var is_offered_already: bool = false;
        for (buffer[0..count]) |offered| {
            if (offered.root_degree == chord.root_degree and offered.quality == chord.quality) {
                is_offered_already = true;
            }
        }
        if (!is_scale_own and !is_offered_already and count < buffer.len) {
            buffer[count] = chord;
            count += 1;
        }
    }
    return buffer[0..count];
}

/// A button's place on a diagram: its centre and its half-size.
const ButtonPlace = struct {
    /// Where its centre is.
    centre: Vec2,
    /// Its half-size: the half-side of a square, or a circle's radius.
    half_size: f32,
};

/// Where a borrowed chord's button sits beside its root's chord: at `root_centre`, of half-size `root_half_size`,
/// on the side toward `middle` - the diagram's middle, where there is room - just clear of the root's button.
fn borrowedButtonCentre(root_centre: Vec2, root_half_size: f32, middle: Vec2) Vec2 {
    const toward_middle: Vec2 = middle - root_centre;
    const distance_to_middle: f32 = length(toward_middle);
    const direction: Vec2 = if (distance_to_middle > 0)
        toward_middle / splat2(distance_to_middle)
    else
        .{ 0, -1 };
    const clearance: f32 = 1.1 * root_half_size * (1 + params.window.borrowed_button_share);
    return root_centre + direction * splat2(clearance);
}

/// A borrowed chord's button on the chooser: its centre and half-size, beside the chooser's chord on its root.
fn chooserBorrowedButton(chooser: ChooserLayout, chord: ScaleChord) ButtonPlace {
    const root_chord: ScaleChord = chooser.scale.chords[chord.root_degree - 1];
    const root_half_size: f32 = columnChordHalfSize(chooser, root_chord, false);
    const root_centre: Vec2 = chooser.chordCentre(root_chord);
    return .{
        .centre = borrowedButtonCentre(root_centre, root_half_size, chooser.centre),
        .half_size = params.window.borrowed_button_share * root_half_size,
    };
}

/// A borrowed chord's button on the key's window: at the top right corner of the shape of the window's chord on its
/// root, a third of its half-size.
fn fifthsBorrowedButton(fifths: FifthsLayout, chord: ScaleChord) ButtonPlace {
    const half_size: f32 = fifths.shapeHalfSize();
    const root_centre: Vec2 = fifths.cellCentre(FifthsLayout.cellOfDegree(chord.root_degree));
    return .{
        .centre = root_centre + Vec2{ half_size, -half_size },
        .half_size = 0.33 * half_size,
    };
}

/// Whether a pointer holds the borrowed chord `chord` (`PlayTarget.borrowed_chord`): its button is drawn lit.
fn isBorrowedChordHeld(s: *const State, chord: ScaleChord) bool {
    for (s.pointer_holds) |hold_slot| {
        const hold: PointerHold = hold_slot orelse continue;
        switch (hold.target) {
            .borrowed_chord => |held_chord| {
                if (held_chord.root_degree == chord.root_degree and held_chord.quality == chord.quality) {
                    return true;
                }
            },
            .note, .chord, .chooser_chord, .ignored => {},
        }
    }
    return false;
}

/// Writes a song's key into `buffer` for its label, after its name: ` (D major)` where the scale to choose is the
/// key's own tonic in Ionian; ` (B minor, as D Ionian)` where it is not - a minor key, counted from its relative
/// major; the version first where the song has several (` (Sinatra: C major)`).
fn writeSongKey(buffer: []u8, original_key: SongKey) []const u8 {
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

/// Writes the options' list of progressions in the current key: "off", then each progression's name, if it has one,
/// a song's key, its Nashville numbers and its chords' names - `1-4-5-1  C-F-G-C` in C, `D-G-A-D` in D; borrowed
/// chords named as themselves - `Hotel California (B minor, as D Ionian)  6-3-5-2-4-1-2-3  Am-E-G-D-F-C-Dm-E`. A
/// song's key is its recording's, and the scale that plays it (`SongKey`): chosen, the chords listed are the
/// recording's own - `Bm-F#-A-E-G-D-Em-F#` in D.
fn writeProgressionLabels(s: *State) void {
    s.progression_labels[0] = "off";
    for (progressions, 1..) |progression, label_index| {
        const buffer: *[params.limits.progression_label_capacity]u8 = &s.progression_label_buffers[label_index];
        var label_length: usize = 0;
        const name: []const u8 = bufPrint(buffer, "{s}", .{progression.name}) catch "";
        label_length += name.len;
        if (progression.original_key) |original_key| {
            const key_text: []const u8 = writeSongKey(buffer[label_length..], original_key);
            label_length += key_text.len;
        }
        const name_separator: []const u8 = if (progression.name.len > 0) "  " else "";
        const numbers: []const u8 = bufPrint(buffer[label_length..], "{s}{s}  ", .{
            name_separator,
            progression.nashville,
        }) catch "";
        label_length += numbers.len;
        for (0..progression.degrees.len) |step_index| {
            var name_buffer: [8]u8 = undefined;
            const step_chord: ScaleChord = progressionChord(&s.scale, progression, step_index);
            const chord_name: []const u8 = chordLetterName(&name_buffer, &s.scale, step_chord);
            const separator: []const u8 = if (step_index == 0) "" else "-";
            const room: []u8 = buffer[label_length..];
            const written: []const u8 = bufPrint(room, "{s}{s}", .{ separator, chord_name }) catch "";
            label_length += written.len;
        }
        s.progression_labels[label_index] = buffer[0..label_length];
    }
}

/// The beat at which the track's chord `chord_count` - counted from its first - reaches its button: the end of its bar
/// of travel, after the first bar's way in (`drawProgressionTrack`).
fn progressionArrivalBeat(chord_count: usize) f64 {
    return params.progression.beats_per_chord * float64(chord_count + 1);
}

/// Counts the progression's beats on, at its tempo: by the frame's duration, so that a tempo changed on the slider
/// carries on from where the track is rather than jumping.
fn advanceProgression(f: *z.Frame, s: *State) void {
    if (!hasTrack(s)) {
        return;
    }
    const beats_per_second: f64 = @as(f64, s.progression_beats_per_minute) / 60;
    s.progression_beat += @as(f64, f.time.delta_time) * beats_per_second;
    // Following the player, the chord awaited - the first not yet played - goes no further than its button: the
    // track holds a hair short of its arrival until the player plays it (`takeProgressionChord`).
    if (s.progression_waits_for_player) {
        const awaited_arrival_beat: f64 = progressionArrivalBeat(s.progression_chords_taken);
        s.progression_beat = @min(s.progression_beat, awaited_arrival_beat - params.progression.hold_beats);
    }
}

/// The chord the track waits for the player to play, once it has reached its button: following the player
/// (`progression_waits_for_player`), the chord awaited (`progression_chords_taken`), held at its arrival until it is
/// played (`takeProgressionChord`); null while none waits - the wait off, or the chord still on its way.
fn awaitedChord(s: *const State) ?ScaleChord {
    if (!hasTrack(s) or !s.progression_waits_for_player) {
        return null;
    }
    const arrival_beat: f64 = progressionArrivalBeat(s.progression_chords_taken);
    if (s.progression_beat < arrival_beat - 2 * params.progression.hold_beats) {
        return null;
    }
    return trackChord(s, s.progression_chords_taken);
}

/// How large the chord the track waits for is drawn now, as a multiple of its own size: from its size to a fifth
/// larger and back, three times a second, for as long as it waits - a call to play it; 1 while no chord waits.
fn waitingScale(f: *z.Frame, s: *const State) f32 {
    if (awaitedChord(s) == null) {
        return 1;
    }
    const swing: f32 = 0.5 + 0.5 * sinTurns(f.time.time * params.progression.waiting_pulses_per_second);
    return 1 + params.progression.waiting_pulse_growth * swing;
}

/// The waiting pulse's scale for the star's note on `degree`: the awaited chord's three notes pulse, every other note
/// keeps its size.
fn noteWaitingScale(f: *z.Frame, s: *const State, degree: u8) f32 {
    const awaited: ScaleChord = awaitedChord(s) orelse return 1;
    const awaited_degrees: [3]u8 = awaited.degrees();
    if (indexOfScalar(u8, &awaited_degrees, degree) == null) {
        return 1;
    }
    return waitingScale(f, s);
}

/// The waiting pulse's scale for the star's button of `chord`: the button on the awaited chord's root pulses - the
/// star has one button a root, a borrowed chord's being its root's there.
fn starChordWaitingScale(f: *z.Frame, s: *const State, chord: ScaleChord) f32 {
    const awaited: ScaleChord = awaitedChord(s) orelse return 1;
    return if (awaited.root_degree == chord.root_degree) waitingScale(f, s) else 1;
}

/// The waiting pulse's scale for a left diagram's button of `chord` - the chooser's, the key's window's, a borrowed
/// chord's own: only the awaited chord's own button pulses, a borrowed chord's small one rather than its root's.
fn leftChordWaitingScale(f: *z.Frame, s: *const State, chord: ScaleChord) f32 {
    const awaited: ScaleChord = awaitedChord(s) orelse return 1;
    const is_awaited: bool = awaited.root_degree == chord.root_degree and awaited.quality == chord.quality;
    return if (is_awaited) waitingScale(f, s) else 1;
}

/// Whether `point` lies in `rectangle`.
fn isPointInRectangle(point: Vec2, rectangle: z.Rectangle) bool {
    const is_within_x: bool = point[0] >= rectangle.x and point[0] < rectangle.x + rectangle.width;
    const is_within_y: bool = point[1] >= rectangle.y and point[1] < rectangle.y + rectangle.height;
    return is_within_x and is_within_y;
}

/// The options, built with the engine's UI: a button at the top left, beside the scale's name, opens a panel along the
/// left of the page - a tap beside it closes it again - holding them: the scale's tonic, A to G#, and its mode, Ionian
/// to Locrian (`changeScale` on a pick); the
/// progression to follow, its tempo and whether it waits for the player - a song chosen sets the scale its key is
/// played in (`SongKey`), where the tonics offered have it, and leaves the scale to the player after; the two pedals'
/// volumes, 0 silencing one (`updatePedals`); the chooser chord's volume (`HoldLayer.thumb`); and the sound's
/// diagnostics. Returns whether the UI has the pointers: while the panel is open, or one of its lists, the fingers
/// play nothing (`readPointers`).
fn buildOptions(f: *z.Frame, s: *State, ui: z.ui_real.Ui) bool {
    buildHeader(f, s, ui);
    if (!s.is_options_open) {
        return ui.isComboOpen();
    }
    // The panel along the left, 70% of the window's width - at least 460 pixels - and its height less a margin, so
    // that the star stays in sight beside it.
    const window_size: Vec2 = .{ f.window.widthf(), f.window.heightf() };
    const panel_margin: f32 = 0.06 * @min(window_size[0], window_size[1]);
    // Its wanted width, but no wider than the window allows, on a window too narrow for the least.
    const wanted_panel_width: f32 = @max(
        params.window.options_panel_least_width,
        params.window.options_panel_share * window_size[0],
    );
    const panel_width: f32 = @min(window_size[0] - 2 * panel_margin, wanted_panel_width);
    const panel_rectangle: z.Rectangle = .{
        .x = panel_margin,
        .y = panel_margin,
        .width = panel_width,
        .height = window_size[1] - 2 * panel_margin,
    };
    // A tap outside the panel closes it - but not one on the header's button, which opens and closes it itself, nor
    // one while a list is open, which the tap closes instead. The finger that closed it is the panel's until it lifts,
    // so that it plays nothing under it: the panel reports having the pointers this frame.
    if (z.isMouseButtonPressed(f.input, .left) and !ui.isComboOpen()) {
        const press_position: Vec2 = z.getMousePosition(f.input);
        const is_on_header: bool = press_position[1] < StarLayout.header_height + StarLayout.margin and
            press_position[0] < s.header_content_right + params.window.header_padding;
        if (!isPointInRectangle(press_position, panel_rectangle) and !is_on_header) {
            s.is_options_open = false;
            return true;
        }
    }
    ui.setNextWindowPos(.{ panel_rectangle.x, panel_rectangle.y }, .{});
    ui.setNextWindowSize(.{ panel_rectangle.width, panel_rectangle.height }, .{});
    const panel_flags: z.ui_real.WindowFlags = .{ .no_resize = true, .no_move = true, .no_collapse = true };
    var picked_scale: Scale = s.chosen_scale;
    // A progression picked in the list, or the boxes' count changed: placed in the boxes once a song's key is set.
    var is_progression_to_place: bool = false;
    if (ui.window("Options", .{ .flags = panel_flags })) |panel| {
        defer panel.close();
        // The scale is chosen in the header (`buildHeader`); the star's own options here.
        ui.text("Star", .{});
        // The star turning to the chord chosen, or kept at rest - and sent there, or back, when the box changes.
        if (ui.checkbox("turn the star", &s.turns_star)) {
            aimStar(f, s, starAimFor(s, &s.chosen_scale, s.chosen_chord_index));
        }
        _ = ui.checkbox("solfege names", &s.shows_solfege);
        ui.separator();
        ui.text("Progression", .{});
        // The list's labels in the key chosen now - a scale changed above shows in them next frame.
        writeProgressionLabels(s);
        // As wide as the panel's row allows: the named progressions' labels are long.
        const progression_opts: z.ui_real.ComboOpts = .{ .width = 0, .max_visible_items = 6 };
        if (ui.combo("track", &s.progression_choice, &s.progression_labels, progression_opts)) {
            s.progression_beat = 0;
            s.progression_chords_taken = 0;
            is_progression_to_place = true;
            // A song chosen, its key comes with it - D Ionian for Hotel California - where the tonics offered have
            // it; the scale is the player's to change again after.
            if (s.progression_choice > 0) {
                const chosen_progression: Progression = progressions[@intCast(s.progression_choice - 1)];
                if (chosen_progression.original_key) |original_key| {
                    if (songKeyTonic(original_key)) |tonic| {
                        picked_scale = .ofTonic(tonic.letter, tonic.accidental, .ionian);
                    }
                }
            }
        }
        // The editor's boxes: 2 to 16. The boxes shown before keep their chords; more of them, the progression
        // picked carries on into the ones that appear empty (`extendChosenProgression`).
        const box_count_before: usize = progressionBoxCount(s);
        if (ui.combo("boxes", &s.progression_box_count_choice, &params.progression.box_count_labels, .{})) {
            extendChosenProgression(s, box_count_before);
        }
        _ = ui.slider("bpm", &s.progression_beats_per_minute, .{ .min = 40, .max = 200, .fmt = "{d:.0}" });
        // Following the player, from the chord on its way when the box is ticked, so that the track goes on from
        // where it is.
        if (ui.checkbox("wait for the player", &s.progression_waits_for_player) and s.progression_waits_for_player) {
            s.progression_chords_taken = @trunc(s.progression_beat / params.progression.beats_per_chord);
        }
        // The track choosing its chords, the star following the song while the player plays the melody on it
        // (`playProgressionChords`).
        _ = ui.checkbox("play the chords", &s.progression_plays_chords);
        ui.separator();
        ui.text("Volumes", .{});
        // The pedals: the chosen chord's root, and the scale's tonic, each held low (`updatePedals`); 0 is silent.
        _ = ui.slider("root pedal", &s.root_pedal.volume, .{ .min = 0, .max = 1, .fmt = "{d:.2}" });
        _ = ui.slider("tonic pedal", &s.tonic_pedal.volume, .{ .min = 0, .max = 1, .fmt = "{d:.2}" });
        // The chord the thumb holds on the chooser, as a share of the notes' strength.
        _ = ui.slider("chooser chord", &s.chooser_chord_volume, .{ .min = 0, .max = 1, .fmt = "{d:.2}" });
        // The delay between a chord's notes as it starts, in seconds: root, third, fifth (`holdChordDegrees`).
        _ = ui.slider("strum", &s.chord_strum_seconds, .{ .min = 0, .max = 0.4, .fmt = "{d:.2} s" });
        ui.separator();
        // The sound's diagnostics: once shown, the engine keeps its panel up.
        const is_stats_toggled: bool = ui.checkbox("audio stats", &s.is_showing_audio_stats);
        if (is_stats_toggled and s.is_showing_audio_stats) {
            z.audio_device.showDiagnostics(f.audio_device);
        }
        // The debugging of the page's JavaScript handles: a handle used after it was freed named with where it was
        // made and freed; a leak counted by the code that made it. Slower: for finding a fault.
        const is_debugging_toggled: bool = ui.checkbox("debug handles", &s.is_debugging_handles);
        if (is_debugging_toggled) {
            z.audio_device.setHandleDebugging(f.audio_device, s.is_debugging_handles);
        }
        ui.separator();
        if (ui.button("close", .{})) {
            s.is_options_open = false;
        }
    }
    const is_new_tonic: bool = picked_scale.tonic_letter != s.chosen_scale.tonic_letter or
        picked_scale.tonic_accidental != s.chosen_scale.tonic_accidental;
    const is_new_scale: bool = is_new_tonic or picked_scale.mode != s.chosen_scale.mode;
    if (is_new_scale) {
        changeScale(f, s, picked_scale);
    }
    if (is_progression_to_place) {
        placeChosenProgression(s);
    }
    return true;
}

/// The slot holding what the pointer `pointer_id` holds, or null if it holds nothing.
fn holdSlotOf(s: *State, pointer_id: i32) ?*?PointerHold {
    for (&s.pointer_holds) |*hold_slot| {
        const hold: PointerHold = hold_slot.* orelse continue;
        if (hold.pointer_id == pointer_id) {
            return hold_slot;
        }
    }
    return null;
}

/// A slot no pointer holds, or null if all are taken - which the eleven slots, one for each pointer the engine
/// tracks, make impossible.
fn freeHoldSlot(s: *State) ?*?PointerHold {
    for (&s.pointer_holds) |*hold_slot| {
        if (hold_slot.* == null) {
            return hold_slot;
        }
    }
    return null;
}

/// The pointer `pointer_id` lets go of what it holds, if anything.
fn letGoOfPointer(f: *z.Frame, s: *State, pointer_id: i32) void {
    const hold_slot: *?PointerHold = holdSlotOf(s, pointer_id) orelse return;
    releaseTarget(f, s, hold_slot.*.?.target);
    hold_slot.* = null;
}

/// The player has played `chord` - from the chooser, the key's window, the star or a borrowed chord's button. Following
/// the player (`progression_waits_for_player`), the chord awaited, played, starts now: before its time, the track
/// jumps to its arrival; waiting at its button, it goes on - either way the next sets out from the centre. Any other
/// chord leaves the track as it is: a borrowed step wants the borrowed chord's button, not its root's.
fn takeProgressionChord(s: *State, chord: ScaleChord) void {
    if (!hasTrack(s) or !s.progression_waits_for_player) {
        return;
    }
    const awaited_chord: ScaleChord = trackChord(s, s.progression_chords_taken);
    if (chord.root_degree != awaited_chord.root_degree or chord.quality != awaited_chord.quality) {
        return;
    }
    s.progression_beat = @max(s.progression_beat, progressionArrivalBeat(s.progression_chords_taken));
    s.progression_chords_taken += 1;
}

/// A finger takes `target`: a chord on the chooser or the key's window is chosen (`chooseChord`) - when the finger
/// takes it, not at every frame it rests there - and then whatever it is sounds (`holdTarget`).
fn takeTarget(f: *z.Frame, s: *State, target: PlayTarget) void {
    switch (target) {
        .chooser_chord => |chord_index| {
            chooseChord(f, s, chord_index);
            takeProgressionChord(s, s.chosen_scale.chords[chord_index]);
        },
        // A borrowed chord chooses the chord on its root - the star turns to it - and alters the scale sounding for
        // itself before its notes are held, so that they sound at their altered pitches.
        .borrowed_chord => |chord| {
            chooseChord(f, s, chord.root_degree - 1);
            applyAlterations(f, s, s.chosen_scale.alterationsForChord(chord));
            takeProgressionChord(s, chord);
        },
        .chord => |chord_index| takeProgressionChord(s, s.chosen_scale.chords[chord_index]),
        .note, .ignored => {},
    }
    holdTarget(f, s, target);
}

/// The pointer `pointer_id`, at `position`, holds `target`: nothing changes if it holds it already; one holding
/// something else lets that go first, as a finger sliding from one note onto the next - once it has moved
/// `params.playing.target_switch_distance` from where it took what it holds; one holding nothing takes a free slot.
fn holdWithPointer(
    f: *z.Frame,
    s: *State,
    pointer_id: i32,
    target: PlayTarget,
    position: Vec2,
) void {
    if (holdSlotOf(s, pointer_id)) |hold_slot| {
        const hold: PointerHold = hold_slot.*.?;
        if (std.meta.eql(hold.target, target)) {
            // The same target: a hold free to change since the star turned settles where the finger is now.
            if (hold.anchor == null) {
                hold_slot.*.?.anchor = position;
            }
            return;
        }
        // Another target: taken only once the finger has moved from where it took the one it holds.
        if (hold.anchor) |anchor| {
            if (length(position - anchor) < params.playing.target_switch_distance) {
                return;
            }
        }
        releaseTarget(f, s, hold.target);
        takeTarget(f, s, target);
        hold_slot.* = .{ .pointer_id = pointer_id, .target = target, .anchor = position };
        return;
    }
    const free_slot: *?PointerHold = freeHoldSlot(s) orelse return;
    takeTarget(f, s, target);
    free_slot.* = .{ .pointer_id = pointer_id, .target = target, .anchor = position };
}

/// The track's chords due so far, counted from its first - the last of them is the one to play now; 0 in the first
/// bar, before the first arrives. Following the player, the chords played, and the one awaited as soon as it reaches
/// its button - where the track holds it (`advanceProgression`); otherwise every chord that has arrived.
fn dueProgressionChordCount(s: *const State) usize {
    if (s.progression_waits_for_player) {
        const awaited_arrival_beat: f64 = progressionArrivalBeat(s.progression_chords_taken);
        const held_arrival_beat: f64 = awaited_arrival_beat - 2 * params.progression.hold_beats;
        const has_awaited_arrived: bool = s.progression_beat >= held_arrival_beat;
        return s.progression_chords_taken + @intFromBool(has_awaited_arrived);
    }
    return @trunc(s.progression_beat / params.progression.beats_per_chord);
}

/// Puts back the scale a borrowed chord the track chose altered (`playProgressionChords`) - unless a finger holds a
/// borrowed chord now, whose alterations are then the ones that hold (`releaseTarget`'s rule).
fn restoreTrackAlterations(f: *z.Frame, s: *State) void {
    if (!s.has_track_altered_scale) {
        return;
    }
    s.has_track_altered_scale = false;
    if (borrowedChordHoldCount(s) == 0) {
        applyAlterations(f, s, @splat(0));
    }
}

/// Chooses the track's chords for the player, while the options say so (`progression_plays_chords`): as each falls
/// due, it is chosen, as a finger on its button would choose it (`chooseChord`) - the star turns to it, and the
/// fingers on the star find the chord's notes under them - but nothing sounds: the player plays the melody, the track
/// keeps the star on the song. A borrowed chord alters the scale sounding as well (`applyAlterations`), so that the
/// melody's notes are the chord's - A sharp over F sharp major in D - until the next chord, the scale's own, puts it
/// back; following the player, a chord chosen counts as played (`takeProgressionChord`) and sends the next on its
/// way. Called every frame: with the track off, the box unticked or the first bar not over, it chooses nothing, and
/// puts back the scale it altered.
fn playProgressionChords(f: *z.Frame, s: *State) void {
    const is_playing: bool = hasTrack(s) and s.progression_plays_chords;
    const due_count: usize = if (is_playing) dueProgressionChordCount(s) else 0;
    if (due_count == 0) {
        s.progression_played_chord_count = 0;
        restoreTrackAlterations(f, s);
        return;
    }
    if (due_count == s.progression_played_chord_count) {
        return;
    }
    const due_chord: ScaleChord = trackChord(s, due_count - 1);
    const own_chord_index: usize = due_chord.root_degree - 1;
    const is_borrowed: bool = due_chord.quality != s.chosen_scale.chords[own_chord_index].quality;
    chooseChord(f, s, @intCast(own_chord_index));
    if (is_borrowed) {
        applyAlterations(f, s, s.chosen_scale.alterationsForChord(due_chord));
        s.has_track_altered_scale = true;
    } else {
        restoreTrackAlterations(f, s);
    }
    takeProgressionChord(s, due_chord);
    s.progression_played_chord_count = due_count;
}

/// A little copy of a note on the circle of thirds' link between its two neighbours in the scale - the 2 halfway from 1
/// to 3, the 4 from 3 to 5, every note on the link across the circle from it - so that a melody up the scale, 1 2 3 4
/// 5, walks along the links rather than leaving them for each note where it stands. A copy plays its note as the note
/// itself does; it is drawn small and dim, without a name or an outline, so that the notes stay what the eye reads. As
/// the star turns, the links move, and the copies with them.
const NoteProxy = struct {
    /// The note it stands for.
    degree: u8,
    /// Where it stands: halfway along its link.
    centre: Vec2,
    /// How large it is drawn: a share of its note's size (`params.note_proxy.size_share`).
    half_size: f32,
    /// How far from its centre a touch plays it: most of the room between it and the two notes either side - wider
    /// than the proxy is drawn, so that a fingertip finds it (`noteProxyBetween`).
    reach: f32,
};

/// Whether `point` lies on `degree`'s note as drawn: within its square, or its circle.
fn isOnNote(star: StarLayout, degree: u8, point: Vec2) bool {
    const offset: Vec2 = @abs(point - star.noteCentre(degree));
    const half_size: f32 = star.noteHalfSize(degree);
    return switch (shapeOfDegree(&star.scale, degree)) {
        .square => @max(offset[0], offset[1]) <= half_size,
        .circle => length(offset) <= half_size,
    };
}

/// Where along the link from `first_place` to the place after it the curve crosses `degree`'s edge, as a share of the
/// link: halved, 20 times, between `inside_share`, on the note, and `outside_share`, off it - the share returned off
/// it. If the note covers the outside share too, the outside share.
fn noteEdgeOnLink(
    star: StarLayout,
    degree: u8,
    first_place: f32,
    inside_share: f32,
    outside_share: f32,
) f32 {
    if (isOnNote(star, degree, star.pointAtFractionalPlace(first_place + outside_share, 1))) {
        return outside_share;
    }
    var on_share: f32 = inside_share;
    var off_share: f32 = outside_share;
    for (0..20) |_| {
        const trial_share: f32 = 0.5 * (on_share + off_share);
        if (isOnNote(star, degree, star.pointAtFractionalPlace(first_place + trial_share, 1))) {
            on_share = trial_share;
        } else {
            off_share = trial_share;
        }
    }
    return off_share;
}

/// The proxy of `degree`, on the link between the notes `lower_degree` and `upper_degree` - neighbours on the circle of
/// thirds, a place apart - halfway along the part of it the notes leave in sight: on the curve, between the edges of
/// the two notes as they are drawn (`noteEdgeOnLink`), so that it sits on the white path, arc or line, in the middle of
/// what shows of it. Its reach: the room from it to the nearer edge of those two notes - each counted out to a square's
/// corner, its half-size times the square root of two, so that a square's corner pointing at it keeps its touches - of
/// which it takes `params.note_proxy.room_share`; never less than `params.note_proxy.reach` of its own half-size.
fn noteProxyBetween(
    star: StarLayout,
    degree: u8,
    lower_degree: u8,
    upper_degree: u8,
) NoteProxy {
    const lower_place: u8 = circlePlaceOfDegree(lower_degree);
    const upper_place: u8 = circlePlaceOfDegree(upper_degree);
    const is_lower_first: bool = (lower_place + 1) % 7 == upper_place;
    const first_place: f32 = float(if (is_lower_first) lower_place else upper_place);
    const first_degree: u8 = if (is_lower_first) lower_degree else upper_degree;
    const second_degree: u8 = if (is_lower_first) upper_degree else lower_degree;
    // Halfway along the link's visible part: between where the curve leaves the first note and where it enters the
    // second, as the notes are drawn - unless the notes leave none of it.
    const leaving_share: f32 = noteEdgeOnLink(star, first_degree, first_place, 0, 0.5);
    const entering_share: f32 = noteEdgeOnLink(star, second_degree, first_place, 1, 0.5);
    const halfway: Vec2 = star.pointAtFractionalPlace(first_place + 0.5 * (leaving_share + entering_share), 1);
    const half_size: f32 = params.note_proxy.size_share * star.noteHalfSize(degree);
    const corner_share: f32 = @sqrt(2.0);
    const lower_reach: f32 = corner_share * star.noteHalfSize(lower_degree);
    const upper_reach: f32 = corner_share * star.noteHalfSize(upper_degree);
    const room_to_lower: f32 = length(star.noteCentre(lower_degree) - halfway) - lower_reach;
    const room_to_upper: f32 = length(star.noteCentre(upper_degree) - halfway) - upper_reach;
    const room: f32 = @min(room_to_lower, room_to_upper);
    const reach: f32 = @max(params.note_proxy.reach * half_size, params.note_proxy.room_share * room);
    return .{ .degree = degree, .centre = halfway, .half_size = half_size, .reach = reach };
}

/// The seven proxies of the star as it stands, one for each note, the first degree's first (`NoteProxy`): each on the
/// link between the notes a step below it and a step above it in the scale, a third apart on the circle.
fn noteProxies(star: StarLayout) [7]NoteProxy {
    var proxies: [7]NoteProxy = undefined;
    for (&proxies, all_degrees) |*proxy, degree| {
        proxy.* = noteProxyBetween(star, degree, degreeAbove(degree, 6), degreeAbove(degree, 1));
    }
    return proxies;
}

/// What a pointer at `position` plays, by the part of the window it is in:
///
///     the keyboard      the note of the key under it - which then sounds and lights in the star, as a press there
///     the star          a note's proxy on its bottom line within its reach (`NoteProxy`), else the note or chord
///                       nearest it (`nearestTarget`) - unless the star is moving (`is_star_moving`): a finger
///                       resting on it would otherwise sound whatever passed under it
///     the chooser       the chord nearest it, at half strength, for as long as the thumb holds it - choosing it too
///     the key's window  the same, its nearest cell's chord (`FifthsLayout.nearestChord`)
///     the chromatic circle the scale's note nearest it (`ChromaticLayout.degreeAt`) - which then sounds and lights
///                       everywhere, as a press anywhere else
///     the sounding box  nothing - it shows what sounds
///     an editor's box   its chord, as the chooser plays it; an empty box nothing
///     beside the keyboard, where the fullscreen button is: nothing
fn targetAt(
    window_layout: WindowLayout,
    star: StarLayout,
    position: Vec2,
    is_star_moving: bool,
    borrowed_chords: []const ScaleChord,
    sounding_scale: *const Scale,
    boxes: []const ?ScaleChord,
) ?PlayTarget {
    const parts: WindowParts = window_layout.parts;
    if (parts.isBelowStar(position)) {
        const key_degree: u8 = parts.keyboardDegreeAt(sounding_scale, position) orelse return null;
        return .{ .note = key_degree };
    }
    // A box of the progression editor: its chord, as the chooser plays it - a borrowed one as a borrowed chord's
    // button does; an empty box, nothing.
    if (parts.isInEditor(position)) {
        const box_index: usize = parts.editorBoxAt(boxes.len, position) orelse return null;
        const chord: ScaleChord = boxes[box_index] orelse return null;
        const own_chord: ScaleChord = star.scale.chords[chord.root_degree - 1];
        if (chord.quality != own_chord.quality) {
            return .{ .borrowed_chord = chord };
        }
        return .{ .chooser_chord = chord.root_degree - 1 };
    }
    // A borrowed chord's button, within a little more than its size, before the chords round it.
    for (borrowed_chords) |chord| {
        const on_chooser: ButtonPlace = chooserBorrowedButton(window_layout.chooser, chord);
        const on_fifths: ButtonPlace = fifthsBorrowedButton(window_layout.fifths, chord);
        const is_on_chooser: bool = length(position - on_chooser.centre) < 1.3 * on_chooser.half_size;
        const is_on_fifths: bool = length(position - on_fifths.centre) < 1.3 * on_fifths.half_size;
        if (is_on_chooser or is_on_fifths) {
            return .{ .borrowed_chord = chord };
        }
    }
    if (parts.isInChooser(position)) {
        return .{ .chooser_chord = window_layout.chooser.nearestChord(position) };
    }
    if (parts.isInFifths(position)) {
        return .{ .chooser_chord = window_layout.fifths.nearestChord(position) };
    }
    if (parts.isInChromatic(position)) {
        return .{ .note = window_layout.chromatic.degreeAt(&star.scale, position) };
    }
    if (parts.isInSounding(position) or is_star_moving) {
        return null;
    }
    for (noteProxies(star)) |proxy| {
        if (length(position - proxy.centre) < proxy.reach) {
            return .{ .note = proxy.degree };
        }
    }
    return nearestTarget(star, position);
}

/// The chord the pointer `pointer_id` carries, or null.
fn chordDragOf(s: *State, pointer_id: i32) ?*ChordDrag {
    for (&s.chord_drags) |*drag_slot| {
        if (drag_slot.*) |*drag| {
            if (drag.pointer_id == pointer_id) {
                return drag;
            }
        }
    }
    return null;
}

/// The chords the fingers carry toward the progression editor's boxes (`ChordDrag`): a finger lifted drops its chord on
/// the box under it (`dropChord`); one still down carries its chord to where it is now; one that has just come down on
/// a chord - anywhere one plays, a box's own included - picks it up, while it also plays it as any finger does. Only a
/// finger that has just come down picks a chord up, not one gliding onto it. Then the pointers down now are kept, to
/// tell the next frame's new ones.
fn carryChords(
    s: *State,
    window_layout: WindowLayout,
    star: StarLayout,
    pointers: []const PointerDown,
    is_star_moving: bool,
    borrowed_chords: []const ScaleChord,
    is_ui_capturing: bool,
) void {
    for (&s.chord_drags) |*drag_slot| {
        const drag: ChordDrag = drag_slot.* orelse continue;
        const is_still_down: bool = for (pointers) |pointer| {
            if (pointer.pointer_id == drag.pointer_id) {
                break true;
            }
        } else false;
        if (!is_still_down) {
            dropChord(s, window_layout.parts, drag);
            drag_slot.* = null;
        }
    }
    for (pointers) |pointer| {
        if (chordDragOf(s, pointer.pointer_id)) |drag| {
            drag.position = pointer.position;
            continue;
        }
        const was_down: bool = indexOfScalar(?i32, &s.pointer_ids_last_frame, pointer.pointer_id) != null;
        const is_for_dropdowns: bool = is_ui_capturing or window_layout.parts.isInHeader(pointer.position);
        if (was_down or is_for_dropdowns) {
            continue;
        }
        const target: PlayTarget = targetAt(
            window_layout,
            star,
            pointer.position,
            is_star_moving,
            borrowed_chords,
            &s.scale,
            s.progression_boxes[0..progressionBoxCount(s)],
        ) orelse continue;
        const chord: ScaleChord = chordOfTarget(s, target) orelse continue;
        for (&s.chord_drags) |*drag_slot| {
            if (drag_slot.* == null) {
                drag_slot.* = .{
                    .pointer_id = pointer.pointer_id,
                    .chord = chord,
                    .start = pointer.position,
                    .position = pointer.position,
                };
                break;
            }
        }
    }
    s.pointer_ids_last_frame = @splat(null);
    for (pointers, 0..) |pointer, index| {
        s.pointer_ids_last_frame[index] = pointer.pointer_id;
    }
}

/// The pointers, each on its own - several fingers play several notes and chords at once. A pointer that has lifted
/// lets go of what it held. A pointer that begins on the dropdowns, or while one of their lists is open, is theirs
/// until it lifts, and plays nothing. A pointer down on the chooser chooses the chord nearest it. Every other pointer
/// down then holds what it is on (`targetAt`) - following its finger from one target to the next as it slides - or,
/// on nothing that plays, lets go.
fn readPointers(
    f: *z.Frame,
    s: *State,
    window_layout: WindowLayout,
    is_ui_capturing: bool,
) void {
    // The star as the fingers find it: at the chosen chord's turn and sides, where it is going - though they find
    // nothing while it moves, and it is only there once it has arrived.
    const star: StarLayout = starForChoice(
        window_layout,
        s,
        s.transition.turn_to,
        s.transition.minor_side_outside_to,
    );
    const is_star_moving: bool = s.transition.isUnderWay(f.time.time);
    // The borrowed chords whose buttons are shown, which a finger can take (`offeredBorrowedChords`).
    var offered_buffer: [params.limits.most_offered_borrowed_chords]ScaleChord = undefined;
    const borrowed_chords: []const ScaleChord = offeredBorrowedChords(s, &offered_buffer);
    // The turn has just ended: every hold may change at once to what is now under its finger - the same fingers play
    // the new chord's notes, as the star brought them under them - this frame, before the pointers are read.
    const has_turn_ended: bool = s.was_star_moving and !is_star_moving;
    s.was_star_moving = is_star_moving;
    if (has_turn_ended) {
        for (&s.pointer_holds) |*hold_slot| {
            if (hold_slot.*) |*hold| {
                hold.anchor = null;
            }
        }
    }
    var pointers_buffer: [params.limits.most_pointers]PointerDown = undefined;
    const pointers: []const PointerDown = pointersDown(f, s, &pointers_buffer);
    carryChords(s, window_layout, star, pointers, is_star_moving, borrowed_chords, is_ui_capturing);
    for (s.pointer_holds) |hold_slot| {
        const hold: PointerHold = hold_slot orelse continue;
        const is_still_down: bool = for (pointers) |pointer| {
            if (pointer.pointer_id == hold.pointer_id) {
                break true;
            }
        } else false;
        if (!is_still_down) {
            letGoOfPointer(f, s, hold.pointer_id);
        }
    }
    for (pointers) |pointer| {
        // A finger the dropdowns have keeps to them until it lifts; one that begins on them, or while a list is open,
        // becomes theirs.
        if (holdSlotOf(s, pointer.pointer_id)) |hold_slot| {
            if (hold_slot.*.?.target == .ignored) {
                continue;
            }
        }
        const is_for_dropdowns: bool = is_ui_capturing or window_layout.parts.isInHeader(pointer.position);
        if (is_for_dropdowns) {
            letGoOfPointer(f, s, pointer.pointer_id);
            holdWithPointer(f, s, pointer.pointer_id, .ignored, pointer.position);
            continue;
        }
        // While the star turns, a finger on it keeps what it holds - the note sounds on through the turn rather than
        // falling silent - and takes nothing new: it would sound whatever passed under it.
        const is_on_star: bool = window_layout.parts.isInStarArea(pointer.position);
        if (is_star_moving and is_on_star) {
            continue;
        }
        const target: ?PlayTarget = targetAt(
            window_layout,
            star,
            pointer.position,
            is_star_moving,
            borrowed_chords,
            &s.scale,
            s.progression_boxes[0..progressionBoxCount(s)],
        );
        if (target) |target_to_hold| {
            holdWithPointer(f, s, pointer.pointer_id, target_to_hold, pointer.position);
        } else {
            letGoOfPointer(f, s, pointer.pointer_id);
        }
    }
}

// ---- The chord's curve ----

/// An interval as a ratio of whole numbers: the upper note's frequency to the lower's.
const JustRatio = struct {
    /// The upper note's part.
    upper: u32,
    /// The lower note's part.
    lower: u32,
};

/// The just-intonation ratio of each interval, by its size in semitones within an octave: the simplest whole-number
/// ratio the ear hears the interval as - the unison 1:1, the minor second 16:15, the major second 9:8, the minor third
/// 6:5, the major third 5:4, the fourth 4:3, the tritone 7:5, the fifth 3:2, the minor sixth 8:5, the major sixth 5:3,
/// the minor seventh 9:5, the major seventh 15:8. Equal temperament, which the instrument plays, divides the octave in
/// twelve equal steps instead, and its ratios are not whole-number ratios at all; but a Lissajous curve closes on
/// itself only for whole-number ratios, so the curve shows the interval the ear hears.
const just_interval_ratios = [12]JustRatio{
    .{ .upper = 1, .lower = 1 },
    .{ .upper = 16, .lower = 15 },
    .{ .upper = 9, .lower = 8 },
    .{ .upper = 6, .lower = 5 },
    .{ .upper = 5, .lower = 4 },
    .{ .upper = 4, .lower = 3 },
    .{ .upper = 7, .lower = 5 },
    .{ .upper = 3, .lower = 2 },
    .{ .upper = 8, .lower = 5 },
    .{ .upper = 5, .lower = 3 },
    .{ .upper = 9, .lower = 5 },
    .{ .upper = 15, .lower = 8 },
};

/// The notes the curve draws, at most three, bottom first, and their frequencies as whole numbers in the ratio the ear
/// hears them in (`curveFrequencies`): a major chord's 4, 5 and 6.
const CurveNotes = struct {
    /// How many: 0 to 3.
    count: usize,
    /// Their degrees, bottom first.
    degrees: [3]u8,
    /// Their frequencies as whole numbers in the ratio the ear hears.
    frequencies: [3]u32,
};

/// The semitones from the note `lower_degree` up to `upper_degree` in `scale`, within an octave: from 0 to 11.
fn semitonesUp(scale: *const Scale, lower_degree: u8, upper_degree: u8) u8 {
    const lower_semitone: u8 = scale.semitones[lower_degree - 1];
    const upper_semitone: u8 = scale.semitones[upper_degree - 1];
    return (upper_semitone + 12 - lower_semitone) % 12;
}

/// The frequencies, as the smallest whole numbers in the right ratio, of notes stacked upward from the first: each
/// note's ratio to the bottom one from `just_interval_ratios`, all scaled by the least common multiple of their
/// denominators so that every one is whole, then divided by the greatest common divisor of the results.
///
///     C E G:   1, 5/4, 3/2      x 4      4 : 5 : 6
///     A C E:   1, 6/5, 3/2      x 10     10 : 12 : 15
///     B D F:   1, 6/5, 7/5      x 5      5 : 6 : 7
fn curveFrequencies(scale: *const Scale, degrees: []const u8) [3]u32 {
    var common_denominator: u32 = 1;
    for (degrees[1..]) |degree| {
        const ratio: JustRatio = just_interval_ratios[semitonesUp(scale, degrees[0], degree)];
        // The least common multiple of the denominators so far and this one.
        common_denominator = common_denominator / gcd(u32, common_denominator, ratio.lower) * ratio.lower;
    }
    var frequencies: [3]u32 = @splat(0);
    frequencies[0] = common_denominator;
    var common_divisor: u32 = common_denominator;
    for (degrees[1..], 1..) |degree, note_index| {
        const ratio: JustRatio = just_interval_ratios[semitonesUp(scale, degrees[0], degree)];
        frequencies[note_index] = common_denominator / ratio.lower * ratio.upper;
        common_divisor = gcd(u32, common_divisor, frequencies[note_index]);
    }
    for (frequencies[0..degrees.len]) |*frequency| {
        frequency.* /= common_divisor;
    }
    return frequencies;
}

/// The largest of a stacking's frequencies: how complex its curve is - the number of times the fastest note goes
/// round while the curve closes.
fn largestFrequency(frequencies: [3]u32) u32 {
    return @max(frequencies[0], frequencies[1], frequencies[2]);
}

/// The notes the curve draws, from the notes sounding now:
///
///     which    the chosen chord's notes first, root, third and fifth; then the others by degree; at most three
///     order    a chord of the scale from its root, its third and fifth above; any other set stacked from whichever
///              of its notes makes the simplest ratios - the smallest largest frequency - as the ear would hear it
fn curveNotes(s: *const State) CurveNotes {
    var chosen: [3]u8 = undefined;
    var chosen_count: usize = 0;
    const chosen_chord: ScaleChord = s.scale.chords[s.chosen_chord_index];
    for (chosen_chord.degrees()) |degree| {
        if (isDegreeSounding(s, degree) and chosen_count < 3) {
            chosen[chosen_count] = degree;
            chosen_count += 1;
        }
    }
    for (all_degrees) |degree| {
        const is_already_chosen: bool = indexOfScalar(u8, chosen[0..chosen_count], degree) != null;
        if (isDegreeSounding(s, degree) and !is_already_chosen and chosen_count < 3) {
            chosen[chosen_count] = degree;
            chosen_count += 1;
        }
    }
    var curve: CurveNotes = .{ .count = chosen_count, .degrees = chosen, .frequencies = @splat(0) };
    if (chosen_count == 0) {
        return curve;
    }
    // A chord of the scale, all three of its notes or two of them: taken from its root, in the chord's order.
    for (s.scale.chords) |chord| {
        const chord_degrees: [3]u8 = chord.degrees();
        var in_chord_order: [3]u8 = undefined;
        var in_chord_count: usize = 0;
        for (chord_degrees) |degree| {
            if (indexOfScalar(u8, chosen[0..chosen_count], degree) != null) {
                in_chord_order[in_chord_count] = degree;
                in_chord_count += 1;
            }
        }
        const is_chosen_chord: bool = chord.root_degree == chosen_chord.root_degree;
        const is_whole_chord: bool = in_chord_count == chosen_count and chosen_count == 3;
        const is_part_of_chosen: bool = in_chord_count == chosen_count and is_chosen_chord;
        if (is_whole_chord or is_part_of_chosen) {
            curve.degrees = in_chord_order;
            curve.frequencies = curveFrequencies(&s.scale, in_chord_order[0..chosen_count]);
            return curve;
        }
    }
    // Any other set: each of its notes tried as the bottom, the others stacked above it in the order of the scale
    // from there, and the simplest kept.
    var best_frequencies: [3]u32 = @splat(0);
    var best_largest: u32 = maxInt(u32);
    for (0..chosen_count) |bottom_index| {
        var stacked: [3]u8 = undefined;
        stacked[0] = chosen[bottom_index];
        var stacked_count: usize = 1;
        for (1..8) |steps_up| {
            const degree: u8 = degreeAbove(chosen[bottom_index], @intCast(steps_up));
            if (indexOfScalar(u8, chosen[0..chosen_count], degree) != null and stacked_count < chosen_count) {
                stacked[stacked_count] = degree;
                stacked_count += 1;
            }
        }
        const frequencies: [3]u32 = curveFrequencies(&s.scale, stacked[0..chosen_count]);
        if (largestFrequency(frequencies) < best_largest) {
            best_largest = largestFrequency(frequencies);
            best_frequencies = frequencies;
            curve.degrees = stacked;
        }
    }
    curve.frequencies = best_frequencies;
    return curve;
}

/// The curve's color at `fraction_along` its length: a gradient through its notes' colors, bottom to top and back -
/// C, E, G, E, C for a major chord - so that no color ever turns straight into a far one, as the top's into the
/// bottom's would. It goes there and back as often as the bottom note swings while the curve goes round - four times
/// for a major chord's 4 : 5 : 6 - so that each of its loops carries all the chord's colors. It is measured along the
/// curve's length, not its parameter: the point slows down where the curve turns, and a gradient by the parameter
/// would change color all at once there.
fn curveColorAt(curve: CurveNotes, fraction_along: f32) Color {
    // The colors there and back: from the bottom's, index 0, up to the top's, `count - 1`, and down again.
    const steps_one_way: f32 = float(curve.count - 1);
    const steps_there_and_back: f32 = 2 * steps_one_way;
    const gradient_rounds: f32 = float(curve.frequencies[0]);
    const position_there_and_back: f32 = @mod(fraction_along * gradient_rounds, 1) * steps_there_and_back;
    // Folded at the top: on the way back, the position counts down.
    const position: f32 = if (position_there_and_back <= steps_one_way)
        position_there_and_back
    else
        steps_there_and_back - position_there_and_back;
    const lower_index: usize = @floor(position);
    const upper_index: usize = @min(lower_index + 1, curve.count - 1);
    const blend: f32 = position - @floor(position);
    const lower_color: Color = params.colors.degrees[curve.degrees[lower_index] - 1];
    const upper_color: Color = params.colors.degrees[curve.degrees[upper_index] - 1];
    return lower_color.lerp(upper_color, blend);
}

/// The sounding chord as a Lissajous curve, in the sounding box (`WindowParts.sounding`): the path of a point whose
/// coordinates each swing like one of the notes, `sin(frequency x s)` for `s` once round, the frequencies in the ratio
/// the ear hears (`curveNotes`). Whole-number ratios make the curve close on itself after one round, so it is a fixed
/// figure, and the simpler the ratio, the simpler the figure - a unison a line, an octave a figure of eight, a fifth a
/// figure of three lobes against two.
///
///     one note       nothing: a line, the unison with itself, says nothing
///     two notes      the flat figure of the interval, the upper note across, the lower up and down: still
///     three notes    a figure in three dimensions - the fifth across, the root up and down, the third in depth -
///                    turning slowly about the upright axis, seen from the front: facing, it shows the root against the
///                    fifth; as it turns, the third comes in
///
/// Drawn in segments, enough for the fastest note's swings to stay smooth, in a gradient of its notes' colors along its
/// length (`curveColorAt`).
fn drawChordCurve(f: *z.Frame, s: *const State, room: z.Rectangle) void {
    const curve: CurveNotes = curveNotes(s);
    // A single note would draw a line, the unison with itself: nothing to show.
    if (curve.count < 2) {
        return;
    }
    // The figure's half-size: square, as a Lissajous figure is drawn, and as large as the box's shorter side allows,
    // centred in it.
    const room_centre: Vec2 = .{ room.x + 0.5 * room.width, room.y + 0.5 * room.height };
    const half_side: f32 = 0.45 * @min(room.width, room.height);
    const half_size: Vec2 = @splat(half_side);
    const across_frequency: f32 = float(curve.frequencies[curve.count - 1]);
    const upright_frequency: f32 = float(curve.frequencies[0]);
    const depth_frequency: f32 = if (curve.count == 3) float(curve.frequencies[1]) else 0;
    // The turn about the upright axis: none for a flat figure, steady for a figure in depth.
    const curve_turns: f32 = if (curve.count == 3) @mod(f.time.time * params.sounding.curve_turns_per_second, 1) else 0;
    const turn_cosine: f32 = cosTurns(curve_turns);
    const turn_sine: f32 = sinTurns(curve_turns);
    const segments_per_swing: usize = 48;
    const segment_count: usize = @min(
        segments_per_swing * largestFrequency(curve.frequencies),
        params.limits.most_curve_points - 1,
    );
    // The points first, with the length the curve has reached at each: the gradient is by length.
    var points: [params.limits.most_curve_points]Vec2 = undefined;
    var lengths_so_far: [params.limits.most_curve_points]f32 = undefined;
    for (0..segment_count + 1) |point_index| {
        // The point's progress once round, in turns.
        const progress: f32 = float(point_index) / float(segment_count);
        const across: f32 = sinTurns(across_frequency * progress);
        const upright: f32 = sinTurns(upright_frequency * progress);
        const depth: f32 = sinTurns(depth_frequency * progress);
        // Turned about the upright axis, and seen from the front: depth swings into the across direction.
        const turned_across: f32 = across * turn_cosine + depth * turn_sine;
        points[point_index] = room_centre + Vec2{ turned_across, -upright } * half_size;
        const segment_length: f32 = if (point_index == 0) 0 else length(points[point_index] - points[point_index - 1]);
        const length_before: f32 = if (point_index == 0) 0 else lengths_so_far[point_index - 1];
        lengths_so_far[point_index] = length_before + segment_length;
    }
    const whole_length: f32 = @max(lengths_so_far[segment_count], 1);
    for (1..segment_count + 1) |point_index| {
        const middle_length: f32 = (lengths_so_far[point_index - 1] + lengths_so_far[point_index]) / 2;
        const color: Color = curveColorAt(curve, middle_length / whole_length);
        f.gl.line(points[point_index - 1], points[point_index], .{ .color = color, .thickness = 2 });
    }
}

// ---- Naming the chord ----

/// A set of pitch classes - the twelve notes of the octave, C to B, without regard to which octave - as twelve bits:
/// bit 0 for C, bit 1 for C sharp, and on to bit 11 for B. A set of notes sounding, or a chord's notes counted from its
/// root (`ChordPattern`).
const PitchClassSet = u12;

/// The set holding the pitch classes `semitones_from_root` above a root at 0.
fn pitchClassSetOf(comptime semitones_from_root: []const u4) PitchClassSet {
    var set: PitchClassSet = 0;
    for (semitones_from_root) |semitone| {
        set |= @as(PitchClassSet, 1) << semitone;
    }
    return set;
}

/// `set` as seen from `root`: every pitch class moved down by `root` semitones, round the octave, so that the root is
/// at 0 - the form a chord's pattern is written in. C E G seen from C is 0 4 7; seen from E, 0 3 8.
fn pitchClassesFromRoot(set: PitchClassSet, root: u4) PitchClassSet {
    // A rotation of the twelve bits, by `root`: the set written twice in a row, 24 bits, and the twelve from bit
    // `root` on taken - each bit below `root` comes back round at the top.
    const set_twice: u24 = @as(u24, set) | (@as(u24, set) << 12);
    return @truncate(set_twice >> root);
}

/// A kind of chord: the pitch classes it holds counted from its root, the suffix written after the root's name in a
/// chord symbol, and the kind spelled out.
const ChordPattern = struct {
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
const chord_patterns = [_]ChordPattern{
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
const interval_names = [12][]const u8{
    "unison",  "minor second", "major second", "minor third", "major third",   "fourth",
    "tritone", "fifth",        "minor sixth",  "major sixth", "minor seventh", "major seventh",
};

/// What the notes sounding are called, as the centre of the chromatic circle shows it: a symbol - `Am7`, `G`, `Bdim` -
/// and the kind spelled out beneath it, or the notes themselves when no name fits. `root` is the chord's root, by its
/// pitch class, when there is one: the polygon is drawn in its color.
const ChordName = struct {
    /// The symbol's letters.
    symbol_buffer: [24]u8,
    /// How many of them are the symbol.
    symbol_length: usize,
    /// The kind spelled out, or the notes named when no kind fits.
    description: []const u8,
    /// The chord's root's pitch class, if it has one.
    root: ?u4,

    /// The symbol: `Am7`.
    fn symbol(name: *const ChordName) []const u8 {
        return name.symbol_buffer[0..name.symbol_length];
    }
};

/// The pitch classes sounding now, as a set.
fn soundingPitchClasses(s: *const State) PitchClassSet {
    var set: PitchClassSet = 0;
    for (all_degrees) |degree| {
        if (isDegreeSounding(s, degree)) {
            const pitch_class: u4 = s.scale.pitchClassOfDegree(degree);
            set |= @as(PitchClassSet, 1) << pitch_class;
        }
    }
    return set;
}

/// A chord's name from its root and its pattern: the root's name and the pattern's suffix - `A` and `m7`, `Am7`.
fn nameFromPattern(scale: *const Scale, root: u4, pattern: ChordPattern) ChordName {
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
const ChordMatch = struct {
    /// The chord's root's pitch class.
    root: u4,
    /// The kind of chord it is.
    pattern: ChordPattern,
};

/// The chord `sounding` makes, if one of `chord_patterns` fits it: from `preferred_root` - the chosen chord's - if that
/// root fits, else the first pattern that fits from any root, and for that pattern the lowest root from C.
fn matchedChord(sounding: PitchClassSet, preferred_root: u4) ?ChordMatch {
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
fn namedChord(
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
fn numeralNameOf(buffer: []u8, scale: *const Scale, match: ChordMatch) []const u8 {
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

/// The chord the notes sounding make, named by degrees as the sounding box shows it (`drawChordNumeral`) - no note's
/// name:
///
///     one note           its degree: `3`
///     two notes          their degrees, upward from the lower as the chord's curve stacks them: `1-5`
///     a chord            its Roman numeral and kind (`numeralNameOf`), from the chosen chord's root when several fit
///     no chord fits      the degrees, in the scale's order: `1-2-4`
fn degreeNameOfChord(buffer: []u8, s: *const State) ?[]const u8 {
    const sounding: PitchClassSet = soundingPitchClasses(s);
    const note_count: usize = @popCount(sounding);
    if (note_count == 0) {
        return null;
    }
    const scale: *const Scale = &s.scale;
    if (note_count == 2) {
        const curve: CurveNotes = curveNotes(s);
        return bufPrint(buffer, "{d}-{d}", .{ curve.degrees[0], curve.degrees[1] }) catch "";
    }
    if (note_count >= 3) {
        const chosen_root: u4 = scale.pitchClassOfDegree(scale.chords[s.chosen_chord_index].root_degree);
        if (matchedChord(sounding, chosen_root)) |match| {
            return numeralNameOf(buffer, scale, match);
        }
    }
    var name_length: usize = 0;
    for (all_degrees) |degree| {
        if (!isDegreeSounding(s, degree)) {
            continue;
        }
        const separator: []const u8 = if (name_length == 0) "" else "-";
        const written: []const u8 = bufPrint(buffer[name_length..], "{s}{d}", .{ separator, degree }) catch "";
        name_length += written.len;
    }
    return buffer[0..name_length];
}

/// The chord the notes sounding make, named as chord symbols are written:
///
///     the root           a pitch class sounding, from which the others make one of `chord_patterns`
///     several fit        the same notes can be two chords - C E G A is C6, and A C E G is Am7 - and the chord chosen
///                        on the left decides: its root, if it is one of the roots that fit; otherwise the pattern
///                        first in `chord_patterns`, and among roots for it the lowest from C
///     two notes          a fifth is the power chord, C5; any other pair is named by its interval, from its lower note
///                        as the chord's curve stacks them (`curveNotes`)
///     one note           its name
///     no name fits       the notes, in the scale's order from its tonic
fn nameOfChord(s: *const State) ?ChordName {
    const sounding: PitchClassSet = soundingPitchClasses(s);
    const note_count: usize = @popCount(sounding);
    if (note_count == 0) {
        return null;
    }
    const scale: *const Scale = &s.scale;
    var name: ChordName = .{ .symbol_buffer = undefined, .symbol_length = 0, .description = "", .root = null };
    const chosen_root: u4 = scale.pitchClassOfDegree(scale.chords[s.chosen_chord_index].root_degree);
    if (namedChord(scale, sounding, chosen_root)) |chord_name| {
        return chord_name;
    }
    if (note_count == 2) {
        // Two notes that are no fifth: named by their interval, upward from the lower as the curve stacks them.
        const curve: CurveNotes = curveNotes(s);
        const lower_degree: u8 = curve.degrees[0];
        const upper_degree: u8 = curve.degrees[1];
        const lower_name: []const u8 = scale.noteName(lower_degree);
        const upper_name: []const u8 = scale.noteName(upper_degree);
        const symbol: []const u8 = bufPrint(&name.symbol_buffer, "{s}-{s}", .{ lower_name, upper_name }) catch "";
        name.symbol_length = symbol.len;
        name.description = interval_names[semitonesUp(scale, lower_degree, upper_degree)];
        return name;
    }
    // One note, or notes no name fits: the notes, in the scale's order from its tonic, spelled as it spells them.
    for (all_degrees) |degree| {
        if (!isDegreeSounding(s, degree)) {
            continue;
        }
        const separator: []const u8 = if (name.symbol_length == 0) "" else " ";
        const room: []u8 = name.symbol_buffer[name.symbol_length..];
        const written: []const u8 = bufPrint(room, "{s}{s}", .{ separator, scale.noteName(degree) }) catch "";
        name.symbol_length += written.len;
    }
    return name;
}

// ---- Drawing ----

/// How a line from a chord to one of its notes is drawn: by the note's role in the chord.
const LineRole = enum { root, third, fifth };

/// The color of a line by the role of the note it leads to: the root red, the third yellow, the fifth cyan - the
/// colors of 1, 3 and 5, the root, third and fifth of the scale's first chord.
fn lineColorOfRole(role: LineRole) Color {
    return switch (role) {
        .root => params.colors.degrees[0],
        .third => params.colors.degrees[2],
        .fifth => params.colors.degrees[4],
    };
}

/// The width of the drawing's strokes - rings, borders, lines - in proportion to the notes' size.
fn strokeThickness(star: StarLayout) f32 {
    return @max(1.5, 0.07 * star.size_unit);
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

/// The size to draw `text` at: `wanted_size`, or smaller, so that it is at most `most_width` wide.
fn fittedTextSize(
    s: *const State,
    text: []const u8,
    wanted_size: f32,
    most_width: f32,
) f32 {
    const wanted_width: f32 = z.measureText(s.font, text, wanted_size)[0];
    if (wanted_width <= most_width) {
        return wanted_size;
    }
    return wanted_size * most_width / wanted_width;
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
    star: StarLayout,
    chord: ScaleChord,
    note_degree: u8,
    role: LineRole,
    is_lit: bool,
) void {
    const note_centre: Vec2 = star.noteCentre(note_degree);
    const chord_centre: Vec2 = star.chordCentre(chord);
    const start: Vec2 = shapeEdgeToward(chord_centre, shapeOfChord(chord), star.chordHalfSize(chord), note_centre);
    const gap_beyond_note: f32 = 1.15 * star.noteHalfSize(note_degree);
    const end: Vec2 = shapeEdgeToward(note_centre, shapeOfDegree(&star.scale, note_degree), gap_beyond_note, start);
    if (length(end - start) <= 0.5 * star.size_unit) {
        return;
    }
    // A lit chord's lines are drawn whole and twice as thick, so that the chord stands out from the six others.
    const whole_color: Color = lineColorOfRole(role);
    const color: Color = if (is_lit)
        whole_color
    else
        whole_color.lerp(params.colors.background, params.dimming.resting);
    const resting_thickness: f32 = strokeThickness(star);
    const thickness: f32 = if (is_lit) 2 * resting_thickness else resting_thickness;
    const size_unit: f32 = star.size_unit;
    switch (role) {
        .root => drawArrow(f, start, end, thickness, 0.5 * size_unit, color),
        .third => drawZigzag(f, start, end, thickness, 0.35 * size_unit, color),
        .fifth => {
            const dash_length: f32 = 0.3 * size_unit;
            f.gl.lineDashed(start, end, thickness, dash_length, dash_length * 0.8, .{ .color = color });
        },
    }
}

/// A fan from `apex` to the arc of the star's curve from `first_place` to the place after it, filled with `color`: a
/// triangle from the apex to each short piece of the arc.
fn drawChordFan(
    f: *z.Frame,
    star: StarLayout,
    apex: Vec2,
    first_place: f32,
    color: Color,
) void {
    var previous_point: Vec2 = star.pointAtFractionalPlace(first_place, 1);
    for (1..params.star.curve_pieces_per_link + 1) |piece_index| {
        const piece_share: f32 = float(piece_index) / float(params.star.curve_pieces_per_link);
        const point: Vec2 = star.pointAtFractionalPlace(first_place + piece_share, 1);
        f.gl.triangle(apex, previous_point, point, .{ .color = color });
        previous_point = point;
    }
}

/// A chord's shape, filled faintly with the chord's color: two fans from the chord to the arcs of the star's curve its
/// notes span - one to the arc from its root to its third, the other, fainter, to the arc from its third to its fifth:
/// IV's green between IV and the arc from 4 to 6, and fainter to the arc from 6 to 1 - so that each chord's part of the
/// figure reads as one region, bounded by its lines to its notes and the arc between them. The chords outside and
/// inside face each link from either side, so the arc is where their shapes meet, and no two cross
/// (`StarLayout.chordCentre`). The diminished chord fans out to the one link it faces alone: its third to its fifth
/// with the major side outside, its root to its third with the minor. Drawn first, under the lines and the shapes.
fn drawChordShapes(
    f: *z.Frame,
    star: StarLayout,
    chord: ScaleChord,
    is_lit: bool,
) void {
    const placed_chord: ScaleChord = star.scale.chords[chord.root_degree - 1];
    const chord_centre: Vec2 = star.chordCentre(chord);
    const root_place: f32 = float(circlePlaceOfDegree(placed_chord.root_degree));
    const chord_color: Color = params.colors.degrees[chord.root_degree - 1];
    const root_third_amount: f32 = if (is_lit)
        params.dimming.root_third_fan.lit
    else
        params.dimming.root_third_fan.resting;
    const third_fifth_amount: f32 = if (is_lit)
        params.dimming.third_fifth_fan.lit
    else
        params.dimming.third_fifth_fan.resting;
    const root_third_color: Color = chord_color.lerp(params.colors.background, root_third_amount);
    const third_fifth_color: Color = chord_color.lerp(params.colors.background, third_fifth_amount);
    if (placed_chord.quality == .diminished) {
        const is_minor_side_outside: bool = star.minor_side_outside_fraction >= 0.5;
        if (is_minor_side_outside) {
            drawChordFan(f, star, chord_centre, root_place, root_third_color);
        } else {
            drawChordFan(f, star, chord_centre, root_place + 1, third_fifth_color);
        }
        return;
    }
    drawChordFan(f, star, chord_centre, root_place, root_third_color);
    drawChordFan(f, star, chord_centre, root_place + 1, third_fifth_color);
}

/// A shape filled with `fill_color` and outlined in `stroke_color`.
fn drawShape(
    f: *z.Frame,
    centre: Vec2,
    shape: Shape,
    half_size: f32,
    fill_color: Color,
    stroke: f32,
    stroke_color: Color,
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
            f.gl.rect(square, .{ .color = stroke_color, .outline = stroke });
        },
        .circle => {
            f.gl.circle(centre, half_size, .{ .color = fill_color });
            f.gl.circle(centre, half_size, .{ .color = stroke_color, .outline = stroke });
        },
    }
}

/// The curve the notes sit on, from note to note round it - the path of thirds: along the arc where it curves, along
/// the line between the bottom notes (`StarCurve`); thick and white, a little thicker than the notes' outlines, so that
/// the circle of thirds reads first. Each link drawn as `params.star.curve_pieces_per_link` short straight pieces, too
/// short for the bend between two to show.
fn drawNotePath(f: *z.Frame, star: StarLayout) void {
    const thickness: f32 = params.star.note_path_thickness_share * strokeThickness(star);
    for (0..7) |circle_place| {
        var previous_point: Vec2 = star.pointAtPlace(@intCast(circle_place), 1);
        for (1..params.star.curve_pieces_per_link + 1) |piece_index| {
            const piece_share: f32 = float(piece_index) / float(params.star.curve_pieces_per_link);
            const place: f32 = float(circle_place) + piece_share;
            const point: Vec2 = star.pointAtFractionalPlace(place, 1);
            f.gl.line(previous_point, point, .{ .color = params.colors.outline, .thickness = thickness });
            previous_point = point;
        }
    }
}

/// A note: its shape - a square on the major side, a circle on the minor - in its color, dimmed until it sounds, in a
/// white outline - black for a note of the chord chosen (`is_chosen`), so that its colored outline stands apart from
/// it (`drawChordOutlines`); its degree, large, and its letter and solfege name beneath.
fn drawNote(
    f: *z.Frame,
    s: *State,
    star: StarLayout,
    degree: u8,
    is_lit: bool,
    is_chosen: bool,
) void {
    const centre: Vec2 = star.noteCentre(degree);
    // The chord the track waits for pulses (`noteWaitingScale`).
    const half_size: f32 = star.noteHalfSize(degree) * noteWaitingScale(f, s, degree);
    const fill_color: Color = colorOfDegree(degree, is_lit);
    const note_shape: Shape = shapeOfDegree(&star.scale, degree);
    const own_outline_color: Color = if (is_chosen) params.colors.chosen_note_outline else params.colors.outline;
    drawShape(f, centre, note_shape, half_size, fill_color, strokeThickness(star), own_outline_color);
    const degree_color: Color = if (is_lit) params.colors.lit_text else params.colors.text;
    const degree_text: [1]u8 = .{'0' + degree};
    const degree_centre: Vec2 = centre - @as(Vec2, .{ 0, 0.25 * half_size });
    drawCentredText(f, s, degree_centre, &degree_text, 0.9 * half_size, degree_color);
    // Named as the scale sounding spells it: G sharp while a borrowed chord held has raised G - and its solfege
    // syllable beside, where the options ask for it (`shows_solfege`).
    var names_buffer: [16]u8 = undefined;
    const note_name: []const u8 = s.scale.noteName(degree);
    const solfege_name: []const u8 = s.scale.solfegeName(degree);
    const names: []const u8 = if (s.shows_solfege)
        bufPrint(&names_buffer, "{s} {s}", .{ note_name, solfege_name }) catch ""
    else
        note_name;
    const names_centre: Vec2 = centre + @as(Vec2, .{ 0, 0.47 * half_size });
    drawCentredText(f, s, names_centre, names, 0.5 * half_size, degree_color);
    // An altered note marked at its top right corner: a round badge with a sharp or a flat - the note is the scale's
    // own degree, raised or lowered for the borrowed chord held.
    const alteration: i8 = s.scale.alterations[degree - 1];
    if (alteration != 0) {
        const badge_centre: Vec2 = centre + @as(Vec2, .{ 0.8 * half_size, -0.8 * half_size });
        const badge_half_size: f32 = 0.32 * half_size;
        drawShape(
            f,
            badge_centre,
            .circle,
            badge_half_size,
            params.colors.text,
            strokeThickness(star),
            params.colors.outline,
        );
        const sign: []const u8 = if (alteration > 0) "#" else "b";
        drawCentredText(f, s, badge_centre, sign, 1.3 * badge_half_size, params.colors.lit_text);
    }
}

/// The star's seven note proxies (`NoteProxy`): each its note's shape, in its note's color, small and faint - a little
/// brighter while its note sounds - with no outline and no name.
fn drawNoteProxies(f: *z.Frame, s: *State, star: StarLayout) void {
    const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    for (noteProxies(star)) |proxy| {
        var fill_color: Color = colorOfDegree(proxy.degree, isDegreeSounding(s, proxy.degree));
        fill_color.a = params.note_proxy.alpha;
        const proxy_shape: Shape = shapeOfDegree(&star.scale, proxy.degree);
        drawShape(f, proxy.centre, proxy_shape, proxy.half_size, fill_color, 0, transparent);
    }
}

/// A chord, as its triplet (`ChordTriplet`): its fifth, then its third, then - in front - its own shape in its root's
/// color, each in its color and dimmed until the chord sounds; and its numeral on the front one, large - 1.4 times
/// the half-size, or smaller where a long numeral, iii or vii, would not fit within the shape (`fittedTextSize`).
fn drawChord(
    f: *z.Frame,
    s: *State,
    star: StarLayout,
    chord: ScaleChord,
    is_lit: bool,
) void {
    const triplet: ChordTriplet = .ofChord(star, chord);
    // The button on the root of the chord the track waits for pulses (`starChordWaitingScale`).
    const half_size: f32 = triplet.half_size * starChordWaitingScale(f, s, chord);
    const stroke: f32 = strokeThickness(star);
    var layer: usize = 3;
    while (layer > 0) {
        layer -= 1;
        const fill_color: Color = colorOfDegree(triplet.degrees[layer], is_lit);
        const shape: Shape = triplet.shapes[layer];
        drawShape(f, triplet.centres[layer], shape, half_size, fill_color, stroke, params.colors.chord_outline);
    }
    const name_color: Color = if (is_lit) params.colors.lit_text else params.colors.text;
    const numeral: []const u8 = chord.numeral();
    const numeral_size: f32 = fittedTextSize(s, numeral, 1.4 * half_size, 1.8 * half_size);
    drawCentredText(f, s, triplet.centres[0], numeral, numeral_size, name_color);
}

// ---- The chord chosen and the chord coming, outlined on the star ----

/// How many chords of the left diagrams fingers hold now - the chooser's, the key's window's, the borrowed ones: two
/// or more held, the chosen chord's outlines are not drawn (`drawChordOutlines`).
fn heldLeftChordCount(s: *const State) usize {
    var count: usize = 0;
    for (s.pointer_holds) |hold_slot| {
        const hold: PointerHold = hold_slot orelse continue;
        switch (hold.target) {
            .chooser_chord, .borrowed_chord => count += 1,
            .note, .chord, .ignored => {},
        }
    }
    return count;
}

/// The outlines' pulse, on the track's tempo: 1 on each beat, falling away to 0 before the next - the track's own
/// beat, or, while it waits for the player and its beats are held, the clock's at its tempo; 0 without a track.
fn outlinePulse(f: *z.Frame, s: *const State) f32 {
    if (!hasTrack(s)) {
        return 0;
    }
    const is_waiting: bool = awaitedChord(s) != null;
    const clock_beats: f64 = @as(f64, f.time.time) * @as(f64, s.progression_beats_per_minute) / 60;
    const beats: f64 = if (is_waiting) clock_beats else s.progression_beat;
    const beat_phase: f32 = @floatCast(beats - @floor(beats));
    const swell: f32 = 1 - beat_phase;
    return swell * swell;
}

/// `color` at `opacity`, 0 to 1.
fn withOpacity(color: Color, opacity: f32) Color {
    var faded: Color = color;
    faded.a = @trunc(255 * clamp(opacity, 0, 1));
    return faded;
}

/// Where the coming chord's outlines stand now, for every view to draw them alike (`drawChordOutlines`,
/// `drawKeyOutlines`, `drawNoteShapeOutlines`): the chord coming; how far they have closed in - 0 as they appear, at
/// the bar's middle, to 1 as the chord arrives; and their opacity, faint as they appear, brightening as they close in,
/// pulsing on the beat (`outlinePulse`).
const ComingOutline = struct {
    chord: ScaleChord,
    closed_share: f32,
    opacity: f32,

    /// How far out an outline is now that sets out `start_reach_share` beyond the gap (`params.outline.gap_share`), as
    /// a share of its note's half-size: all of it as it appears, none - the gap alone - as the chord arrives.
    fn reachShare(coming: ComingOutline, start_reach_share: f32) f32 {
        return params.outline.gap_share + start_reach_share * (1 - coming.closed_share);
    }
};

/// The coming chord's outlines now (`ComingOutline`); null without a track, and over the bar's first half, before
/// they appear (`params.outline.coming_shown_share`).
fn comingOutline(f: *z.Frame, s: *const State) ?ComingOutline {
    if (!hasTrack(s)) {
        return null;
    }
    const chords_gone: f64 = s.progression_beat / params.progression.beats_per_chord;
    const travelled_share: f32 = @floatCast(chords_gone - @floor(chords_gone));
    const appearing_share: f32 = 1 - params.outline.coming_shown_share;
    if (travelled_share < appearing_share) {
        return null;
    }
    const closed_share: f32 = (travelled_share - appearing_share) / params.outline.coming_shown_share;
    const pulse: f32 = outlinePulse(f, s);
    return .{
        .chord = trackChord(s, @trunc(chords_gone)),
        .closed_share = closed_share,
        .opacity = (0.25 + 0.75 * closed_share) * (0.7 + 0.3 * pulse),
    };
}

/// Outlines `degree`'s note on `star` in `color`: its own shape, `reach_share` of its half-size out from it, the line
/// `thickness_share` of its half-size thick - the note's size as drawn, pulsing while the track waits for its chord
/// (`noteWaitingScale`).
fn drawNoteOutline(
    f: *z.Frame,
    s: *const State,
    star: StarLayout,
    degree: u8,
    reach_share: f32,
    thickness_share: f32,
    color: Color,
) void {
    const half_size: f32 = star.noteHalfSize(degree) * noteWaitingScale(f, s, degree);
    const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    const outline_half_size: f32 = half_size * (1 + reach_share);
    const shape: Shape = shapeOfDegree(&star.scale, degree);
    drawShape(f, star.noteCentre(degree), shape, outline_half_size, transparent, thickness_share * half_size, color);
}

/// The chord chosen and the chord coming, outlined on the star - so that a chord chosen on the left, by a finger or by
/// the track, shows where its notes are, the star turning or not, and the track's next chord shows before it comes:
///   the chord chosen: each of its notes in a thick outline, the color of its part in the chord - root, third, fifth
///     (`params.colors.role_outlines`) - its own white outline black (`drawNote`), and its own button in a white one;
///     not while fingers hold two or more of the left diagrams' chords, whose notes then sound together;
///   the chord coming, while a progression is followed: each of its notes in a thinner outline of its part's color,
///     and its button in a white outline twice as thick from five times as far - appearing at the bar's middle, out
///     from them and faint, closing in and brightening, on them when the chord arrives (`comingOutline`). A note of
///     both has both. The keyboard and the circle of the twelve notes outline the same notes alike (`drawKeyOutlines`,
///     `drawNoteShapeOutlines`).
/// Both pulse on the track's tempo (`outlinePulse`); without a track, the chosen chord's outlines hold still.
fn drawChordOutlines(f: *z.Frame, s: *State, star: StarLayout) void {
    const pulse: f32 = outlinePulse(f, s);
    if (comingOutline(f, s)) |coming| {
        const reach_share: f32 = coming.reachShare(params.outline.coming_reach_share);
        const thickness_share: f32 = params.outline.coming_share * (1 + 0.6 * pulse);
        for (coming.chord.degrees(), params.colors.role_outlines) |degree, role_color| {
            const color: Color = withOpacity(role_color, coming.opacity);
            drawNoteOutline(f, s, star, degree, reach_share, thickness_share, color);
        }
        // Its button on the star too - the button on its root, where a borrowed chord's is its root's - in a white
        // outline twice as thick, closing in from five times as far.
        const button_reach_share: f32 = coming.reachShare(
            params.outline.coming_button_reach_factor * params.outline.coming_reach_share,
        );
        const coming_triplet: ChordTriplet = .ofChord(star, coming.chord);
        const coming_half_size: f32 = coming_triplet.half_size * starChordWaitingScale(f, s, coming.chord);
        const coming_transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
        drawShape(
            f,
            coming_triplet.centres[0],
            coming_triplet.shapes[0],
            coming_half_size * (1 + button_reach_share),
            coming_transparent,
            params.outline.coming_button_thickness_factor * thickness_share * coming_half_size,
            withOpacity(params.colors.outline, coming.opacity),
        );
    }
    if (heldLeftChordCount(s) >= 2) {
        return;
    }
    const chosen_chord: ScaleChord = s.scale.chords[s.chosen_chord_index];
    const thickness_share: f32 = params.outline.chosen_share * (1 + 0.6 * pulse);
    for (chosen_chord.degrees(), params.colors.role_outlines) |degree, role_color| {
        drawNoteOutline(f, s, star, degree, params.outline.gap_share, thickness_share, role_color);
    }
    // The chosen chord's own button, the front of its triplet, in white.
    const triplet: ChordTriplet = .ofChord(star, chosen_chord);
    const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    const chosen_half_size: f32 = triplet.half_size * starChordWaitingScale(f, s, chosen_chord);
    const button_outline_half_size: f32 = chosen_half_size * (1 + params.outline.gap_share);
    const button_thickness: f32 = thickness_share * chosen_half_size;
    const button_shape: Shape = triplet.shapes[0];
    drawShape(
        f,
        triplet.centres[0],
        button_shape,
        button_outline_half_size,
        transparent,
        button_thickness,
        params.colors.outline,
    );
}

/// A key of the keyboard a chord's note may be outlined on (`drawKeyOutlines`): where it is drawn, and its degree.
const OutlinedKey = struct {
    rectangle: z.Rectangle,
    degree: u8,
};

/// The chosen chord's and the coming chord's notes outlined on the keyboard's keys, as on the star
/// (`drawChordOutlines`): every key of a note of the chord in an outline of the note's part's colour round the key -
/// thick for the chosen chord, though not while two or more of the left diagrams' chords are held; thin for the
/// coming one, appearing at the bar's middle and closing in (`comingOutline`). The sizes are shares of a key's
/// half-height, as the star's are of a note's half-size.
fn drawKeyOutlines(
    f: *z.Frame,
    s: *State,
    keys: []const OutlinedKey,
    keyboard_height: f32,
) void {
    const half_size: f32 = 0.5 * keyboard_height;
    const pulse: f32 = outlinePulse(f, s);
    if (comingOutline(f, s)) |coming| {
        const thickness: f32 = @max(1, params.outline.coming_share * (1 + 0.6 * pulse) * half_size);
        const reach: f32 = coming.reachShare(params.outline.coming_reach_share) * half_size;
        for (coming.chord.degrees(), params.colors.role_outlines) |degree, role_color| {
            for (keys) |key| {
                if (key.degree == degree) {
                    const outline: z.Rectangle = insetRectangle(key.rectangle, -(reach + thickness));
                    f.gl.rect(outline, .{ .color = withOpacity(role_color, coming.opacity), .outline = thickness });
                }
            }
        }
    }
    if (heldLeftChordCount(s) >= 2) {
        return;
    }
    const chosen_chord: ScaleChord = s.scale.chords[s.chosen_chord_index];
    const thickness: f32 = params.outline.chosen_share * (1 + 0.6 * pulse) * half_size;
    const gap: f32 = params.outline.gap_share * half_size;
    for (chosen_chord.degrees(), params.colors.role_outlines) |degree, role_color| {
        for (keys) |key| {
            if (key.degree == degree) {
                const outline: z.Rectangle = insetRectangle(key.rectangle, -(gap + thickness));
                f.gl.rect(outline, .{ .color = role_color, .outline = thickness });
            }
        }
    }
}

/// The chosen chord's and the coming chord's notes outlined on a view that draws the scale's notes in their shapes as
/// the star does - the circle of the twelve notes - as on the star (`drawChordOutlines`): each note at `places`, of
/// `half_sizes`, by degree.
fn drawNoteShapeOutlines(
    f: *z.Frame,
    s: *State,
    places: *const [7]Vec2,
    half_sizes: *const [7]f32,
) void {
    const pulse: f32 = outlinePulse(f, s);
    const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    if (comingOutline(f, s)) |coming| {
        const reach_share: f32 = coming.reachShare(params.outline.coming_reach_share);
        const thickness_share: f32 = params.outline.coming_share * (1 + 0.6 * pulse);
        for (coming.chord.degrees(), params.colors.role_outlines) |degree, role_color| {
            const half_size: f32 = half_sizes[degree - 1];
            const shape: Shape = shapeOfDegree(&s.scale, degree);
            const color: Color = withOpacity(role_color, coming.opacity);
            const outline_half_size: f32 = half_size * (1 + reach_share);
            drawShape(f, places[degree - 1], shape, outline_half_size, transparent, thickness_share * half_size, color);
        }
    }
    if (heldLeftChordCount(s) >= 2) {
        return;
    }
    const chosen_chord: ScaleChord = s.scale.chords[s.chosen_chord_index];
    const thickness_share: f32 = params.outline.chosen_share * (1 + 0.6 * pulse);
    for (chosen_chord.degrees(), params.colors.role_outlines) |degree, role_color| {
        const half_size: f32 = half_sizes[degree - 1];
        const shape: Shape = shapeOfDegree(&s.scale, degree);
        const outline_half_size: f32 = half_size * (1 + params.outline.gap_share);
        const thickness: f32 = thickness_share * half_size;
        drawShape(f, places[degree - 1], shape, outline_half_size, transparent, thickness, role_color);
    }
}

/// A line of dots from `start` to `end`, moving toward `end`: one every `spacing`, the first `phase` of a spacing from
/// `start` - `phase` grows with time and wraps at 1, so that the dots flow - each colored between `start_color` and
/// `end_color` by how far along it is.
fn drawMovingDots(
    f: *z.Frame,
    start: Vec2,
    end: Vec2,
    start_color: Color,
    end_color: Color,
    spacing: f32,
    phase: f32,
) void {
    const offset: Vec2 = end - start;
    const line_length: f32 = length(offset);
    if (line_length < spacing) {
        return;
    }
    const along: Vec2 = offset / splat2(line_length);
    const dot_radius: f32 = 0.24 * spacing;
    const whole_spacings: usize = @floor(line_length / spacing);
    const dot_count: usize = whole_spacings + 1;
    for (0..dot_count) |dot_index| {
        const distance_along: f32 = (float(dot_index) + phase) * spacing;
        if (distance_along > line_length) {
            break;
        }
        const fraction_along: f32 = distance_along / line_length;
        const dot_color: Color = start_color.lerp(end_color, fraction_along);
        const dot_centre: Vec2 = start + along * splat2(distance_along);
        f.gl.circle(dot_centre, dot_radius, .{ .color = dot_color });
    }
}

/// The chord sounding, named by degrees (`degreeNameOfChord`), large in the middle of `room` - the sounding box - over
/// the chord's curve, which draws the same notes as a figure: as large as half the box's shorter side, or smaller,
/// so that a long name fits within it (`fittedTextSize`).
fn drawChordNumeral(f: *z.Frame, s: *State, room: z.Rectangle) void {
    var name_buffer: [24]u8 = undefined;
    const chord_name: []const u8 = degreeNameOfChord(&name_buffer, s) orelse return;
    const room_centre: Vec2 = .{ room.x + 0.5 * room.width, room.y + 0.5 * room.height };
    const wanted_size: f32 = 0.5 * @min(room.width, room.height);
    const text_size: f32 = fittedTextSize(s, chord_name, wanted_size, 0.9 * room.width);
    // Bolder than the font draws it: the text four times, a few hundredths of its size apart - its strokes
    // thickened by the shift, its shapes kept.
    const stroke_shift: f32 = 0.03 * text_size;
    const shifts = [4]Vec2{ .{ 0, 0 }, .{ stroke_shift, 0 }, .{ 0, stroke_shift }, .{ stroke_shift, stroke_shift } };
    for (shifts) |shift| {
        drawCentredText(f, s, room_centre + shift, chord_name, text_size, params.colors.text);
    }
}

/// The names of the degrees' functions in a key, the tonic's first: what a chord on the degree, or the note alone, is
/// called - the seventh's by its distance from the tonic (`functionNameOfDegree`).
const degree_function_names = [6][]const u8{
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
fn functionNameOfDegree(scale: *const Scale, degree: u8) []const u8 {
    if (degree == 7) {
        const is_half_step_below_tonic: bool = scale.semitones[6] == 11;
        return if (is_half_step_below_tonic) "Leading tone" else "Subtonic";
    }
    return degree_function_names[degree - 1];
}

/// The degree whose function names what sounds (`drawFunctionName`): a note alone, its own; a chord the notes make
/// (`matchedChord`), its root's - from the chosen chord's root when several fit, as its numeral is named
/// (`degreeNameOfChord`); none for two notes, or for notes that make no chord.
fn soundingFunctionDegree(s: *const State) ?u8 {
    const sounding: PitchClassSet = soundingPitchClasses(s);
    const note_count: usize = @popCount(sounding);
    if (note_count == 1) {
        for (all_degrees) |degree| {
            if (isDegreeSounding(s, degree)) {
                return degree;
            }
        }
        return null;
    }
    if (note_count < 3) {
        return null;
    }
    const scale: *const Scale = &s.scale;
    const chosen_root: u4 = scale.pitchClassOfDegree(scale.chords[s.chosen_chord_index].root_degree);
    const match: ChordMatch = matchedChord(sounding, chosen_root) orelse return null;
    return scale.degreeOfPitchClass(match.root);
}

/// What sounds, named by its function in the key - "Dominant" for V, or for the 5 alone - across `band`, the sounding
/// box's bottom, under its figure: as large as most of the band's height, or smaller, so that it fits its width.
fn drawFunctionName(f: *z.Frame, s: *State, band: z.Rectangle) void {
    const degree: u8 = soundingFunctionDegree(s) orelse return;
    const name: []const u8 = functionNameOfDegree(&s.scale, degree);
    const band_centre: Vec2 = .{ band.x + 0.5 * band.width, band.y + 0.5 * band.height };
    const text_size: f32 = fittedTextSize(s, name, 0.7 * band.height, 0.95 * band.width);
    drawCentredText(f, s, band_centre, name, text_size, params.colors.text);
}

/// One end of a line of dots between two buttons - notes or chords: the button's centre, shape and half-size, the
/// dots starting a little outside its edge, and the colour they have there.
const DotsEnd = struct {
    /// The button's centre.
    centre: Vec2,
    /// Its shape: the dots start at its edge.
    shape: Shape,
    /// Its half-size.
    half_size: f32,
    /// The dots' color at this end: they blend from one end's to the other's.
    color: Color,
};

/// Dots moving from `from` toward `to`, from edge to edge - a tenth of a half-size outside each - coloured from
/// `from`'s colour to `to`'s, `spacing` apart (`drawMovingDots`): a step in pitch, wherever it is drawn.
fn drawStepDots(
    f: *z.Frame,
    from: DotsEnd,
    to: DotsEnd,
    spacing: f32,
    phase: f32,
) void {
    const start: Vec2 = shapeEdgeToward(from.centre, from.shape, 1.1 * from.half_size, to.centre);
    const end: Vec2 = shapeEdgeToward(to.centre, to.shape, 1.1 * to.half_size, from.centre);
    drawMovingDots(f, start, end, from.color, to.color, spacing, phase);
}

/// A key's names, centred at `middle_x`: its degree's number with its top near `number_y`, and below it its note's
/// name as the scale spells it, each sized from the keyboard's height.
fn drawKeyNames(
    f: *z.Frame,
    s: *State,
    degree: u8,
    middle_x: f32,
    number_y: f32,
    keyboard: z.Rectangle,
    label_color: Color,
) void {
    var number_buffer: [2]u8 = undefined;
    const number: []const u8 = bufPrint(&number_buffer, "{d}", .{degree}) catch "";
    const number_centre: Vec2 = .{ middle_x, number_y };
    const name_centre: Vec2 = .{ middle_x, number_y + 0.4 * keyboard.height };
    drawCentredText(f, s, number_centre, number, 0.36 * keyboard.height, label_color);
    drawCentredText(f, s, name_centre, s.scale.noteName(degree), 0.3 * keyboard.height, label_color);
}

/// The keyboard along the bottom, as a piano's from the tonic to the tonic above (`PianoLayout`), laid out for the
/// scale sounding - a borrowed chord's raised note on its own key: the white keys first, each a key the scale uses in
/// its degree's color, whole and a little taller while it sounds, the others grey; then the black keys over their
/// edges, a key the scale uses in its degree's color, the others black, each from as high as a sounding white key
/// rises down to 60% of the keyboard's height. Each key the scale uses is named as the chord buttons are: its
/// degree's number, and its note's name as the scale spells it.
fn drawKeyboard(f: *z.Frame, s: *State, keyboard: z.Rectangle) void {
    const scale: *const Scale = &s.scale;
    const layout: PianoLayout = .ofScale(scale);
    const white_width: f32 = keyboard.width / float(layout.white_count);
    // The keys with a degree, to outline over every key once all are drawn (`drawKeyOutlines`).
    var outlined_keys: [params.limits.most_outlined_keys]OutlinedKey = undefined;
    var outlined_count: usize = 0;
    for (0..layout.white_count) |white_index| {
        const degree: ?u8 = layout.degreeAt(scale, layout.whiteSemitones(white_index));
        const is_sounding: bool = if (degree) |key_degree| isDegreeSounding(s, key_degree) else false;
        // A key sounding rises above the others, into the margin above the keyboard.
        const rise: f32 = if (is_sounding) params.keyboard.sounding_key_rise_share * keyboard.height else 0;
        const key: z.Rectangle = .{
            .x = keyboard.x + float(white_index) * white_width,
            .y = keyboard.y - rise,
            .width = white_width,
            .height = keyboard.height + rise,
        };
        const key_color: Color = if (degree) |key_degree|
            colorOfDegree(key_degree, is_sounding)
        else
            params.colors.unused_white_key;
        f.gl.rect(key, .{ .color = key_color });
        f.gl.rect(key, .{ .color = params.colors.background, .outline = 1 });
        // Its names in its middle, which the black keys over its edges leave clear from top to bottom.
        const key_degree: u8 = degree orelse continue;
        outlined_keys[outlined_count] = .{ .rectangle = key, .degree = key_degree };
        outlined_count += 1;
        const key_middle_x: f32 = key.x + 0.5 * white_width;
        const label_color: Color = if (is_sounding) params.colors.lit_text else params.colors.text;
        drawKeyNames(f, s, key_degree, key_middle_x, keyboard.y + 0.3 * keyboard.height, keyboard, label_color);
    }
    const black_width: f32 = params.keyboard.black_key_width_share * white_width;
    const most_rise: f32 = params.keyboard.sounding_key_rise_share * keyboard.height;
    for (0..layout.white_count) |white_index| {
        if (!layout.hasBlackAfter(white_index)) {
            continue;
        }
        const degree: ?u8 = layout.degreeAt(scale, layout.whiteSemitones(white_index) + 1);
        const is_sounding: bool = if (degree) |key_degree| isDegreeSounding(s, key_degree) else false;
        const boundary_x: f32 = keyboard.x + float(white_index + 1) * white_width;
        const black_key: z.Rectangle = .{
            .x = boundary_x - 0.5 * black_width,
            .y = keyboard.y - most_rise,
            .width = black_width,
            .height = params.keyboard.black_key_height_share * keyboard.height + most_rise,
        };
        const key_color: Color = if (degree) |key_degree|
            colorOfDegree(key_degree, is_sounding)
        else
            params.colors.black_key;
        f.gl.rect(black_key, .{ .color = key_color });
        const key_degree: u8 = degree orelse continue;
        outlined_keys[outlined_count] = .{ .rectangle = black_key, .degree = key_degree };
        outlined_count += 1;
        f.gl.rect(black_key, .{ .color = params.colors.background, .outline = 1 });
        const label_color: Color = if (is_sounding) params.colors.lit_text else params.colors.text;
        drawKeyNames(f, s, key_degree, boundary_x, keyboard.y + 0.05 * keyboard.height, keyboard, label_color);
    }
    drawKeyOutlines(f, s, outlined_keys[0..outlined_count], keyboard.height);
}

/// The color the notes sounding are joined in, on both circles: their chord's root's, when they have a name with a
/// root (`nameOfChord`) - grey otherwise.
fn colorOfSoundingNotes(s: *const State, name: ?ChordName) Color {
    const root_pitch_class: ?u4 = if (name) |chord_name| chord_name.root else null;
    const root_degree: ?u8 = if (root_pitch_class) |root| s.scale.degreeOfPitchClass(root) else null;
    return if (root_degree) |degree| params.colors.degrees[degree - 1] else params.colors.outline;
}

/// The chord the notes sounding make, if one does (`matchedChord`): from the chosen chord's root when several fit.
fn soundingChordMatch(s: *const State) ?ChordMatch {
    const scale: *const Scale = &s.scale;
    const chosen_root: u4 = scale.pitchClassOfDegree(scale.chords[s.chosen_chord_index].root_degree);
    return matchedChord(soundingPitchClasses(s), chosen_root);
}

/// The chord played, drawn on a side diagram as the star draws a chord's lines: from its root's corner, a zigzag to
/// its third's, in the third's yellow, and a dashed line to its fifth's, in the fifth's cyan (`drawChordLine`) - the
/// other edges of its polygon left unoutlined. `corner_of_degree` gives each degree's corner on the diagram, null
/// for a note not sounding; `line_unit` the diagram's size unit, which the zigzag's wavelength and the dashes follow.
/// A chord without a third - a suspended one - draws only its fifth's line; two notes a fifth apart, the dashed line.
fn drawChordRoleEdges(
    f: *z.Frame,
    s: *const State,
    corner_of_degree: *const [7]?Vec2,
    line_unit: f32,
) void {
    const match: ChordMatch = soundingChordMatch(s) orelse return;
    const root_degree: u8 = s.scale.degreeOfPitchClass(match.root) orelse return;
    const root_corner: Vec2 = corner_of_degree[root_degree - 1] orelse return;
    const third_degree: u8 = degreeAbove(root_degree, 2);
    const fifth_degree: u8 = degreeAbove(root_degree, 4);
    const thickness: f32 = @max(1.5, 0.12 * line_unit);
    if (corner_of_degree[third_degree - 1]) |third_corner| {
        const third_color: Color = lineColorOfRole(.third);
        const zigzag_wavelength: f32 = 0.35 * line_unit;
        drawZigzag(f, root_corner, third_corner, thickness, zigzag_wavelength, third_color);
    }
    if (corner_of_degree[fifth_degree - 1]) |fifth_corner| {
        const dash_length: f32 = 0.3 * line_unit;
        const fifth_color: Color = lineColorOfRole(.fifth);
        const gap_length: f32 = 0.8 * dash_length;
        f.gl.lineDashed(root_corner, fifth_corner, thickness, dash_length, gap_length, .{ .color = fifth_color });
    }
}

/// Joins `corners`, given in order round their middle: three or more by a polygon filled faintly in `color` - a fan of
/// triangles from the corners' centroid, which covers exactly a polygon whose corners are in order of their angle
/// round it, convex or not - and, when `is_outlined`, outlined in it; two by a line; one, nothing. A chord played is
/// not outlined: its root's edges to its third and fifth are drawn in their roles' styles (`drawChordRoleEdges`).
fn drawSoundingPolygon(
    f: *z.Frame,
    corners: []const Vec2,
    color: Color,
    edge_thickness: f32,
    is_outlined: bool,
) void {
    const corner_count: usize = corners.len;
    const fill_color: Color = color.lerp(params.colors.background, 0.7);
    if (corner_count >= 3) {
        var corner_sum: Vec2 = @splat(0);
        for (corners) |corner| {
            corner_sum += corner;
        }
        const centroid: Vec2 = corner_sum / splat2(float(corner_count));
        for (0..corner_count) |corner_index| {
            const next_corner: Vec2 = corners[(corner_index + 1) % corner_count];
            f.gl.triangle(centroid, corners[corner_index], next_corner, .{ .color = fill_color });
        }
    }
    if (corner_count >= 2 and is_outlined) {
        for (0..corner_count) |corner_index| {
            const next_corner: Vec2 = corners[(corner_index + 1) % corner_count];
            const is_closing_edge_of_a_line: bool = corner_count == 2 and corner_index == 1;
            if (!is_closing_edge_of_a_line) {
                f.gl.line(corners[corner_index], next_corner, .{ .color = color, .thickness = edge_thickness });
            }
        }
    }
}

/// The circle of the twelve notes, at the top of the chooser's column: the pitch classes in order of pitch, the tonic
/// at the top and round clockwise a semitone at a time - so that an interval is a fixed angle, a twelfth of a turn a
/// semitone, and a chord a fixed shape wherever its root. The seven notes of the scale are drawn as in the star, in
/// their shapes and their colors, lit while they sound; the five sharps, which the scale does not use, as small grey
/// dots. The notes that sound are joined - two by a line, three by a triangle, more by the polygon round them - filled
/// faintly with the color of the chord's root, and the chord's name is written in the middle (`nameOfChord`), the kind
/// spelled out beneath it.
fn drawChromaticCircle(f: *z.Frame, s: *State, area: z.Rectangle) void {
    const chromatic: ChromaticLayout = .ofArea(area);
    const centre: Vec2 = chromatic.centre;
    const radius: f32 = chromatic.radius;
    const note_half_size: f32 = chromatic.note_half_size;
    const sharp_dot_radius: f32 = 0.3 * note_half_size;
    const stroke: f32 = @max(1, 0.06 * note_half_size);
    f.gl.circle(centre, radius, .{ .color = params.colors.note_path, .outline = 1 });
    var places: [12]Vec2 = undefined;
    for (&places, 0..) |*place, pitch_class| {
        place.* = chromatic.placeOf(&s.scale, @intCast(pitch_class));
    }
    const sounding: PitchClassSet = soundingPitchClasses(s);
    const name: ?ChordName = nameOfChord(s);
    // The polygon of the notes sounding, in pitch order round the circle: a fan of triangles from the first.
    var corners: [12]Vec2 = undefined;
    var corner_count: usize = 0;
    for (places, 0..) |place, pitch_class| {
        const pitch_class_bit: PitchClassSet = @as(PitchClassSet, 1) << @as(u4, @intCast(pitch_class));
        if (sounding & pitch_class_bit != 0) {
            corners[corner_count] = place;
            corner_count += 1;
        }
    }
    const is_chord_played: bool = soundingChordMatch(s) != null;
    drawSoundingPolygon(f, corners[0..corner_count], colorOfSoundingNotes(s, name), 2 * stroke, !is_chord_played);
    var corner_of_degree: [7]?Vec2 = @splat(null);
    for (&corner_of_degree, all_degrees) |*corner, degree| {
        if (isDegreeSounding(s, degree)) {
            corner.* = places[s.scale.pitchClassOfDegree(degree)];
        }
    }
    drawChordRoleEdges(f, s, &corner_of_degree, note_half_size);
    // The notes over the polygon: the scale's in their shapes, the sharps as dots - each scale note's place and size
    // kept for its outlines after (`drawNoteShapeOutlines`).
    var note_places: [7]Vec2 = undefined;
    var note_half_sizes: [7]f32 = undefined;
    for (places, 0..) |place, pitch_class| {
        const degree: u8 = s.scale.degreeOfPitchClass(@intCast(pitch_class)) orelse {
            f.gl.circle(place, sharp_dot_radius, .{ .color = params.colors.dim_text });
            continue;
        };
        const is_lit: bool = isDegreeSounding(s, degree);
        const fill_color: Color = colorOfDegree(degree, is_lit);
        // A note at rest a quarter smaller than one sounding: what sounds stands out.
        const resting_half_size: f32 = ChromaticLayout.resting_note_scale * note_half_size;
        const shown_half_size: f32 = if (is_lit) note_half_size else resting_half_size;
        note_places[degree - 1] = place;
        note_half_sizes[degree - 1] = shown_half_size;
        drawShape(
            f,
            place,
            shapeOfDegree(&s.scale, degree),
            shown_half_size,
            fill_color,
            stroke,
            params.colors.outline,
        );
        const letter_color: Color = if (is_lit) params.colors.lit_text else params.colors.text;
        drawCentredText(f, s, place, s.scale.noteName(degree), 1.1 * shown_half_size, letter_color);
    }
    drawNoteShapeOutlines(f, s, &note_places, &note_half_sizes);
    const chord_name: ChordName = name orelse return;
    const symbol_size: f32 = 0.42 * radius;
    const description_size: f32 = 0.16 * radius;
    const symbol_centre: Vec2 = centre - @as(Vec2, .{ 0, 0.08 * radius });
    drawCentredText(f, s, symbol_centre, chord_name.symbol(), symbol_size, params.colors.text);
    if (chord_name.description.len > 0) {
        const description_centre: Vec2 = centre + @as(Vec2, .{ 0, 0.3 * radius });
        drawCentredText(f, s, description_centre, chord_name.description, description_size, params.colors.dim_text);
    }
}

/// The notes sounding, on the chooser: each note stands for the chord built on it, and the chords' buttons of the notes
/// sounding are joined - two by a line, three by a triangle, more by the polygon round them - filled faintly with the
/// color of the chord's root, as on the circle of the twelve notes, beneath the buttons. A triad's three notes are
/// neighbours on the circle of thirds, and so are the three chords built on them: its triangle joins three
/// neighbouring buttons, its own and the two after it.
fn drawChooserPolygon(f: *z.Frame, s: *State, chooser: ChooserLayout) void {
    // The corners in the order of the buttons round the circle - the order of their notes on the circle of thirds -
    // so that no edge crosses another.
    var corners: [7]Vec2 = undefined;
    var corner_count: usize = 0;
    for (0..7) |place_index| {
        const degree: u8 = degreeAtPlace(@intCast(place_index));
        if (isDegreeSounding(s, degree)) {
            corners[corner_count] = chooser.chordCentre(s.scale.chordOf(degree));
            corner_count += 1;
        }
    }
    const edge_thickness: f32 = @max(1.5, 0.1 * chooser.size_unit);
    const is_chord_played: bool = soundingChordMatch(s) != null;
    const polygon_color: Color = colorOfSoundingNotes(s, nameOfChord(s));
    drawSoundingPolygon(f, corners[0..corner_count], polygon_color, edge_thickness, !is_chord_played);
    var corner_of_degree: [7]?Vec2 = @splat(null);
    for (&corner_of_degree, all_degrees) |*corner, degree| {
        if (isDegreeSounding(s, degree)) {
            corner.* = chooser.chordCentre(s.scale.chords[degree - 1]);
        }
    }
    drawChordRoleEdges(f, s, &corner_of_degree, chooser.size_unit);
}

/// A chord's button as the left hand's column draws it - on the chooser and on the key's window, at the same sizes:
/// its shape at `centre`, `half_size`, in its root's color, lit while chosen and dimmed otherwise, with its numeral
/// above its letters, large enough to read at a glance - 70% and 52% of its half-size, the two lines spread so that
/// they keep inside a circle's narrower top and bottom. `size_unit` is the chooser's (`ChooserLayout.size_unit`),
/// which its outline follows.
fn drawChordButton(
    f: *z.Frame,
    s: *State,
    centre: Vec2,
    half_size: f32,
    chord: ScaleChord,
    is_chosen: bool,
    size_unit: f32,
) void {
    const fill_color: Color = colorOfDegree(chord.root_degree, is_chosen);
    const stroke: f32 = @max(1.5, 0.07 * size_unit);
    drawShape(f, centre, shapeOfChord(chord), half_size, fill_color, stroke, params.colors.chord_outline);
    const name_color: Color = if (is_chosen) params.colors.lit_text else params.colors.text;
    const numeral_centre: Vec2 = centre - @as(Vec2, .{ 0, 0.27 * half_size });
    const letters_centre: Vec2 = centre + @as(Vec2, .{ 0, 0.45 * half_size });
    drawCentredText(f, s, numeral_centre, chord.numeral(), 0.7 * half_size, name_color);
    var letters_buffer: [8]u8 = undefined;
    const letter_name: []const u8 = chordLetterName(&letters_buffer, &s.scale, chord);
    drawCentredText(f, s, letters_centre, letter_name, 0.525 * half_size, name_color);
}

/// The borrowed chords' buttons (`offeredBorrowedChords`), on the chooser and on the key's window: each the chooser's
/// button for the borrowed chord, smaller, beside its root's chord, lit while held.
fn drawBorrowedButtons(f: *z.Frame, s: *State, window_layout: WindowLayout) void {
    var offered_buffer: [params.limits.most_offered_borrowed_chords]ScaleChord = undefined;
    const offered: []const ScaleChord = offeredBorrowedChords(s, &offered_buffer);
    const chooser: ChooserLayout = window_layout.chooser;
    for (offered) |chord| {
        const is_held: bool = isBorrowedChordHeld(s, chord);
        const scale: f32 = leftChordWaitingScale(f, s, chord);
        const on_chooser: ButtonPlace = chooserBorrowedButton(chooser, chord);
        drawChordButton(f, s, on_chooser.centre, scale * on_chooser.half_size, chord, is_held, chooser.size_unit);
        const on_fifths: ButtonPlace = fifthsBorrowedButton(window_layout.fifths, chord);
        drawChordButton(f, s, on_fifths.centre, scale * on_fifths.half_size, chord, is_held, chooser.size_unit);
    }
}

/// A chord of the chooser, at its place there (`drawChordButton`).
fn drawChooserChord(
    f: *z.Frame,
    s: *State,
    chooser: ChooserLayout,
    chord: ScaleChord,
    is_chosen: bool,
) void {
    const centre: Vec2 = chooser.chordCentre(chord);
    // The chord the track waits for pulses (`leftChordWaitingScale`).
    const waiting_scale: f32 = leftChordWaitingScale(f, s, chord);
    const half_size: f32 = columnChordHalfSize(chooser, chord, is_chosen) * waiting_scale;
    drawChordButton(f, s, centre, half_size, chord, is_chosen, chooser.size_unit);
}

/// One end of a column star's dots (`drawColumnStar`): the button of the chord on `degree`, at its corner and of its
/// half-size, in full colour while `is_lit`, and a little dimmed otherwise (`params.column_dots.resting_dimming`) -
/// less than a resting button, so that the steps read clearly between the buttons.
fn columnDotsEnd(
    s: *const State,
    corner_centres: *const [7]Vec2,
    corner_half_sizes: *const [7]f32,
    degree: u8,
    is_lit: bool,
) DotsEnd {
    const chord: ScaleChord = s.scale.chords[degree - 1];
    const whole_color: Color = params.colors.degrees[degree - 1];
    return .{
        .centre = corner_centres[degree - 1],
        .shape = shapeOfChord(chord),
        .half_size = corner_half_sizes[degree - 1],
        .color = if (is_lit)
            whole_color
        else
            whole_color.lerp(params.colors.background, params.column_dots.resting_dimming),
    };
}

/// The star of the scale's steps in pitch on the left hand's column - the chooser's and the key's window's: the seven
/// notes joined in order of pitch - 1 to 2, 2 to 3, and on round to 7 and back to 1 - from chord to chord, each chord
/// standing for the note it is built on, at `corner_centres` (the chords on 1 to 7), of `corner_half_sizes` - each
/// diagram's own buttons' sizes, the dots starting at their edges. On the chooser the chords' places
/// follow the circle of thirds, a step up in pitch is three places round it, and the path is a seven-pointed star.
/// Each step is drawn as the star's steps in pitch are: dots flowing from the lower note toward the upper, coloured
/// from one note's colour to the other's - dimmed, and in full colour around each note sounding, its step from below
/// and its step above.
fn drawColumnStar(
    f: *z.Frame,
    s: *State,
    chooser: ChooserLayout,
    corner_centres: *const [7]Vec2,
    corner_half_sizes: *const [7]f32,
) void {
    const phase: f32 = @mod(f.time.time * params.column_dots.dots_per_second, 1);
    const spacing: f32 = params.column_dots.spacing_units * chooser.size_unit;
    for (all_degrees) |degree| {
        const next_degree: u8 = degreeAbove(degree, 1);
        const is_lit: bool = isDegreeSounding(s, degree) or isDegreeSounding(s, next_degree);
        const from_end: DotsEnd = columnDotsEnd(s, corner_centres, corner_half_sizes, degree, is_lit);
        const to_end: DotsEnd = columnDotsEnd(s, corner_centres, corner_half_sizes, next_degree, is_lit);
        drawStepDots(f, from_end, to_end, spacing, phase);
    }
}

/// Where a chart's places are (`drawGuitarChord`): its grid, its marks' row, its spacings, its window's first fret,
/// and a dot's radius.
const GuitarPlaces = struct {
    /// The grid of strings and frets.
    grid: z.Rectangle,
    /// The height of the row over it, where the x and o marks go.
    marks_height: f32,
    /// The distance between two strings.
    string_spacing: f32,
    /// The distance between two frets.
    fret_spacing: f32,
    /// The window's first fret.
    window_start: u8,
    /// A plain dot's radius.
    dot_radius: f32,

    /// The place of `fret` on string `string_index`: between its fret lines, or, for 0, in the marks' row over the
    /// string.
    fn fretPlace(places: GuitarPlaces, string_index: usize, fret: u8) Vec2 {
        const string_x: f32 = places.grid.x + float(string_index) * places.string_spacing;
        if (fret == 0) {
            return .{ string_x, places.grid.y - 0.5 * places.marks_height };
        }
        const frets_down: f32 = float(fret - places.window_start) + 0.5;
        return .{ string_x, places.grid.y + frets_down * places.fret_spacing };
    }
};

/// Every note sounding that a chart's window could play, other than the chart's own: on each string, open or at each
/// fret of the window, where the note there is one sounding - by any finger anywhere, a key, a note on the star -
/// a ring in its color, where a finger could press it to play the note on the guitar.
fn drawSoundingPlaces(
    f: *z.Frame,
    s: *State,
    places: GuitarPlaces,
    guitar_chord: GuitarChord,
) void {
    const sounding: PitchClassSet = soundingPitchClasses(s);
    if (sounding == 0) {
        return;
    }
    const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    const window_end: u8 = places.window_start + params.guitar.window_frets;
    for (0..6) |string_index| {
        var fret: u8 = 0;
        while (fret < window_end) : (fret += if (fret == 0) places.window_start else 1) {
            if (guitar_chord.frets[string_index] == fret) {
                continue;
            }
            const pitch_class: u4 = guitarPitchClass(string_index, fret);
            const is_pitch_class_sounding: bool = sounding & (@as(PitchClassSet, 1) << pitch_class) != 0;
            if (!is_pitch_class_sounding) {
                continue;
            }
            const degree: ?u8 = s.scale.degreeOfPitchClass(pitch_class);
            const note_color: Color = if (degree) |chord_degree|
                colorOfDegree(chord_degree, true)
            else
                params.colors.text;
            const ring_radius: f32 = if (fret == 0) 0.32 * places.marks_height else places.dot_radius;
            drawShape(f, places.fretPlace(string_index, fret), .circle, ring_radius, transparent, 1.5, note_color);
        }
    }
}

/// A guitar chord's diagram in `box`, as chord charts draw one: the strings upright, the lowest at the left, across a
/// window of four frets, the nut along the top when the window starts at the first fret, else the window's first fret's
/// number at its left; over each string, an x for a string not played, or a ring for an open one; on it, a dot for the
/// fret pressed, in the color of the note it sounds - so that the fingering shows the chord's root, third and fifth as
/// the app colors them everywhere - and a barre as a bar across the strings it covers. The chord's own notes are drawn
/// whole and large (`params.guitar.chart_note_scale`), sounding or not, overlapping where they meet - the chord's shape
/// reads at a glance - each ringed in white while it sounds; the lines brighten while the whole chord sounds
/// (`is_lit`). And every other note sounding that the window could play - on any string, at any fret of the window or
/// open - is shown where it could be pressed, as a ring in its color (`drawSoundingPlaces`): a chord played elsewhere,
/// Am7 on the keyboard, shows over the Am chart where its G could go.
fn drawGuitarChord(
    f: *z.Frame,
    s: *State,
    box: z.Rectangle,
    guitar_chord: GuitarChord,
    is_lit: bool,
) void {
    // The grid: six strings across, four frets down, below a row for the marks over the strings.
    const marks_height: f32 = 0.16 * box.height;
    const grid: z.Rectangle = .{
        .x = box.x + 0.14 * box.width,
        .y = box.y + marks_height,
        .width = 0.8 * box.width,
        .height = box.height - marks_height - 0.04 * box.height,
    };
    const string_spacing: f32 = grid.width / 5;
    const fret_spacing: f32 = grid.height / float(params.guitar.window_frets);
    const line_color: Color = if (is_lit) params.colors.text else params.colors.guitar_line;
    for (0..6) |string_index| {
        const string_x: f32 = grid.x + float(string_index) * string_spacing;
        const string_bottom: Vec2 = .{ string_x, grid.y + grid.height };
        f.gl.line(.{ string_x, grid.y }, string_bottom, .{ .color = line_color, .thickness = 1 });
    }
    for (0..params.guitar.window_frets + 1) |fret_line| {
        const fret_y: f32 = grid.y + float(fret_line) * fret_spacing;
        const is_nut: bool = fret_line == 0 and guitar_chord.window_start == 1;
        const thickness: f32 = if (is_nut) 3 else 1;
        const fret_right: Vec2 = .{ grid.x + grid.width, fret_y };
        f.gl.line(.{ grid.x, fret_y }, fret_right, .{ .color = line_color, .thickness = thickness });
    }
    if (guitar_chord.window_start > 1) {
        var fret_number_buffer: [3]u8 = undefined;
        const fret_number: []const u8 = bufPrint(&fret_number_buffer, "{d}", .{guitar_chord.window_start}) catch "";
        const number_centre: Vec2 = .{ box.x + 0.06 * box.width, grid.y + 0.5 * fret_spacing };
        drawCentredText(f, s, number_centre, fret_number, 0.8 * fret_spacing, line_color);
    }
    const places: GuitarPlaces = .{
        .grid = grid,
        .marks_height = marks_height,
        .string_spacing = string_spacing,
        .fret_spacing = fret_spacing,
        .window_start = guitar_chord.window_start,
        .dot_radius = 0.36 * @min(string_spacing, fret_spacing),
    };
    // A barre: a bar across the strings it covers, under their dots.
    if (guitar_chord.barre) |barre| {
        const bar_centre: Vec2 = places.fretPlace(barre.from_string, barre.fret);
        const bar: z.Rectangle = .{
            .x = bar_centre[0] - places.dot_radius,
            .y = bar_centre[1] - 0.6 * places.dot_radius,
            .width = grid.x + grid.width - bar_centre[0] + 2 * places.dot_radius,
            .height = 1.2 * places.dot_radius,
        };
        f.gl.rect(bar, .{ .color = line_color });
    }
    for (guitar_chord.frets, 0..) |maybe_fret, string_index| {
        const fret: u8 = maybe_fret orelse {
            drawCentredText(f, s, places.fretPlace(string_index, 0), "x", 0.9 * marks_height, line_color);
            continue;
        };
        // The chord's own notes whole and large, sounding or not, each ringed in white while it sounds.
        const degree: ?u8 = s.scale.degreeOfPitchClass(guitarPitchClass(string_index, fret));
        const is_sounding: bool = if (degree) |chord_degree| isDegreeSounding(s, chord_degree) else false;
        const note_color: Color = if (degree) |chord_degree| colorOfDegree(chord_degree, true) else params.colors.text;
        const place: Vec2 = places.fretPlace(string_index, fret);
        const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
        const radius: f32 = if (fret == 0)
            params.guitar.chart_note_scale * 0.32 * marks_height
        else
            params.guitar.chart_note_scale * places.dot_radius;
        if (fret == 0) {
            drawShape(f, place, .circle, radius, transparent, 2, note_color);
        } else {
            f.gl.circle(place, radius, .{ .color = note_color });
        }
        if (is_sounding) {
            drawShape(f, place, .circle, radius + 1.5, transparent, 1.5, params.colors.text);
        }
    }
    drawSoundingPlaces(f, s, places, guitar_chord);
}

/// The key's window on the circle of fifths (`FifthsLayout`): the star of steps in pitch between its chords
/// (`drawColumnStar`), then each chord as its shape - a square for a major chord, a circle for the others - filled
/// dark over the dots, faintly in the chord's color while it sounds, and outlined in the chord's color, bright and
/// thicker while chosen; in it, the chord as fingered on a guitar (`drawGuitarChord`); above it, its name.
fn drawFifths(
    f: *z.Frame,
    s: *State,
    fifths: FifthsLayout,
    chooser: ChooserLayout,
) void {
    const half_size: f32 = fifths.shapeHalfSize();
    var corner_centres: [7]Vec2 = undefined;
    for (&corner_centres, all_degrees) |*corner_centre, degree| {
        corner_centre.* = fifths.cellCentre(FifthsLayout.cellOfDegree(degree));
    }
    const corner_half_sizes: [7]f32 = @splat(half_size);
    drawColumnStar(f, s, chooser, &corner_centres, &corner_half_sizes);
    for (FifthsLayout.cells) |cell| {
        const chord: ScaleChord = s.scale.chords[cell.degree - 1];
        const is_chosen: bool = cell.degree - 1 == s.chosen_chord_index;
        const is_lit: bool = isChordSounding(s, chord);
        const root_color: Color = params.colors.degrees[cell.degree - 1];
        const fill_color: Color = if (is_lit)
            root_color.lerp(params.colors.background, 0.75)
        else
            params.colors.background;
        const edge_color: Color = colorOfDegree(cell.degree, is_chosen or is_lit);
        const edge_thickness: f32 = if (is_chosen) 3.5 else 2;
        const shape: Shape = shapeOfChord(chord);
        const centre: Vec2 = fifths.cellCentre(cell);
        // The chord the track waits for pulses (`leftChordWaitingScale`): its shape, round its chart.
        const cell_half_size: f32 = half_size * leftChordWaitingScale(f, s, chord);
        drawShape(f, centre, shape, cell_half_size, fill_color, edge_thickness, edge_color);
        const guitar_chord: GuitarChord = fifths.guitar_chords[cell.degree - 1];
        drawGuitarChord(f, s, fifths.diagramBox(cell, shape), guitar_chord, is_lit);
        // Its name above it, outside, leaving the shape to the chord: its letters - Em - the numeral being the
        // chooser's.
        var letters_buffer: [8]u8 = undefined;
        const name: []const u8 = chordLetterName(&letters_buffer, &s.scale, chord);
        const name_height: f32 = fifths.nameHeight();
        const name_centre: Vec2 = centre - Vec2{ 0, cell_half_size + 0.5 * name_height };
        const name_size: f32 = fittedTextSize(s, name, 0.9 * name_height, 2.4 * half_size);
        drawCentredText(f, s, name_centre, name, name_size, colorOfDegree(cell.degree, true));
    }
}

/// The chooser's star (`drawColumnStar`), its corners the chooser's chords.
fn drawChooserStar(f: *z.Frame, s: *State, chooser: ChooserLayout) void {
    var corner_centres: [7]Vec2 = undefined;
    for (&corner_centres, all_degrees) |*corner_centre, degree| {
        corner_centre.* = chooser.chordCentre(s.scale.chords[degree - 1]);
    }
    var corner_half_sizes: [7]f32 = undefined;
    for (&corner_half_sizes, all_degrees) |*corner_half_size, degree| {
        const is_chosen: bool = degree - 1 == s.chosen_chord_index;
        corner_half_size.* = columnChordHalfSize(chooser, s.scale.chords[degree - 1], is_chosen);
    }
    drawColumnStar(f, s, chooser, &corner_centres, &corner_half_sizes);
}

/// A chord's button as a ghost: the button (`drawChordButton`) with every colour at `opacity` - its fill, its outline
/// and its letters.
fn drawFadedChordButton(
    f: *z.Frame,
    s: *State,
    centre: Vec2,
    half_size: f32,
    chord: ScaleChord,
    opacity: f32,
) void {
    const alpha: u8 = @trunc(255 * clamp(opacity, 0, 1));
    var fill_color: Color = colorOfDegree(chord.root_degree, true);
    fill_color.a = alpha;
    var outline: Color = params.colors.chord_outline;
    outline.a = alpha;
    drawShape(f, centre, shapeOfChord(chord), half_size, fill_color, @max(1, 0.05 * half_size), outline);
    var name_color: Color = params.colors.lit_text;
    name_color.a = alpha;
    drawCentredText(f, s, centre - @as(Vec2, .{ 0, 0.2 * half_size }), chord.numeral(), 0.6 * half_size, name_color);
}

/// Where the track's chord at `step` is played on the chooser: a borrowed chord on its own small button
/// (`chooserBorrowedButton`) - Hotel California's F# in D, beside the scale's F#m - any other on the scale's chord on
/// its root, at the size the chooser draws it.
fn progressionChordButton(
    s: *const State,
    chooser: ChooserLayout,
    step: usize,
) ButtonPlace {
    const chord: ScaleChord = trackChord(s, step);
    const own_chord_index: usize = chord.root_degree - 1;
    const own_chord: ScaleChord = s.chosen_scale.chords[own_chord_index];
    if (chord.quality != own_chord.quality) {
        return chooserBorrowedButton(chooser, chord);
    }
    const is_chosen: bool = own_chord_index == s.chosen_chord_index;
    return .{
        .centre = chooser.chordCentre(own_chord),
        .half_size = columnChordHalfSize(chooser, own_chord, is_chosen),
    };
}

/// The chosen progression's track, in the chooser's middle - a picture to learn it by, which plays nothing and
/// presses nothing. The progression's chords come one a bar (`params.progression.beats_per_chord`), over and over: each
/// appears at the chooser's centre a bar before its turn, a small faint ghost of its button, and travels out along
/// the line to its button, growing and filling in, to reach it on the bar's first beat - when it is the chord to
/// play. The first chord has the first bar to come in: chord k arrives at beat 4 (k + 1). While a chord is the one to
/// play, a ring round its button swells on each beat and settles before the next. Following the player
/// (`progression_waits_for_player`), a chord that reaches its button waits there, pulsing, ringed, until it is played;
/// played before it gets there, it starts at once (`takeProgressionChord`).
fn drawProgressionTrack(f: *z.Frame, s: *State, chooser: ChooserLayout) void {
    const chords_gone: f64 = s.progression_beat / params.progression.beats_per_chord;
    const whole_chords_gone: f64 = @floor(chords_gone);
    const travelled_share: f32 = @floatCast(chords_gone - whole_chords_gone);
    const arriving_chord: usize = @trunc(whole_chords_gone);
    // The chord on its way: from the centre to its button, a third of its size and faint at the start, whole and
    // nearly opaque on arrival.
    // It is shown as the progression's chord - a borrowed one as itself - and lands on the button of the scale's chord
    // on its root.
    const arriving_chord_of_scale: ScaleChord = trackChord(s, arriving_chord);
    const arriving_degree: u8 = arriving_chord_of_scale.root_degree;
    // A borrowed chord lands on its own small button; any other on the chord on its root.
    const button_centre: Vec2 = progressionChordButton(s, chooser, arriving_chord).centre;
    const travel_offset: Vec2 = (button_centre - chooser.centre) * splat2(travelled_share);
    const arriving_centre: Vec2 = chooser.centre + travel_offset;
    const full_half_size: f32 = columnChordHalfSize(chooser, arriving_chord_of_scale, false);
    const arriving_half_size: f32 = full_half_size * (0.35 + 0.65 * travelled_share);
    // Following the player, a chord held at its button waits to be played: it pulses, twice a second - on the
    // clock, the track's beats being held - and a ring round it asks for the touch.
    const is_waiting: bool = s.progression_waits_for_player and arriving_chord == s.progression_chords_taken and
        travelled_share > 0.999;
    const waiting_pulse: f32 = 0.5 + 0.5 * sinTurns(@as(f32, @floatCast(f.time.time)) * 2);
    const arriving_opacity: f32 = if (is_waiting) 0.55 + 0.4 * waiting_pulse else 0.25 + 0.65 * travelled_share;
    drawFadedChordButton(f, s, arriving_centre, arriving_half_size, arriving_chord_of_scale, arriving_opacity);
    if (is_waiting) {
        var waiting_ring_color: Color = params.colors.degrees[arriving_degree - 1];
        waiting_ring_color.a = @trunc(255 * (0.4 + 0.6 * waiting_pulse));
        const waiting_ring_half_size: f32 = full_half_size * (1.25 + 0.15 * waiting_pulse);
        const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
        const ring_thickness: f32 = @max(2, 0.12 * chooser.size_unit);
        const shape: Shape = shapeOfChord(arriving_chord_of_scale);
        drawShape(f, button_centre, shape, waiting_ring_half_size, transparent, ring_thickness, waiting_ring_color);
    }
    // The chord to play now - the one that arrived last - ringed on its own button, the ring swelling on each beat:
    // a borrowed chord on its small button, as it arrived, not on the scale's chord on its root.
    if (arriving_chord == 0) {
        return;
    }
    const playing_chord: ScaleChord = trackChord(s, arriving_chord - 1);
    const playing_degree: u8 = playing_chord.root_degree;
    const playing_button: ButtonPlace = progressionChordButton(s, chooser, arriving_chord - 1);
    const beat_share: f32 = @floatCast(s.progression_beat - @floor(s.progression_beat));
    const swell: f32 = 1 - beat_share;
    const ring_half_size: f32 = playing_button.half_size * (1.2 + 0.25 * swell * swell);
    var ring_color: Color = params.colors.degrees[playing_degree - 1];
    ring_color.a = @trunc(255 * (0.5 + 0.5 * swell));
    const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    const ring_thickness: f32 = @max(2, 0.15 * chooser.size_unit);
    const ring_shape: Shape = shapeOfChord(playing_chord);
    drawShape(f, playing_button.centre, ring_shape, ring_half_size, transparent, ring_thickness, ring_color);
}

/// A carried chord over one of the editor's boxes: the box, and the chord it would take.
const CarriedOverBox = struct {
    box_index: usize,
    chord: ScaleChord,
};

/// The box a carried chord is over (`ChordDrag`), once its finger has left where it came down - the first such, if
/// two fingers carry chords over boxes - or null.
fn carriedOverBox(s: *const State, parts: WindowParts) ?CarriedOverBox {
    for (s.chord_drags) |drag_slot| {
        const drag: ChordDrag = drag_slot orelse continue;
        if (!drag.hasLeftStart()) {
            continue;
        }
        const box_index: usize = parts.editorBoxAt(progressionBoxCount(s), drag.position) orelse continue;
        return .{ .box_index = box_index, .chord = drag.chord };
    }
    return null;
}

/// The progression editor along the star's top (`WindowParts.editor`): a row of boxes, 2 to 16 - the progression the
/// track plays, a box a bar, the empty ones passed over (`trackChord`). A box holding a chord shows it as the chooser
/// does, in its shape and colour with its numeral and its name (`drawChordButton`); an empty one is only its outline.
/// The box whose chord plays now is outlined in white, as the chosen chord's button is, the outline swelling on each
/// beat (`outlinePulse`), and a thin white playhead crosses it through its bar; the chord the track waits for pulses
/// in its box as everywhere (`waitingScale`); a box a carried chord is over shows that chord in its place, outlined
/// in the chord's colour, ready to take it.
fn drawProgressionEditor(
    f: *z.Frame,
    s: *State,
    parts: WindowParts,
    size_unit: f32,
) void {
    const box_count: usize = progressionBoxCount(s);
    const playing_box: ?usize = playingBoxIndex(s);
    const pulse: f32 = outlinePulse(f, s);
    // The box of the chord the track waits for, which pulses as the chord does everywhere (`waitingScale`).
    const awaited_box: ?usize = if (awaitedChord(s) != null) trackBoxIndex(s, s.progression_chords_taken) else null;
    // The box a carried chord is over shows that chord, as it will hold it once the finger lifts (`carriedOverBox`).
    const carried: ?CarriedOverBox = carriedOverBox(s, parts);
    for (0..box_count) |box_index| {
        const box: z.Rectangle = parts.editorBox(box_count, box_index);
        f.gl.rect(box, .{ .color = params.colors.left_diagram_box, .outline = 1 });
        const is_playing: bool = playing_box == box_index;
        const is_carried_over: bool = carried != null and carried.?.box_index == box_index;
        const shown_chord: ?ScaleChord = if (is_carried_over) carried.?.chord else s.progression_boxes[box_index];
        if (shown_chord) |chord| {
            const centre: Vec2 = .{ box.x + 0.5 * box.width, box.y + 0.5 * box.height };
            const box_scale: f32 = if (awaited_box == box_index) waitingScale(f, s) else 1;
            const half_size: f32 = 0.4 * @min(box.width, box.height) * box_scale;
            drawChordButton(f, s, centre, half_size, chord, is_playing, size_unit);
        }
        if (is_playing) {
            const thickness: f32 = 2 + 2 * pulse;
            f.gl.rect(insetRectangle(box, -thickness), .{ .color = params.colors.outline, .outline = thickness });
            // The playhead: a thin white line across the box, from its left edge as its bar begins to its right edge
            // as the bar ends - held there while the track waits for the player.
            const bars: f64 = s.progression_beat / params.progression.beats_per_chord;
            const bar_share: f32 = @floatCast(bars - @floor(bars));
            const playhead_x: f32 = box.x + bar_share * box.width;
            const playhead: z.Rectangle = .{
                .x = playhead_x - 0.5 * params.progression.playhead_width,
                .y = box.y,
                .width = params.progression.playhead_width,
                .height = box.height,
            };
            f.gl.rect(playhead, .{ .color = params.colors.outline });
        }
        if (is_carried_over) {
            const chord_color: Color = params.colors.degrees[carried.?.chord.root_degree - 1];
            f.gl.rect(insetRectangle(box, -3), .{ .color = chord_color, .outline = 3 });
        }
    }
}

/// The chords the fingers carry (`ChordDrag`), each as a ghost of its button under its finger once the finger has
/// left where it came down, the size of an editor's box's chord - but over a box, where the box shows the chord in
/// its place instead (`drawProgressionEditor`).
fn drawCarriedChords(f: *z.Frame, s: *State, parts: WindowParts) void {
    const half_size: f32 = 0.4 * parts.editor.height;
    const box_count: usize = progressionBoxCount(s);
    for (s.chord_drags) |drag_slot| {
        const drag: ChordDrag = drag_slot orelse continue;
        const is_over_box: bool = parts.editorBoxAt(box_count, drag.position) != null;
        if (drag.hasLeftStart() and !is_over_box) {
            drawFadedChordButton(f, s, drag.position, half_size, drag.chord, 0.75);
        }
    }
}

/// The window: the line of text at the top, the chooser with its chosen chord lit, a faint line between the two parts,
/// and the star, as it is shown now (`StarTransition.shownTurn`).
fn draw(f: *z.Frame, s: *State, window_layout: WindowLayout) void {
    // The diagrams round the star each in a thin box, apart from each other and from it: the left hand's two, the
    // circle's square and the sounding box at the right.
    const parts: WindowParts = window_layout.parts;
    const boxed_parts = [4]z.Rectangle{ parts.fifths, parts.chooser, parts.chromatic, parts.sounding };
    for (boxed_parts) |part| {
        f.gl.rect(
            insetRectangle(part, params.window.left_diagram_box_inset),
            .{ .color = params.colors.left_diagram_box, .outline = 1 },
        );
    }
    drawFifths(f, s, window_layout.fifths, window_layout.chooser);
    drawChromaticCircle(f, s, insetRectangle(parts.chromatic, params.window.left_diagram_padding));
    // What sounds: its figure, its name over it, and under them, in the box's bottom band, its function in the key.
    const sounding_room: z.Rectangle = insetRectangle(parts.sounding, params.window.left_diagram_padding);
    const name_band_height: f32 = params.sounding.function_name_band_share * sounding_room.height;
    var figure_room: z.Rectangle = sounding_room;
    figure_room.height -= name_band_height;
    var name_band: z.Rectangle = sounding_room;
    name_band.y += figure_room.height;
    name_band.height = name_band_height;
    drawChordCurve(f, s, figure_room);
    drawChordNumeral(f, s, figure_room);
    drawFunctionName(f, s, name_band);
    // The chooser's middle: the star of steps and the notes sounding, under the buttons - or, while a progression is
    // chosen, its track, drawn over them below, its chords landing on their buttons.
    const is_progression_shown: bool = hasTrack(s);
    if (!is_progression_shown) {
        drawChooserStar(f, s, window_layout.chooser);
        drawChooserPolygon(f, s, window_layout.chooser);
    }
    for (s.scale.chords, 0..) |chord, chord_index| {
        drawChooserChord(f, s, window_layout.chooser, chord, chord_index == s.chosen_chord_index);
    }
    drawBorrowedButtons(f, s, window_layout);
    if (is_progression_shown) {
        drawProgressionTrack(f, s, window_layout.chooser);
    }
    const now_seconds: f32 = f.time.time;
    const shown_turn: f32 = s.transition.shownTurn(now_seconds);
    const shown_minor_side_outside: f32 = s.transition.shownMinorSideOutside(now_seconds);
    const star: StarLayout = starForChoice(window_layout, s, shown_turn, shown_minor_side_outside);
    // The chords' triangles first, under everything.
    for (s.scale.chords) |chord| {
        drawChordShapes(f, star, chord, isChordSounding(s, chord));
    }
    drawNotePath(f, star);
    // The chords' lines, under the notes and the chords, which are drawn over their ends.
    for (s.scale.chords) |chord| {
        const chord_degrees: [3]u8 = chord.degrees();
        const is_chord_lit: bool = isChordSounding(s, chord);
        drawChordLine(f, star, chord, chord_degrees[0], .root, is_chord_lit);
        drawChordLine(f, star, chord, chord_degrees[1], .third, is_chord_lit);
        drawChordLine(f, star, chord, chord_degrees[2], .fifth, is_chord_lit);
    }
    // The chosen chord's notes, outlined in color below (`drawChordOutlines`) - not while two or more of the left
    // diagrams' chords are held.
    const chosen_degrees: [3]u8 = s.scale.chords[s.chosen_chord_index].degrees();
    const is_chosen_outlined: bool = heldLeftChordCount(s) < 2;
    for (all_degrees) |degree| {
        const is_chosen: bool = is_chosen_outlined and indexOfScalar(u8, &chosen_degrees, degree) != null;
        drawNote(f, s, star, degree, isDegreeSounding(s, degree), is_chosen);
    }
    drawNoteProxies(f, s, star);
    for (s.scale.chords) |chord| {
        drawChord(f, s, star, chord, isChordSounding(s, chord));
    }
    drawChordOutlines(f, s, star);
    drawKeyboard(f, s, window_layout.parts.keyboard);
    drawProgressionEditor(f, s, window_layout.parts, window_layout.chooser.size_unit);
    drawCarriedChords(f, s, window_layout.parts);
}

// ---- The frame ----

/// The window's layout for its size now: worked out again only when the size changes, since `StarLayout.ofRoom` tries
/// dozens of layouts to find the star's.
fn windowLayoutOf(f: *z.Frame, s: *State) WindowLayout {
    const window_size: Vec2 = .{ f.window.widthf(), f.window.heightf() };
    const is_same_width: bool = window_size[0] == s.layout_window_size[0];
    const is_same_height: bool = window_size[1] == s.layout_window_size[1];
    const is_same_size: bool = is_same_width and is_same_height;
    // The header's width decides whether the star reaches the window's top (`WindowParts.ofWindow`).
    const is_same_header: bool = s.header_content_right == s.layout_header_content_right;
    if (s.window_layout) |kept_window_layout| {
        if (is_same_size and is_same_header) {
            return kept_window_layout;
        }
    }
    const parts: WindowParts = .ofWindow(f, s.header_content_right);
    // Laid out by the chosen scale: a borrowed chord held, which alters the scale sounding, moves nothing.
    const star: StarLayout = .ofRoom(parts.star, parts.button_corner, s.chosen_scale);
    // The left hand's two diagrams inside their boxes, each filling its own.
    const chooser_room: z.Rectangle = insetRectangle(parts.chooser, params.window.left_diagram_padding);
    const fifths_room: z.Rectangle = insetRectangle(parts.fifths, params.window.left_diagram_padding);
    const chooser: ChooserLayout = .ofRoom(chooser_room, star.rotation_turns, s.chosen_scale);
    const window_layout: WindowLayout = .{
        .parts = parts,
        .star = star,
        .chooser = chooser,
        .chromatic = .ofArea(parts.chromatic),
        .fifths = .ofArea(fifths_room, s.chosen_scale),
    };
    s.window_layout = window_layout;
    s.layout_window_size = window_size;
    s.layout_header_content_right = s.header_content_right;
    return window_layout;
}

/// A frame: the window cleared; the dropdowns built first, so that a pick changes the scale before anything reads it
/// and the fingers know whether a list is open; the layout for the window's size and the scale; the digit keys, the
/// pointers; the drawing; and the dropdowns rendered last, over it.
/// A press or release, the moment it arrives (`AppSpec.on_input`): the fingers and the digit keys read again then
/// (`readPointers`, `readDigitKeys`), and the strum's due notes started (`startDueHolds`), so that a note or a chord a
/// finger or a key came down on sounds now rather than at the next frame. Both readings follow what is held, not what
/// changed, so the frame's own reading after it finds nothing new. While the options panel or one of the header's lists
/// is open the pointer is the UI's - which only the frame's UI knows - and the frame reads it as before.
fn onInput(f: *z.Frame, s: *State, event: z.InputEvent) void {
    switch (event) {
        .key_down, .key_up => readDigitKeys(f, s),
        .mouse_button_down, .mouse_button_up, .touch_begin, .touch_end => {
            if (s.is_options_open or s.is_header_list_open) {
                return;
            }
            readPointers(f, s, windowLayoutOf(f, s), false);
        },
        else => {},
    }
    startDueHolds(f, s);
}

fn update(f: *z.Frame, s: *State) void {
    // A black screen with a start button, until it is pressed and the audio runs (`z.showAudioStartScreen`).
    if (z.showAudioStartScreen(f, &s.font)) {
        return;
    }
    z.clearViewport(f, params.colors.background);
    const ui: z.ui_real.Ui = s.ui_host.begin(f);
    const is_ui_capturing: bool = buildOptions(f, s, ui);
    advanceProgression(f, s);
    playProgressionChords(f, s);
    const window_layout: WindowLayout = windowLayoutOf(f, s);
    readDigitKeys(f, s);
    readPointers(f, s, window_layout, is_ui_capturing);
    startDueHolds(f, s);
    updatePedals(f, s);
    draw(f, s, window_layout);
    s.ui_host.render(f);
}

/// The app, as the engine runs it: its window, its state's start (`initState`), its frame (`update`), its presses and
/// releases as they arrive (`onInput`) and its end (`deinit`).
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - the scale star, two hands",
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
