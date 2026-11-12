# magic isomorphic keyboard - the computer keyboard as an instrument, laid out in thirds and fifths, playing the scale star's chords and progressions - the plan (v1 FINAL, Oct 31 2026)

STATUS: FINAL (Oct 31) - D1-D9 taken and agreed; D10, the layout played, Nov 1. IN PROGRESS (Simon's go, Nov 1): S0 and S1 written, S1 on the fifths layout, awaiting Simon's build. Written under
claude.md's "MAKE A PLAN" procedure. **Nothing is implemented, and nothing will be until Simon says go.** This file is
the one source of truth for the demo's decisions, status and journal (section 11).

Simon's ask (Oct 31), with a photo of a laptop keyboard whose keys carry note stickers: "Make a plan for making a new
audio demo, similar to the keyboard piano example, but which will enable playing with different layouts. For example
this layout. Which has keys organized so that fifths, major third, minor thirds, are at constant places around notes.
Look at the star demo with the circle of thirds, and all the things, like chords, and progressions. We want to include
that, to be able to play progressions. Make a detailed plan for making this demo."

What was read for this plan: `examples/audio_keyboard/audio_keyboard.zig` (whole), `examples/audio_scale_star/
audio_scale_star.zig` (whole), `examples/audio_scale_star_hands/audio_scale_star_hands.zig` (its header, the params,
the scale and modes, the pedals, the progressions and their table, the state, holding and strumming, the progression
track, the options, chord naming), `src/types.zig` (`KeyboardKey`), `src/dom_input.zig` and `src/native_input.zig`
(how keys are numbered), `src/bridge.zig` (the page's key listeners), `src/sound.zig` (instruments, notes, voices),
`tools/sound_capture_check.zig`, `examples/audio_scale_star/check.script` and `check.expect`, and build.zig's app list,
the `audio-scale-star-check` step and the `test-goban` step.


## 0. The goal, stated so it can fail

A new example, `examples/magic_isomorphic_keyboard/` (name: D1), where the computer keyboard's four rows of character
keys are an instrument whose layout can be chosen. The layout in the photo comes first, then others. The scale star's
ideas come with it: a scale (tonic and mode) colours every key by its degree, chords are named as they sound, a small
circle-of-thirds star lights up in step, and a progression track (I-V-vi-IV, the songs) waits for the player to play
each chord, wherever on the keyboard they play it.

THE GATES - each one a check that can come out red:

  G1 THE PHOTO, KEY FOR KEY. The layout reproduces the 41 stickers exactly. Checked against a table transcribed by
     hand from the photo (section 1), not against the formula that generates the layout.
  G2 ONE SHAPE PER INTERVAL. On every isomorphic layout, each of a key's six neighbours is the same interval away
     wherever the key is. On the photo's layout every three keys forming a downward triangle are a major triad and
     every upward triangle a minor triad. Tests walk every key and every triangle of the grid.
  G3 AS QUICK AS THE PIANO. A key's note starts through `on_input`, as in `audio_keyboard`. The latency readout of
     the two examples agrees within noise on the same machine.
  G4 IT SOUNDS RIGHT, CHECKED HEADLESS. `zig build magic-isomorphic-keyboard-check` plays a script of single keys and
     triangles and checks the pitch classes and loudness in the saved sound (`tools/sound_capture_check.zig`), against
     an expectations file computed by hand, as `audio-scale-star-check` does.
  G5 PROGRESSIONS ARE PLAYABLE. With "1-5-6-4" chosen, the track waits at each chord until its three pitch classes
     sound, in any voicing, anywhere on the grid. It then moves on, and the coming chord is shown where the hand can
     reach it. Tests cover the matching; a headless screenshot shows the outlines.
  G6 ONE THEORY. The scale, the modes, the chords, the progressions' table and chord naming exist once (D2), and
     `audio_scale_star_hands` still builds and behaves as before.
  G7 TOUCH. On a phone held sideways the drawn grid plays under several fingers at once, sliding from key to key as
     the scale star's targets do.


## 1. The photo, decoded

The stickers, row by row. A key in brackets has no sticker in the photo; its note follows from the same rule.

    number row   (`)  1    2    3    4    5    6    7    8    9    0    -   (=)
                 D#   C    A    F#   D#   C    A    F#   D#   C    A    F#   D#
    Q row             Q    W    E    R    T    Y    U    I    O    P    [   (])  (\)
                      F    D    B    G#   F    D    B    G#   F    D    B    G#   F
    A row               A    S    D    F    G    H    J    K    L    ;   (')
                        A#   G    E    C#   A#   G    E    C#   A#   G    E
    Z row                  Z    X    C    V    B    N    M    ,    .   (/)
                           D#   C    A    F#   D#   C    A    F#   D#   C

Number each row's keys from 0 at `1`, `Q`, `A` and `Z`, and each row from 0 at the top. A computer keyboard's rows are
staggered, so the key at index i of a row sits under the gap between keys i and i+1 of the row above. The offsets are
0.5, 0.25 and 0.5 of a key on an ANSI keyboard, but each is between 0 and 1. So whatever the offsets, a key's two upper
neighbours are the keys at the same index (up-left) and at the next index (up-right) of the row above. Every one of the
41 stickers then fits a single rule:

    pitch(row, index) = pitch of `1` - 3 x index - 7 x row

    one key right          -3   a minor third down        one key left          +3   a minor third up
    up-right               +4   a major third up          down-left             -4   a major third down
    up-left                +7   a fifth up                down-right            -7   a fifth down

That is the Tonnetz - the lattice of minor thirds, major thirds and fifths that music theory draws as triangles - laid
on the keyboard with minor thirds along the rows. ("fifths, major third, minor thirds, are at constant places around
notes".) What follows from it is what the demo is for:

  * EVERY TRIAD IS A TRIANGLE OF NEIGHBOURS. A major triad is a key with its two upper neighbours: root at the bottom
    point, its third up-right, its fifth up-left - a downward triangle. C major is X, D, S (C, E, G). A minor triad is a
    key, its left neighbour and its up-left neighbour - an upward triangle. A minor is C, X, D (A, C, E). One hand
    shape plays every major chord and another every minor chord, in every key.
  * NEIGHBOURING CHORDS SHARE AN EDGE. The three triangles that share an edge with C major's are the three chords
    that keep two of its notes: C minor across the fifth C-G (Z, X, S - its parallel), A minor across the major third
    C-E (its relative) and E minor across the minor third E-G. The smooth moves of real progressions are one-key
    moves here.
  * THE STAR IS A STRIP OF THIS KEYBOARD. The scale star's circle of thirds, 1 3 5 7 2 4 6, alternates major and minor
    thirds. On this grid that is a staircase: C (X), up-right to E (D), left to G (S), up-right to B (E), left to D (W),
    left to F (Q), up-right to A (2), left to C (1). Any three notes in a row on the staircase are one of the scale's
    seven chords: X D S is I, D S E is iii, S E W is V, W Q 2 is ii, Q 2 1 is IV - majors pointing down, minors up.
    The one exception is the step where two minor thirds follow each other, B-D-F (E W Q): three keys in a straight
    line, not a triangle - vii°, the diminished chord, the odd one out on the star too. Rolled into a ring, the
    staircase is the star. Drawing that staircase on the grid (5.7) is the bridge between the two demos.
  * THE PATTERN REPEATS. Four keys along a row return to the same pitch class (four minor thirds are an octave), so
    each row holds one diminished seventh chord over and over, and the rows cycle through the three such chords. Every
    pitch class appears three or four times on the grid, so every chord can be played in several places, and the
    demo can point at the nearest one (5.8).

The octaves are not in the photo: stickers name pitch classes. With pitches taken literally from the rule, pitch falls
to the right and rises upward. With `1` at C6, the grid runs from C2 at `/` to D#6 at the backquote, and middle C is at
both X and 9. Keys whose pitches agree to the octave come in pairs: 8 and Z, 9 and X, 0 and C, - and V, = and B. On a
Shepard instrument, which plays pitch classes, the octave question disappears (D3, D9).

### 1.1 Simon's second picture: the tonic under the left index finger

Simon's second message (Oct 31) adds two pictures. The first is the same lattice drawn as hexagons, centred on C. Each
hexagon round C is named by its interval from C: fifth (G, up-left), third (E, up-right), sixth (A, right), minor
third (D#, left), tone (D), "semitone down (maj7)" (B), "tone down (7)" (A#), tritone, semitone (C#). The scale's
degrees are written beside them, 1 to 7. Naturals are white, sharps lilac, as on the stickers. The second picture
is the laptop keyboard with C major written on it - and the tonic is on the F KEY, the home row's index-finger key
with the bump, not where the stickers put C:

    degree  note  keys                    from the tonic's key
      1      C    F                       -
      2      D    4 and B                 up-left twice; down-right then right
      3      E    T                       up-right
      4      F    V                       down-right
      5      G    R                       up-left
      6      A    G                       right
      7      B    5 and X                 up-left then up-right; down-left then left

Every one of those fits the photo's rule (right -3, up-right +4, up-left +7) anchored at the F key. Against the
stickers, where the F key is C#, the whole grid is a semitone lower. So the layout is the photo's, and the ANCHOR is
the tonic, on the key the left hand finds without looking. The major scale is then one compact shape round the home
key (rows: 4 5 / R T / F G / V B, and X), the same shape in every key - what the stars teach with colours ("what a
note does in the key, not which note it is"), made into a hand position.

What the plan takes from it:
  * THE TONIC SITS ON F BY DEFAULT, and the grid moves with the scale chosen: in G major the F key plays G. One shape
    per degree, in every key - "movable do" on the keyboard. The photo's fixed anchoring (C on X, `1` on C) stays as an
    option, for playing along with the stickers (5.3, D9).
  * LABELS BY INTERVAL FROM THE TONIC, as the hexagon picture writes them: degree numbers with accidentals (1, b2, 2,
    b3, 3, 4, #4, 5, b6, 6, b7, 7), or the interval's name (tone, minor third, fifth, tritone...), beside the note's
    letter (5.7, 5.11).
  * THE STICKERS' COLOURS as an option beside the degree colours: white naturals, lilac sharps (5.7).
  * A HEXAGON VIEW of the same grid, as the first picture draws it, as an option beside the keyboard view (3.9).

### 1.2 Simon's drawing (Nov 1): fifths along the rows - THE LAYOUT PLAYED (D10)

Simon, Nov 1: "I want the layout to be such that we go to the fifth when going to the right, to the major third when
going downright, and to the minor third when going top right" - with a drawing of the laptop's keys, the naturals
written in: 1 to 7 F C G D A E B; Q W E A E B and O P [ ] \ F C G D A; G to ' F C G D A E B; Z to M F C G D A E B.
Every one of them fits

    one key right          +7   a fifth up                one key left          -7
    up-right               +3   a minor third up          down-left             -3
    down-right             +4   a major third up          up-left               -4

anchored at F on 1 - in the plan's terms `step_right` 7, `step_up_right` 3. The same Tonnetz as the photo's, turned:
the circle of fifths runs along each row, and what follows from it changes shape:

  * A MAJOR SCALE IS SEVEN KEYS IN A ROW (F C G D A E B for C major), its sharps continuing to the right. With the
    tonic on F, C major is the home row from D to L - the tonic under the left index finger, its fifth under the next.
  * A MAJOR TRIAD is a downward triangle: its root, the key to its right (the fifth) and the key below between them
    (the third) - C major is F G V. A MINOR TRIAD is an upward one: its root, the key above on its right (the minor
    third) and the key to its right (the fifth) - A minor is J I K.
  * The circle of thirds, the star's path, is still a zigzag: C (F) down-right to E (V), up-right to G (G), down-right
    to B (B), up-right to D (H), up-right again to F (U) - two minor thirds in a straight line, vii's flat step - then
    down-right to A (J) and up-right to C (I).
  * In pitch, a row of fifths spans far: with the tonic C4 on F the grid runs from C1 at the backquote to B8 at the
    backslash, seven octaves. The Shepard default hears only pitch classes; the real-octave mode (S7, D9) must choose
    its octaves another way - D9 is to be asked again when S7 comes.

The photo's layout stays in the code as `thirds_layout` (with its tests), one of the layouts S2 offers; the tonic on F
(1.1) stays the anchor.


## 2. What zimr already has

### 2.1 The three audio demos

`examples/audio_keyboard/audio_keyboard.zig` - the piano on the A and Q rows. What carries over:
  * `onInput` (:209) starts a note the moment its key event arrives, carrying the press's time (`pressed_at_ms`), and
    ignores key repeats. `readComputerKeyboard` (:168) is the per-frame fallback for a launcher that never calls it.
  * `readPointer` (:182) slides a finger from key to key; `drawLatencyReadout` (:245) prints the mixer's measured
    starts.
  * `z.showAudioStartScreen` - the start button, without which a page plays nothing.

`examples/audio_scale_star/audio_scale_star.zig` - the circle of thirds, plain. What carries over:
  * `circlePlaceOfDegree` (:173) and its comptime proof that every chord is three neighbours on the circle.
  * Several pointers each holding a target (`readPointers` :746), hold counts so a note held two ways sounds once.
  * The look: degree colours (red to violet, tonic red), squares on the major side and circles on the minor, the
    roles' line styles (arrow to the root, zigzag to the third, dashes to the fifth).
  * The Shepard instrument, so that notes differ in pitch class and not in height.

`examples/audio_scale_star_hands/audio_scale_star_hands.zig` - 7385 lines, the full star. What carries over:
  * `params` (:152) - every colour, size and default in one struct.
  * The scale (:555-960): `Mode` (11 scales: the 7 church modes, harmonic and melodic minor, harmonic major, Phrygian
    dominant), `Scale` with spelling (each letter once, F# Ionian's E#, G# Ionian's F##), solfege, `ScaleChord`,
    quality from semitones, numerals, `alterationsForChord` for borrowed chords.
  * The progressions (:1119-1282): `Progression`, `ProgressionBorrowing`, `SongKey` (Hotel California in D Ionian),
    the 33-entry `progressions` table, `progressionChord`, `chordLetterName`.
  * Holding (:3111-3590): two strengths (`DegreeHolds`: the thumb's soft chord, everything else full), the strum
    (`holdChordDegrees`, `PendingHold`, 0.1 s between root, third and fifth).
  * The track (:4072-4404, :4575-4700): boxes, the beat, `advanceProgression`, waiting for the player
    (`takeProgressionChord`), "play the chords" (`playProgressionChords`), the waiting pulse.
  * The options panel (:4420) and header, built with `z.ui_real.Ui`.
  * Chord naming (:5268-5714): `PitchClassSet` (u12), `chord_patterns` (:5315, triads, sixths, sevenths, sus,
    add9...), `matchedChord`, `numeralNameOf`, `nameOfChord`; and `functionNameOfDegree` (:6357) - Tonic, Dominant.
  * The pedals (:961-1080): a low Shepard voice under everything, an example-defined generator.

★ What star_hands does NOT have and this demo needs: notes outside the scale. On the star every note is a degree, so
`nameFromPattern` falls back to degree 1 for a root the scale lacks (`degreeOfPitchClass(root) orelse 1`), and
`numeralNameOf` does the same. On a chromatic grid Bb major is playable in C and must be named Bb and bVII, not C and
I. This needs a chromatic spelling and chromatic numerals (5.10).

### 2.2 The engine

  * KEYS ARE PHYSICAL. `KeyboardKey` (`src/types.zig:704`) comes from `KeyboardEvent.code` on the web
    (`src/dom_input.zig:12`: ".w names the key above .s on AZERTY as on QWERTY") and from scancodes natively
    (`src/native_input.zig`, whose tests pin the two to agree). A layout defined on key positions is the same on
    QWERTY, AZERTY and Dvorak - exactly what a sticker layout needs. Every key in the four rows has a name: grave,
    digits, minus, equal, brackets, backslash, semicolon, apostrophe, comma, period, slash.
  * NO ISO KEY. The key between left Shift and Z on ISO keyboards (`IntlBackslash`, scancode 0x56) has no engine name
    (`dom_input.zig:440`, `native_input.zig:914`). The photo's keyboard is ANSI, so v1 does not need it (D8).
  * THE BROWSER SEES EVERY KEY TOO. The page's keydown listener (`src/bridge.zig:4422`, `onKeyDown`) forwards the key
    and does not call `preventDefault`. On Firefox, ' and / open Quick Find; Space can scroll a scrollable page. To be
    verified on a device in S1, before deciding anything (D8).
  * THE MIXER (`src/sound.zig`): `sendNote` (:2917) queues a key's event for the instrument (256 deep);
    `setInstrument` (:2911); two instruments, `sine_instrument` (:312) and `shepard_instrument` (:427); **16 voices
    for notes** (`instrument_voice_count`, :121) - a grid invites more held notes than a star does (risk R3); an
    example can define its own generator - star_hands' pedals - in at most 64 bytes of state
    (`generator_state_capacity`, :299), and so its own instrument.
  * THE SOUND CHECK (`tools/sound_capture_check.zig`) measures pitch classes as a SHEPARD instrument plays them, at
    their partials in middle C's octave. A check run must use the Shepard instrument.
  * TESTS FROM AN EXAMPLE'S OWN FILE: `test-goban` (build.zig:8029) compiles `examples/goban/goban.zig`'s tests with
    only `zm`; Zig analyses only what the tests reach, so nothing of the engine is compiled. The same works here.
  * A SHARED MODULE FOR EXAMPLES: `example_common` is given to every example as a named import (build.zig:2867).


## 3. Brainstorm - every option, including the ones I expect to reject

### 3.1 Where the demo lives

  a. A new example, `magic_isomorphic_keyboard`. Clean; the star demos stay as they are.
  b. Layouts inside `audio_keyboard`. It is 317 lines and is the latency reference; growing it hides that.
  c. A view inside `audio_scale_star_hands`. Its window is already full (seven parts), and it is 7385 lines.
  d. A new example plus a shared theory module (3.2) - (a) without the duplication.

### 3.2 The theory the two demos share

  a. Copy the scale, chords, progressions and naming into the new file (~1300 lines, then two copies drift).
  b. Extract them into a shared example module, `examples/music_theory/music_theory.zig`, imported by name like
     `example_common`, importing only `std` and `zm`; star_hands switches to it in the same step.
  c. The same in the engine, `src/music.zig`. Music theory is not engine material; an example module is the right
     home.
  d. Import star_hands' file from the new example. Impossible: a module cannot reach outside its root's directory.

### 3.3 How a layout is described

  a. ISOMORPHIC: two numbers say everything - the semitones to the key on the right, and to the key up-right (up-left
     is their difference) - plus an anchor key and the note it plays. Any isomorphic layout, one line each, including
     ones invented with two sliders.
  b. TABLE: a list of (key, semitones). For layouts that are not isomorphic: the piano layouts.
  c. CHORD KEYS: a key plays a chord, not a note. The accordion's Stradella bass; the scale's seven chords on a row.
  d. A function per layout (`fn (key) -> action`). Flexible, but the catalogue stops being data.

### 3.4 The layouts worth having

    name                         right  up-right  up-left   what it is
    thirds (the photo)            -3      +4        +7      the Tonnetz, minor thirds along the rows, falling right
    thirds, mirrored              +3      +7        +4      the same, rising to the right
    fifths along the rows         +7      +4        -3      the Tonnetz turned: fifths along, thirds across
    major thirds along the rows   +4      +7        +3      the third turn
    Wicki-Hayden                  +2      +7        +5      concertinas: whole tones along, fifths and fourths across
    Janko                         +2      +1        -1      whole tones along, rows a semitone apart
    guitar fourths                +1      +6        +5      semitones along, up-left a fourth: guitar strings
    accordion C-system            +3      +1        -2      chromatic button accordion: minor thirds along
    custom                     slider  slider              any two numbers
    piano, two octaves (table)                              trackers' layout: Z-row and Q-row white keys, S-row and
                                                            number-row black keys, two octaves and a third
    piano, one row (table)                                  `audio_keyboard`'s: A-row white, Q-row black
    scale chords (chord keys)                               the scale's seven chords on one row, its degrees on the
                                                            others, following the chosen scale
    Stradella (chord keys)                                  columns a fifth apart: bass, major, minor, seventh rows

### 3.5 What sounds

  a. Shepard tones, as the stars play: pitch class only, every layout's octave question gone, the headless check
     works as it is. But a melody cannot rise.
  b. Real octaves through `sine_instrument`: honest pitch, but a bare sine is dull.
  c. Real octaves through a new example instrument (a few harmonics, a soft attack - an "organ"), in 64 bytes of
     state as the pedals are.
  d. A choice in the options, with one of these as the default (D3).

### 3.6 Playing a chord with one key

  a. Never: chords are triangles of keys, which is the point of the photo's layout.
  b. Shift held: every note key plays the scale's own triad on its note (I, ii, iii... on degrees; a major triad on a
     note outside the scale). Shift is the one modifier the browser leaves alone - Ctrl+W closes the tab, Alt opens
     menus.
  c. Tapping the middle of a triangle on the drawn grid plays its triad - the touch version, as the star's chord
     targets play three notes.
  d. Space plays the chord the track waits for, softly, as star_hands' thumb does.
  e. Chord-key layouts (3.4) - a whole layout of one-key chords.

### 3.7 Progressions

  a. Reuse the track as star_hands has it: boxes, a tempo, waiting for the player, "play the chords".
  b. Match the awaited chord by the PITCH CLASSES sounding (all three of its pitch classes sound, more allowed), not
     by which button was pressed - a grid has no chord buttons, and a borrowed chord (E major in C) is then just keys.
  c. Show the coming chord on the grid: every place it can be played outlined faintly, by role (root red, third
     yellow, fifth cyan, star_hands' colours), the one nearest the last chord played outlined strongly.
  d. Editing: star_hands' drag-and-drop into boxes, or RECORDING - tap a box, play a chord, the chord heard goes in.
     Recording suits a keyboard demo and costs little.
  e. Accompaniment: the track plays each chord itself, softly, while the player plays a melody; or a pedal on the
     root.

### 3.8 What else is drawn

  a. The grid alone.
  b. The grid, plus a small circle-of-thirds star lit in step, plus a line naming the chord: `Am7  vi7  Tonic`.
  c. Also the circle of twelve notes, the guitar charts, the Lissajous figure - star_hands' other views.
  d. The Tonnetz continued past the keyboard's edges, faintly - the plane the keys are a window on.

On the grid itself, each one an option:
  * a compass on a held key: its six neighbours labelled with their intervals (m3 up, M3 up, 5th up...);
  * the triangle of each triad sounding, filled in its root's colour;
  * the staircase of the scale's thirds (1.), the star's path on the grid;
  * labels: note names spelled in the key, solfege, degree numbers, or the key caps' own letters.

### 3.9 Drawing the keys

  a. As on an ANSI keyboard: rows offset 0.5, 0.25 and 0.5 of a key; Tab, Caps Lock, Shift, Enter and Backspace drawn
     as dim outlines so the shape reads as a keyboard, as in the photo.
  b. As an ideal lattice: every row offset half a key, triangles equilateral. Prettier triangles, but the keys stop
     being where the fingers are.
  c. As hexagons, the way Simon's second picture draws the lattice (1.1): each key a hexagon touching its six
     neighbours, so the intervals read as directions and the triangles are where three hexagons meet. A second view
     of the same grid, switched in the options; the keyboard view stays the default.

### 3.10 Rejected outright

  * MIDI input or output: the engine has neither, and the demo is about the computer keyboard.
  * Layouts depending on the typed character (AZERTY's A where QWERTY's Q is): positions are the point.
  * Saving custom layouts between sessions: not needed for v1.


## 4. Preferred choices, and why

  * 3.1 (d), 3.2 (b): A NEW EXAMPLE AND A SHARED THEORY MODULE. The new demo needs almost all of star_hands' theory,
    and claude.md's rule for numerically or musically delicate code is one home ("a formula written twice will be
    improved in only one place"). The extraction is mechanical (moves and renames), star_hands is the second caller
    that justifies a module, and the module's tests then cover both demos. A module of `std` + `zm` only can be
    tested like goban, without the engine.
  * 3.3 (a) + (b) + (c): THREE KINDS OF LAYOUT in one union. Isomorphic layouts are two numbers, so the catalogue is
    cheap and a custom layout is two sliders. Tables and chord keys cover the piano and the accordion.
  * 3.4: v1 SHIPS the photo's layout, its mirror, the two other Tonnetz turns, Wicki-Hayden, Janko, guitar fourths,
    custom, the two pianos - all data. The chord-key layouts come in a later stage (S6) (D4).
  * 3.5 (d) with SHEPARD AS THE DEFAULT: the photo's stickers are pitch classes, the stars sound Shepard, and the
    headless check measures Shepard. Real octaves as an option, through a new soft "organ" instrument (D3).
  * 3.6 (b) + (c): Shift for the scale's chord on a key, a tap inside a triangle on the drawn grid. The triangles stay
    the main way. No Space chord (D5, decided).
  * 3.7 (a) + (b) + (c), recording (d) in a later stage, track accompaniment through star_hands' "play the chords" and
    thumb strength (D7).
  * 3.8 (b) with every on-grid overlay, each switchable; the plane past the edges later (D6).
  * 3.9 (a): the real keyboard's offsets. The demo's claim is about the keys under the fingers. The hexagon view (c)
    in a later stage, as an option.
  * 1.1: THE TONIC ON THE F KEY, following the scale chosen; the photo's fixed anchoring as an option.


## 5. The design

### 5.1 Files

    examples/music_theory/music_theory.zig       NEW (S0) - the theory, from star_hands: Mode, Scale, spelling,
                                                 ScaleChord, numerals, Progression and its table, PitchClassSet,
                                                 chord_patterns, matchedChord, chord and numeral names, function
                                                 names; plus chromatic spelling and numerals (5.10). std + zm only.
                                                 Its tests at the end.
    examples/audio_scale_star_hands/...          imports `music_theory` instead of its own copies (S0)
    examples/magic_isomorphic_keyboard/
        magic_isomorphic_keyboard.zig            NEW - the demo, one file, star_hands' order: params, the keys,
                                                 the layouts, holding, the track, input, drawing, the frame; tests
                                                 at the end
        check.script, check.expect               NEW - the headless sound check (5.12)
    build.zig                                    the app's entry; `music_theory` wired as `example_common` is;
                                                 `test-music-theory`, `test-magic-isomorphic-keyboard`,
                                                 `magic-isomorphic-keyboard-check`
    src/notes/examples_catalog.md                one row

### 5.2 The keys

```zig
/// A key of the computer keyboard that can play: the engine's name for it, the label a US keyboard prints on it, its
/// row - 0 the digits, 3 the bottom letters - and its index along the row, 0 at 1, Q, A and Z (-1 for the backquote).
/// The index is what makes the layouts work: a key's upper neighbours are the keys of the row above at its own index
/// (up-left) and the next (up-right), whatever the row's offset.
const PlayingKey = struct {
    key: z.KeyboardKey,
    us_label: []const u8,
    row: u2,
    index_in_row: i8,
};

/// Where index 0 of each row starts, in key widths from the keyboard's left edge, on an ANSI keyboard: 1 after the
/// backquote, Q after Tab's 1.5, A after Caps Lock's 1.75, Z after left Shift's 2.25.
const row_start_in_keys = [4]f32{ 1.0, 1.5, 1.75, 2.25 };

/// The 47 keys of the four rows: 13 + 13 + 11 + 10.
const playing_keys = [_]PlayingKey{
    .{ .key = .grave, .us_label = "`", .row = 0, .index_in_row = -1 },
    .{ .key = .one, .us_label = "1", .row = 0, .index_in_row = 0 },
    // ... to .{ .key = .slash, .us_label = "/", .row = 3, .index_in_row = 9 }
};
```

A comptime block checks the table: 47 keys, no key twice, each row's indices contiguous.

### 5.3 The layouts

```zig
/// What a key does in a layout: plays a note, plays a chord, or nothing.
const KeyAction = union(enum) {
    /// A MIDI key.
    note: u8,
    /// A chord: its root's MIDI key and its kind (`ChordKind`: major, minor, dominant seventh, diminished seventh...).
    chord: KeyChord,
    none,
};

/// A layout where every interval has one shape: the semitones from a key to its right neighbour and to its up-right
/// neighbour. The up-left neighbour is `step_up_right - step_right` away. A key `index` keys right of the anchor key
/// and `rows_down` rows below it plays
///
///     anchor's note + index x step_right + rows_down x (step_right - step_up_right)
///
/// The photo: step_right -3, step_up_right +4 - each row down is a fifth lower.
const Isomorphic = struct {
    step_right: i8,
    step_up_right: i8,
};

/// Which note the anchor key plays (`Anchoring`): the scale's tonic, on the F key by default - the grid moves with the
/// scale, so each degree keeps its key in every key (Simon's second picture, 1.1) - or a fixed MIDI key, as the
/// stickers fix C on X whatever the scale.
const Anchoring = union(enum) {
    tonic_on: z.KeyboardKey,
    fixed: struct { key: z.KeyboardKey, midi: u8 },
};

const LayoutKind = union(enum) {
    isomorphic: Isomorphic,
    /// Each key's semitones above `base_midi`; keys not listed play nothing.
    piano: struct { base_midi: u8, keys: []const KeySemitones },
    /// Chord keys, following the scale chosen (S6).
    scale_chords,
    stradella: struct { first_root_pitch_class: u4 },
};

const Layout = struct {
    name: []const u8,
    /// A line for the legend: "minor thirds along the rows, major thirds up-right, fifths up-left".
    description: []const u8,
    kind: LayoutKind,
};
```

`actionOfKey(layout, anchoring, scale, octave_shift, key) KeyAction` is the one function from a key to what it plays.
Every other part asks it - input, drawing, the occurrences of a chord.

With the tonic on the F key, an isomorphic layout plays the same DEGREE on each key in every key: the major scale is
always 4 5 / R T / F G / V B / X. Changing the tonic in the header transposes the whole grid; the colours do not move,
because the colours are degrees. The piano layouts do not move with the tonic - a piano's keys are its pitches - and
are coloured by degree all the same, as star_hands' keyboard is.

★ A KEY REMEMBERS WHAT IT STARTED. Each held key stores its `KeyAction` (`key_holds: [47]?KeyAction`), and its release
lets go of that, not of what the key plays NOW. Changing the layout, the scale or the octave while keys are held must
not leave a note hanging. (The same reasoning as star_hands' pointer holds.)

### 5.4 Holding and sounding

What the instrument receives is a SOUND KEY: the MIDI key itself with real octaves, or `60 + pitch class` with the
Shepard instrument - which ignores octaves, so that 9 and X, both C, sound once. Holds are counted per sound key, at two
strengths (star_hands' `DegreeHolds`, keyed by sound key instead of degree):

```zig
/// How many things hold a sound key down: computer keys, fingers on drawn keys or triangles, Shift-chords - at full
/// strength - and the track's own chord, at the accompaniment's.
const SoundHolds = struct { full: u8 = 0, accompaniment: u8 = 0 };
holds: [128]SoundHolds,
```

A chord - from Shift, a triangle tap, the track, or a chord key - strums as star_hands' do (root, third, fifth, 0.1 s
apart, `PendingHold`), over its MIDI keys.

★ LOUDNESS. A star holds three notes at most; a grid invites six or eight. Each Shepard note at velocity 0.5 is 0.13
RMS, so eight are 0.38 RMS, and their peaks can pass full scale. S1 measures the peak with ten keys held, and the
velocity is set from the measurement (risk R4).

### 5.5 Input

  * `onInput` (`AppSpec.on_input`): a playing key's press starts its action with the press's time, its release lets go;
    repeats ignored. The per-frame fallback as `audio_keyboard` has it.
  * Shift held at a key's press: the key plays its note's chord (3.6 b). Releasing Shift does not change held keys.
  * Arrow keys: left and right step through the layouts, up and down shift the octave (real octaves only). Escape
    lets go of everything - the panic button.
  * Pointers: every finger, and the mouse, holds the key or triangle under it, sliding on as on the star - the
    6-pixel switch distance (`params.playing.target_switch_distance`) included, against crackle at a boundary.
  * The UI's options panel takes the pointer while open, as in star_hands.

### 5.6 The window

    +----------------------------------------------------------------------------------+
    | [=] C Ionian   thirds (the photo)              Am7   vi7   Tonic                 |
    +----------------------------------------------------------------------------------+
    | [ I ]  [ V ]  ( vi )  [ IV ]           the track: the box playing outlined white  |
    +-------------------------------------------------------------+--------------------+
    |  [`][1][2][3][4][5][6][7][8][9][0][-][=][ bksp ]            |                    |
    |  [tab][Q][W][E][R][T][Y][U][I][O][P][[][]][ \ ]             |    the star        |
    |  [caps][A][S][D][F][G][H][J][K][L][;]['][ enter ]           |   (circle of       |
    |  [shift ][Z][X][C][V][B][N][M][,][.][/][ shift  ]           |    thirds)         |
    |                                                             |                    |
    +-------------------------------------------------------------+--------------------+
    | <- m3 up   up-right: M3 up   up-left: 5th up   major: down-triangle   minor: up    |
    +----------------------------------------------------------------------------------+

The grid is 15 keys wide and 4 tall, so its size comes from the width. On a window held upright (a phone) the star
moves under the grid and the legend shortens. The bottom right corner stays clear for the page's fullscreen button, as
star_hands' does. The parts are worked out once per window size (`WindowParts`, as star_hands).

### 5.7 Drawing the grid

  * EACH KEY: a rounded key cap at its real place. It is filled with its note's DEGREE COLOUR in the chosen scale
    (`params.colors.degrees`, the tonic red), dimmed while silent and whole while it sounds. A note outside the scale
    is grey and lit white. Or, in the stickers' colours: naturals white, sharps lilac (1.1). The shape follows the
    stars: a square for a degree on the major side, a circle for the minor side. Drawn as a mark inside the cap, so
    the cap still reads as a key.
  * EACH KEY'S LABELS, as the star writes a note - its degree large, its letter beneath. The degree is counted from the
    tonic with accidentals for the notes outside the scale (b3, #4, b7: Simon's hexagon picture). Or the interval's
    name (tone, minor third, fifth, tritone), the note's letter spelled in the key (5.10), its solfege. The key's own
    US letter small in a corner, when asked.
  * The non-playing keys (Tab, Caps Lock, Shift, Enter, Backspace) as dim outlines.
  * THE COMPASS (isomorphic layouts): around each held key, its six neighbours carry their intervals, small - "m3",
    "M3", "5" with an arrow up or down. Names are read from the steps, so the compass is right on any layout.
  * TRIANGLES: each triad sounding (from `matchedChord` on the pitch classes sounding) is filled between the centres
    of the keys sounding it. The fill is its root's colour, the two halves weighted as the star's fans are (root to
    third stronger).
  * THE STAIRCASE: the scale's thirds, 1 3 5 7 2 4 6 1, as a thin white path through the occurrences nearest the
    grid's middle - on the photo's layout the staircase of section 1, on others a zigzag. Its triples are the seven
    chords, as on the star.
  * THE COMING CHORD (5.8): outlines by role, pulsing while the track waits.

### 5.8 Progressions on the grid

The track is star_hands' (`progressions`, `progressionChord`, the beat, waiting, "play the chords"), with three
changes:

  1. MATCHING BY SOUND. The awaited chord is played when all three of its pitch classes sound together - the stars'
     rule for lighting a chord ("a chord while all three of its notes do"). Any voicing, any octave, any place on the
     grid, extra notes allowed. A borrowed chord (Hotel California's F# major in D) needs no special button: it is
     its keys.

```zig
/// Whether `chord`'s three pitch classes all sound: the track's test for a chord played, and the star's for a chord lit.
fn isChordSounding(sounding: PitchClassSet, chord_pitch_classes: PitchClassSet) bool {
    return sounding & chord_pitch_classes == chord_pitch_classes;
}
```

  2. WHERE TO PLAY IT. A chord's OCCURRENCES are found by search over the keys. Each of its pitch classes is played by
     three or four keys, so there are at most ~64 triples. A triple counts if its keys are within a small spread (on
     the Tonnetz layouts, exactly the triangles). Each occurrence is outlined faintly. The one whose centre is nearest
     the centre of the keys last played as a chord is outlined strongly: "move your hand here". On the photo's layout
     I-V-vi-IV becomes a short walk of triangles across one hand's span.
  3. RECORDING (S5b, D7): tap a box, play a chord; the chord heard - root and quality from `matchedChord` - goes in.

"Play the chords" keeps star_hands' meaning - the track plays each chord as it falls due - but here it SOUNDS, at the
accompaniment's strength, so the player can play a melody over it.

### 5.9 The star

A small circle of thirds beside the grid, drawn as `audio_scale_star` draws it: seven notes, seven chords, a fixed
circle rather than its fitted ellipse. A note is lit while its pitch class sounds, a chord while all three of its pitch
classes do - the same lights as the grid's. A press on a star note or chord plays it, as on the star. About 300 lines,
in the demo's file. Its link to the grid is the staircase (5.7): the same path, rolled up.

### 5.10 What the shared module gains

  * CHROMATIC SPELLING: a pitch class outside the scale is named by the scale's degree it alters. In C: Db, Eb, F#, Ab,
    Bb - lowered 2, 3, 6 and 7, raised 4, the usual chromatic spelling of a major key. In a minor mode, the raised 6
    and 7 as sharps. A table per mode of which way each of the five missing pitch classes leans, with tests against
    hand-written spellings in several keys.
  * CHROMATIC NUMERALS: bVII, bIII, bVI, #iv°, II (the major chord on 2). `numeralNameOf` takes a root that may not be
    a degree.
  * `matchedChord` is unchanged; it already works on any set of pitch classes.

### 5.11 Options

Header: the options button, the scale (tonic and mode, as star_hands' header has them), the layout.

Panel:

    Layout       layout (list) | custom: step right, step up-right (integer sliders, -11 to 11) | octave (-2..+2) |
                 anchoring: the tonic on F / the stickers (C fixed, as in the photo)
    Sound        instrument: Shepard / organ | note volume | accompaniment volume | strum
    Labels       degree from the tonic (1, b3, #4...) / interval name (tone, minor third...) / note name / solfege |
                 key letters on or off
    Look         colours: degrees / stickers (white naturals, lilac sharps) | view: keyboard / hexagons
    On the grid  compass | triangles | staircase | where the coming chord can be played
    Progression  track (the list, with songs' keys as in star_hands) | boxes | bpm | wait for the player |
                 play the chords
    Diagnostics  audio stats (the latency readout) | debug handles

### 5.12 Tests and checks

`test-music-theory` (S0) - the module's tests, std + zm:
  * spelling: every scale of `Mode` on every tonic offered names each letter once (moved from what star_hands relies
    on); chromatic spellings against a hand-written table (C: Db Eb F# Ab Bb; F: Gb Ab B Db Eb; A minor ...);
  * numerals: Bb major in C is bVII, Ab major bVI, D major II, F# diminished #iv°;
  * naming: C E G is C; E G C is C; C E G Bb is C7; A C E G is Am7 - hand-written expectations.

`test-magic-isomorphic-keyboard` - the demo's own tests, std + zm (as `test-goban`):
  * G1: the 41 stickers, transcribed from the photo into a table in the test, against `actionOfKey` for the photo's
    layout with the stickers' anchoring. The table is a value the code did not produce.
  * Simon's second picture (1.1): with the tonic on F in C major, F is C, 4 and B are D, T is E, V is F, R is G, G is
    A, 5 and X are B - and in G major the same keys play G A B C D E F#.
  * G2: for every isomorphic layout and every key, each existing neighbour is the stated step away; on the photo's
    layout, every downward triangle of keys is a major triad, every upward one minor, and all 24 triads occur.
  * The two pianos against the published tracker layout: Z is C, S C#, Q C an octave up, I C two octaves up.
  * The staircase: on the photo's layout, from X, the path's keys are X D S E W Q 2 1.
  * Occurrences: C major on the photo's layout is found at X-D-S, and at every other place the hand-made list has.
  * Matching: {C, E, G} and {C, E, G, A} play I in C; {C, E} does not; {C, Eb, G} does not.
  * The release rule: a key pressed under one layout and released under another lets go of the first's note.

`magic-isomorphic-keyboard-check` (S1) - headless, as `audio-scale-star-check`, in C major with the tonic on F: the
start button, then single keys (F is C, T is E, R is G, G is A, V is F), then triangles - F T R (C E G, I), D F R
(C Eb G, its parallel minor), G F T (A C E, vi) - each held 0.4 s, the sound saved and checked against
`check.expect`. Its RMS values are worked out by hand, as `audio_scale_star`'s are (0.1328 a note,
0.2300 three).

A headless screenshot (`.capture_to`) of the grid with C major held and the track on, for Simon to look at.


## 6. Stages

Each stage ends with something Simon can run, and its tests green.

  S0  THE SHARED MODULE (D2). Move star_hands' theory into `examples/music_theory/music_theory.zig`; star_hands
      imports it; nothing else changes. `test-music-theory` with the spelling and naming tests. Proof star_hands did
      not move: it builds, and its headless screenshots - C Ionian at rest, a chord held, Hotel California's track
      chosen - match the ones taken before, pixel for pixel. ~1300 lines moved, ~100 new.
  S1  THE GRID PLAYS. The 47 keys, the photo's layout, Shepard, `onInput` and the fallback, pointers, the start screen,
      keys drawn with their notes (no scale colours yet). G1, G2, G3, G4. The browser-defaults check on a device (D8).
      The loudness measurement (5.4). ~700 lines.
  S2  THE SCALE. The tonic on F, the grid moving with the scale; degree colours and the stickers' colours; spelling;
      the header's tonic and mode; labels by interval from the tonic; the legend; the layouts as data: the Tonnetz
      turns, Wicki-Hayden, Janko, guitar fourths, custom, the two pianos; arrows to change layout. ~450 lines.
      (The hexagon view, 3.9 c, joins S8.)
  S3  WHAT SOUNDS, SHOWN. The chord line (name, numeral, function), triangles, the compass, the staircase; Shift and
      triangle taps play chords. ~400 lines.
  S4  THE STAR beside the grid, lit in step and playable. ~300 lines.
  S5  PROGRESSIONS. The track strip, matching by sound, the coming chord's occurrences and the nearest one, waiting,
      "play the chords" sounding. ~400 lines. S5b: recording a box from a chord played.
  S6  CHORD-KEY LAYOUTS. Scale chords (the seven chords on one row, the degrees on the others, following the scale)
      and Stradella. ~300 lines.
  S7  REAL OCTAVES. The organ instrument, the octave shift, the anchor of each layout chosen so the grid's middle is
      near middle C (D9). ~200 lines.
  S8  POLISH. The hexagon view (3.9 c), the phone layout, the catalogue row, the gallery's flagship list if Simon
      wants it there, the sound tutorial's mention of the new instrument (claude.md keeps that tutorial in step with
      every sound change).


## 7. What this costs and what it does not touch

  * New: one example (~2700 lines with its tests), one shared module (~1300 moved + ~200 new), three build steps.
  * Changed: star_hands' imports (S0) only - no behaviour.
  * The engine: nothing, unless D8 adds the browser key capture or the ISO key - each a few lines in `bridge.zig` /
    `dom_input.zig` / `native_input.zig` / `types.zig`, and their tests.


## 8. Risks

  R1 KEY ROLLOVER. Laptop keyboards drop or invent keys in some three- and four-key combinations (ghosting); a triangle
     is three keys in two rows. Some triangles may not play on some keyboards. Mitigation: a "keys held" readout in the
     diagnostics, Shift-chords as one-key chords, the touch grid. Measured on Simon's laptop in S1.
  R2 BROWSER DEFAULTS. Firefox's Quick Find on ' and /; Space scrolling. Measured in S1 (D8).
  R3 SIXTEEN VOICES. A note released keeps its voice for its tail. With eight held notes, strummed chords and tails,
     sixteen may run out. Measured in S1 by holding twelve keys and playing fast. The answer may be an engine change
     (more voices) - asked then, not assumed now.
  R4 LOUDNESS. Eight Shepard notes approach clipping (5.4). Measured in S1.
  R5 STAR_HANDS' EXTRACTION. A move across 7385 lines can change behaviour silently. S0's pixel comparison is the
     guard; the extraction is moves and renames only, no rewrite.
  R6 A PHONE HELD UPRIGHT. Fifteen keys across 390 pixels are 26 pixels each, too small for fingers. The grid is for
     a keyboard or a phone held sideways; upright, the demo says so above a smaller grid.
  R7 TOO MUCH ON THE GRID. Compass, triangles, staircase and coming-chord outlines at once can bury the keys. Each is
     an option, and the defaults are chosen on a screenshot in S3.


## 9. Decisions (asked one at a time, in this order - all taken)

  D1 THE EXAMPLE - DECIDED (Simon, Oct 31): "new example called magic isomorphic keyboard."
     `examples/magic_isomorphic_keyboard/`, titled "zimr - magic isomorphic keyboard".
  D2 THE SHARED THEORY - DECIDED (Simon, Oct 31): extract `examples/music_theory/` and switch star_hands to it (S0).
  D3 THE SOUND - DECIDED (Simon, Oct 31): Shepard by default; real octaves as an option, through a new soft "organ"
     instrument defined in the example (S7).
  D4 THE LAYOUTS IN v1 - DECIDED (Simon, Oct 31): the isomorphic catalogue and the two pianos (S2), chord-key layouts
     later (S6).
  D5 ONE-KEY CHORDS - DECIDED (Simon, Oct 31): Shift + key and triangle taps; no Space chord.
  D6 THE VIEWS - DECIDED (Simon, Oct 31): the grid, the small star beside it, the chord line; overlays switchable.
  D7 THE TRACK - DECIDED (Simon, Oct 31): a strip filled from the progressions list (S5), then recording (S5b).
  D8 THE ENGINE - DECIDED (Simon, Oct 31, after first answering "both now"): only if S1 shows a need - the key
     capture opt-in if ' or / misbehave in Chrome or Firefox, the ISO key if an ISO keyboard is to be played.
  D9 REAL OCTAVES - DECIDED (Simon, Oct 31): literal. The F key plays the tonic in middle C's octave (60 + its pitch
     class, as star_hands' `midiKeyOfDegree`), every other key by the rule - in C major the grid runs from B1 at /
     to D6 at the backquote, rising upward and to the left. TO ASK AGAIN AT S7: decided for the photo's layout; with
     fifths along the rows (D10) the literal rule spans seven octaves.
  D10 THE LAYOUT PLAYED - DECIDED (Simon, Nov 1): fifths to the right, major thirds down-right, minor thirds up-right
     (1.2), replacing the photo's as the layout played; the photo's kept as one of the layouts offered.

### 9.1 The final list - agreed by Simon, Oct 31 (D10 added Nov 1)

  D1  a new example, `magic_isomorphic_keyboard`, "zimr - magic isomorphic keyboard"
  D2  the theory in `examples/music_theory/music_theory.zig` (std + zm), star_hands switched to it in S0
  D3  Shepard tones by default; real octaves as an option, through a new "organ" instrument (S7)
  D4  S2 ships the photo's layout, its mirror, the other Tonnetz turns, Wicki-Hayden, Janko, guitar fourths, custom
      and the two pianos; scale chords and Stradella in S6
  D5  one-key chords: Shift + key (the scale's triad on its note) and a tap inside a drawn triangle; no Space chord
  D6  on screen: the grid, a small circle-of-thirds star lit in step and playable, a chord line (name, numeral,
      function); the compass, triangles and staircase on the grid, each switchable
  D7  the track: boxes filled from star_hands' progressions list (S5); recording a box from a chord played (S5b)
  D8  engine changes only if S1 measures a need: the page swallowing the keys the app plays; the ISO key
  D9  real octaves: the tonic on F in middle C's octave, the rest literal from the rule (B1 to D6 in C major) - to ask
      again at S7, for the fifths layout
  D10 the layout played: fifths right, major thirds down-right, minor thirds up-right (Simon's drawing, 1.2)
  --  from Simon's second picture (1.1), taken as given: the tonic on the F key by default, the grid moving with the
      scale; labels by interval from the tonic; the stickers' colours and a hexagon view as options



## 10. Appendix - the layouts' first keys

The photo's layout with the stickers' anchoring, `1` at C6 (MIDI 84), in MIDI keys. The default anchoring - the tonic
on F - is the same table moved so F plays the tonic: in C major, every number a semitone lower.

    `  87   1  84   2  81   3  78   4  75   5  72   6  69   7  66   8  63   9  60   0  57   -  54   =  51
    Q  77   W  74   E  71   R  68   T  65   Y  62   U  59   I  56   O  53   P  50   [  47   ]  44   \  41
    A  70   S  67   D  64   F  61   G  58   H  55   J  52   K  49   L  46   ;  43   '  40
    Z  63   X  60   C  57   V  54   B  51   N  48   M  45   ,  42   .  39   /  36

The two-octave piano (trackers' layout), semitones above its base (C3 by default):

    Z 0  S 1  X 2  D 3  C 4  V 5  G 6  B 7  H 8  N 9  J 10  M 11  , 12  L 13  . 14  ; 15  / 16
    Q 12  2 13  W 14  3 15  E 16  R 17  5 18  T 19  6 20  Y 21  7 22  U 23  I 24  9 25  O 26  0 27  P 28
    [ 29  = 30  ] 31


## 11. Journal

Oct 31 - plan v1 drafted. The photo decoded: all 41 stickers fit pitch(row, index) = pitch(`1`) - 3 x index - 7 x row,
the Tonnetz with minor thirds along the rows; the scale star's circle of thirds is a staircase on it. Decisions D1-D9
to be asked one at a time.

Oct 31 - D1 decided: "new example called magic isomorphic keyboard". The plan renamed to match
(`magic_isomorphic_keyboard_plan.md`). Simon's second message, two pictures: the lattice as hexagons with each place
named by its interval from C, and C major written on the laptop with the tonic on the F key. Every note in it fits the
photo's rule anchored at F (the stickers' grid a semitone lower). Taken in (1.1): the tonic on F by default, moving
with the scale; labels by interval from the tonic; the stickers' colours and a hexagon view as options; the headless
check rewritten for the tonic on F.

Oct 31 - D2 decided: the shared module, star_hands switched to it in S0.

Oct 31 - D3 decided: Shepard by default, the organ for real octaves as an option.

Oct 31 - D4 decided: the isomorphic catalogue and the two pianos first (S2), chord-key layouts in S6.

Oct 31 - D5 decided: Shift + key and triangle taps; Space plays nothing.

Oct 31 - D6 decided: grid + star + chord line.

Oct 31 - D7 decided: the list now, recording by playing in S5b.

Oct 31 - D8 decided: Simon first chose "both now", then changed his mind for the recommendation - measure in S1,
change the engine only if needed.

Oct 31 - D9 decided: literal octaves, the tonic on F in middle C's octave. Every decision taken; the final list (9.1)
put to Simon for agreement.

Oct 31 - Simon: "mark final, but don't implement". The plan is FINAL; nothing is implemented until he says go.

Nov 1 - Simon: "implement". S0 written, not compiled here (Simon builds):
  * `examples/music_theory/music_theory.zig` (new): 44 declarations moved verbatim from star_hands by a script -
    the scale (all_degrees ... the circle-of-thirds check), the progressions and `writeSongKey`, the tonics and modes
    the options offer (`ListedTonic` ... `writeAlterations`), chord naming (`PitchClassSet` ... `numeralNameOf` and
    the two comptime name checks), `functionNameOfDegree`. Made `pub`, methods included. Imports `std` alone (no zm:
    nothing moved needed it). Nine tests appended, each against hand-written expectations: D major's spelling and
    F#/G# majors' sevenths, no scale offered beyond two accidentals, four modes' semitones, C Dorian's chords, Hotel
    California in D, borrowed chords' alterations, song-key and mode-alteration labels, song tonics, the seventh's
    function name.
  * star_hands: the 44 removed; 29 bound by name from `music_theory`; `eql`, `startsWith`, `endsWith` aliases dropped
    (their only users moved); the header's file-order paragraph says where the theory went.
  * build.zig: `AppContext.music_theory_mod`, one module a target in the five contexts (web, Windows, Linux,
    headless, the platform check), imported by every example as `music_theory`; `zig build test-music-theory`.
  * Checked here: `zig fmt --check`, `zig ast-check` (undeclared names included) and zimrlint with every rule on the
    three files - clean.

Nov 1 - Simon: "proceed". S1 written, not compiled here:
  * `examples/magic_isomorphic_keyboard/magic_isomorphic_keyboard.zig` (new, 1013 lines): the 47 keys (`playing_keys`,
    each with its engine key's name; `engine_keys` read from those names when compiling, kept apart so the tests need
    no engine), the photo's layout as two numbers (`Isomorphic`, `thirds_layout`), the anchorings (`tonic_on_f`, and
    `stickers_anchoring` for the photo), `midiKeyOf`, Shepard sound keys (`soundKeyOf`: pitch class in middle C's
    octave, so 9 and X sound once), holds counted per sound key, computer keys through `onInput` with the per-frame
    fallback (repeats ignored; Escape and focus loss let go of everything), pointers with the 6-pixel switch distance
    and the nearest key within reach, the start-screen press ignored until lifted. Drawn as an ANSI keyboard - the
    other keys dark - in the stickers' colours: white naturals, lilac sharps, orange while sounding (every key of a
    sounding pitch class lights). Footer: the computer keys held (risk R1, rollover) and the latency readout (G3).
  * Tests (std + zm + music_theory, no engine): G1, the 41 stickers transcribed from the photo, under the stickers'
    anchoring; Simon's second picture, C major and G major with the tonic on F; middle C on F, B1 at /, D6 at the
    backquote (D9); every downward triangle a major triad, every upward one minor, all 24 present (G2).
  * Headless check (G4): `check.script` plays F, T, R, G, V alone, then F T R (C), D F R (Cm), G F T (Am), R 4 5 (G);
    `check.expect` worked out by hand as `audio_scale_star`'s.
  * build.zig: the app's entry in `wgpu_apps`; `zig build test-magic-isomorphic-keyboard`;
    `zig build magic-isomorphic-keyboard-check` (in the scale star's check block, sharing its checker).
  * examples_catalog.md: a row. The editor configs must be regenerated (`generate_editor_configs.bat`) - a new row in
    `wgpu_apps` makes `tripwires` fail until they are.

Nov 1 - Simon's drawing, a new layout to focus on: fifths to the right, major thirds down-right, minor thirds up-right
(1.2, D10). S1 moved to it before any build:
  * `fifths_layout` (`step_right` 7, `step_up_right` 3) is the layout played, held in `State.layout` so S2 can change
    it; the photo's `thirds_layout` stays, tested, for S2's catalogue. `drawing_anchoring` (F1 on 1) for the drawing's
    test. The header's doc, the legend and `midiKeyOf`'s doc describe the new layout.
  * Tests (7): the drawing's 29 naturals; the home row D to L as C major and G major with the tonic on F; C4 on F, C1
    at the backquote, B8 at the backslash; every major and minor triangle and all 24 triads - and the same three for
    the photo's layout (stickers, second picture, triangles), through shared helpers (`expectKeyNotes`,
    `expectAllTriads`, `TriangleShape`).
  * The headless check now plays F, G, V, H, D alone, then F G V (C), F T G (Cm), J I K (Am), G H B (G).
  * A slip on the way: a shell concatenation wrote over the example with its tests alone (its head file had not been
    written); the head was rebuilt from this session's record of the file, every edit since included, and re-checked
    (fmt, ast-check, lint). A copy of the result is kept in the session's scratchpad.

Nov 11 - R1 measured, and the left side's chord keys (Simon's design, outside the stages above):
  * R1, KEY ROLLOVER, is real on both of Simon's machines. On the ASUS TUF Gaming A18 a key of a held chord never
    arrives: a browser page outside zimr, listening to `keydown` alone, misses it too, so neither the events nor the
    mixer drop it. Read on the way: the Win32 queue holds 512 events a pass and drops only repeats; the page's bridge
    hands each `keydown` straight to `onInput`; the renderer has 16 instrument voices and a 256-event note queue, and
    the demo sends at most 12 sound keys. Filter Keys and Sticky Keys are off; no rollover setting was found for the
    laptop. Which chords fail was not recorded.
  * Simon's answer: the keyboard's left side plays chords - the keys up to the column of 5, T, G and B whose note is
    one of the scale's play the scale's triad on it (in C major: major on C, F, G; minor on D, E, A; diminished on B),
    its notes a strum apart (0.1 s), as on the two-handed star. C major only for now; the scale's dropdown comes
    later. Whether it replaces 3.6 (b), Shift for a key's chord, is not decided.
  * Written, not compiled here: `KeyNotes`, `chordOfKey`, `notesOfKey` (pure, tested); `HeldNotes` - what a key or a
    pointer holds, how many of its notes have started and when the hold began - in place of a key's one sound key;
    `beginHold`, `startDueNotes` (once a frame), `endHold` (a waiting note never starts). The left side's keys outside
    the scale play their own note. Chord keys are drawn green, named as chords (`chordLetterName`), and a key is lit
    while held or while every note it plays sounds (`isKeyLit`).
  * Tests (3 more, 10 in all): the fifteen chord keys of C major spelled by hand, with a major, a minor and the
    diminished quality; the left side's sharps and the right side's keys playing one note; G major, the chords moved
    with the scale.
  * The headless check plays the right side - I, O, K, H, U alone, then I O K (C), I 9 O (Cm), J I K (Am), O P L (G) -
    then the seven chord keys F, D, G, X, V, C, B; F held while K plays its third; D let go before its third, under H.
  * Checked here: `zig fmt --check`, `zig ast-check`, and zimrlint with every rule (60), clean - and red on a copy
    with a planted finding. Not run: the tests, the headless check, the app.

Nov 11 - the scale's dropdowns and the chords' volume (Simon: "add the scale dropdown like in the star demo, and make
the volume of the chord tweakable also, so we can play on top of it with the right hand"):
  * The header is the engine's UI now (`buildHeader`, as star_hands' header): the tonic's dropdown, the mode's - each
    mode in two lines, its name and alterations, then its seven chords on the tonic - and a slider, "chords". The
    drawn title is gone; the legend sits under the controls. The tonic stays on F: a scale picked moves every key's
    note, and the left side's chords are the new scale's. What is held sounds on as struck until let go.
  * The mode's label is written by `music_theory.writeModeLabel` (new, with `mode_label_capacity` and
    `mode_label_columns`, and a test of C Dorian's and G Ionian's labels); star_hands' `writeModeLabels` calls it too,
    its own copy of the writing removed - one copy, as D2 asks.
  * Two strengths, as star_hands' thumb and full (`HoldLayer`, `SoundKeyHolds`, `strengthOfSoundKey`,
    `soundStrengthChange`): a chord's key holds its notes softly, at `State.chord_volume` of a note's strength (0.5
    at the start; star_hands' chooser chord starts at 0.3 - 0.5 keeps the headless check's notes well above its
    threshold of presence, and is Simon's to tune by ear); a note's own key holds it fully. A note a chord holds,
    pressed by the right hand, is struck again fully; let go, it rings on as struck. A chord takes the volume of the
    moment it is struck.
  * A note of the scale is named as the scale spells it (`noteNameIn`): Bb in F major, not A#.
  * The pointers leave the controls alone: a list open (or open at the last frame), or a press in the header, lets
    go of what the pointers hold and makes them wait until lifted (`readPointers`) - the slider's handle dragged over
    the keys plays none.
  * The headless check's chord windows are 0.1150 now (three notes at half strength); F held with K: 0.1626.
  * Checked here: `zig fmt --check`, `zig ast-check` and zimrlint with every rule on the keyboard, music_theory and
    star_hands - clean (it caught `releasePointers` declared after its use, moved). Not run: the tests
    (`test-music-theory`, `test-magic-isomorphic-keyboard`), the headless checks, either app.
