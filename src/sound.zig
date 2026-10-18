//! lint:alias sound
//! lint:off arch-check: WebAudio - native audio comes with C5
// src/sound.zig - the engine's sound.
//
// THE TWO LAYERS. Sound in the engine is moving from the browser's audio graph to the engine's own mixer (platforms
// plan, decision D10, steps C5), and during the move this file holds both:
//
//   mixer - the engine's one mixer. Every sound is a voice reading a source - samples in memory, a generator, or a
//           stream's ring - with its own volume, pan and pitch. Its renderer mixes every playing voice into each block
//           the platform's output asks for: natively on the output's audio thread, headless on the run's clock, and
//           on a page in the audio worklet, where a second instance of the app's module runs it.
//
//   audio_device, waves, composer, sounds, streams, music, analyser - the raylib-shaped API apps use, each built on
//           the mixer: a sound a voice of its samples, a stream a voice of its ring, music a stream its decoder fills,
//           the analyser a tap on what the renderer mixed.
//
// HOW A SOUND REACHES A SPEAKER, through the mixer:
//
//   app: play(source) ---> a voice in the mixer          (main thread, during the app's update)
//   engine, after update: mixer.mixFrame()               (main thread, once a drawn frame)
//       asks the output how many frames still wait, mixes the difference up to the margin - 50 ms at first -
//       every voice read at its pitch, scaled by its gains, summed, held to -1..1 - and queues the block
//   platform's output: plays the queue on its own clock  (a device's thread, the browser's worklet, or a headless
//       run's clock), playing silence - an underrun - when the queue runs dry; the mixer then widens its margin
//
// THE FORMAT is fixed: 48 000 frames a second, two channels, 32-bit float samples interleaved left, right, left,
// right. A frame is one moment of sound, one sample per channel; durations of sound are counted in frames, exactly.
//
// THE SECTIONS, in order: mixer (the foundation the others are being moved onto), audio_device (the mixer's start
// and stop, and the browser's context), analyser, waves (samples in memory, and their edits), composer (synthesis),
// streams (pushed samples), music (long sounds), sounds (one-shot effects).
//
// RELATED FILES: src/platform/contract.zig (the four audio requests an output answers), src/platform/headless.zig (an
// output with no speaker, playing on the run's clock, whose sound a script can capture), src/codecs.zig (`audio`:
// WAV decoding and encoding), and the sound tutorial (`src/notes/tutorials/sound_tutorial.html`), which explains
// the mixer, its outputs and its instruments with worked numbers.

const std = @import("std");
const ArrayList = std.ArrayList;
const bufPrint = std.fmt.bufPrint;
const expect = std.testing.expect;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing_allocator = std.testing.allocator;
const readInt = std.mem.readInt;
const writeInt = std.mem.writeInt;
const builtin = @import("builtin");
const zm = @import("zm");
const zn = @import("zn");
const sinTurns = zm.sinTurns;
const cosTurns = zm.cosTurns;
const float64 = zm.float64;
const assert = zm.assert;
const assertf = zm.assertf;
const assertUnreachable = zm.assertUnreachable;
const panicf = zm.panicf;
const asBytes = std.mem.asBytes;
const clamp = zm.clamp;
const tanh = zm.tanh;
const cache_line = std.atomic.cache_line;
const copyForwards = std.mem.copyForwards;
const sliceAsBytes = std.mem.sliceAsBytes;
const indexOfScalar = std.mem.indexOfScalar;
const Random = std.Random;
const expectEqualStrings = std.testing.expectEqualStrings;
const float = zm.float;
const exp2 = zm.exp2;
const exp = zm.exp;
const log2 = zm.log2;
const floor = zm.floor;
const sqrt = zm.sqrt;
const pi = zm.pi;

// lint:off browser-call: WebAudio; native audio comes with C5
const web = @import("web.zig");
const codecs = @import("codecs.zig");
const platform = @import("platform.zig");
const contract = platform.contract;
const types = @import("types.zig");

const Wave = types.Wave;
const Sound = types.Sound;
const Music = types.Music;
const AudioStream = types.AudioStream;

// ============================================================================
// SECTION - mixer (the engine's one mixer: voices read from their sources, mixed as the output asks for them)
// ============================================================================
// Every sound the engine plays is a voice: a source of samples, read as it is needed, with its own volume, pan and
// pitch. The app asks for sounds from the main thread - a play, a stop, a note - and each request travels to the
// renderer as a command. The output asks the renderer for each block of frames when its device needs it - from a
// device's audio thread on Windows, from the browser's audio worklet or script processor in a page, at each frame's
// time in a headless run - and the renderer applies the commands waiting, then mixes every playing voice into the
// block. Nothing waits in a queue between the renderer and the speaker, so a request is heard from the next block.
//
// The format is fixed: 48 000 frames a second, two channels, 32-bit float samples, interleaved - left, right, left,
// right. A frame is one moment of sound: one sample per channel.
//
// A voice's position in a sample source is counted in the source's frames as 32.32 fixed point: an unsigned 64-bit
// integer whose high 32 bits are whole frames and whose low 32 bits are a fraction of a frame, in units of 1/2^32.
// Pitch moves the position by fractions of a frame each mixed frame; fixed point adds those fractions exactly, frame
// after frame, where a float position would gather rounding error over minutes of playing. Between the two source
// frames around the position, the sample is interpolated linearly.

pub const mixer = struct {
    /// Frames a second the engine mixes.
    pub const sample_rate: u32 = 48_000;
    /// Channels in a mixed frame: left and right.
    pub const channel_count: u8 = 2;
    /// The most voices playing at once. A sound asked for when every voice is playing is not played: `play` returns
    /// `Voice.none`.
    pub const voice_capacity: usize = 64;
    /// The slots kept for the instrument's notes (`Instrument`): the last `instrument_voice_count` of the
    /// `voice_capacity`. The main side never plays in them (`Mixer.play` looks below `first_instrument_slot`), so a
    /// note can start without the main side naming its voice first - from wherever the key's event arrives, at the
    /// moment it arrives. Sixteen notes sound at once: ten fingers, and the tails of notes just released.
    pub const instrument_voice_count: usize = 16;
    pub const first_instrument_slot: usize = voice_capacity - instrument_voice_count;
    /// How many measured starts the main side keeps (`Mixer.recentStarts`).
    pub const recent_start_capacity: usize = 10;

    /// The most frames the renderer renders at once: 9 600, 200 ms. An output may ask for more in one request - a
    /// headless run catching up on a long frame - and the mixer then renders it in blocks of this size
    /// (`renderForPullingOutput`). A voice's scratch block holds this many frames, allocated once at `start`, so that
    /// rendering allocates nothing.
    pub const render_block_most_frames: u32 = 9_600;
    /// The most commands a forwarded message holds (`Mixer.forward_batch`): a frame's commands travel together, and a
    /// frame with more sends more messages.
    pub const forward_batch_command_capacity: usize = 32;

    /// The platform's output, as the mixer uses it: the contract's audio requests. Every output pulls - it asks the
    /// mixer's renderer for each block when its device needs it (`start_pulling`) - or, where the platform offers a
    /// renderer in another memory, is forwarded to (`forwarding`). They are held as function pointers so that only a
    /// program that starts sound compiles the platform's own (`platformOutput`) - a platform whose output is not
    /// written yet refuses at compile time - and so that a test can stand in an output of its own.
    pub const Output = struct {
        /// Opens the output so that it pulls its frames from the renderer, handing it `render_callback`, and returns
        /// the format granted (`contract.startAudioPull`).
        start_pulling: *const fn (
            wanted: contract.AudioFormat,
            render_callback: contract.AudioRenderCallback,
        ) contract.AudioFormat,
        /// The clock sound is timed by (`contract.audioClockMilliseconds`): requests are stamped with it, and the
        /// output's timing of each block is on it, so the lag of each start can be measured (`LatencySample`).
        clock_ms: *const fn () f64,
        /// What lies past the output's queue, and the output's name (`contract.audioOutputLatencyMilliseconds`,
        /// `audioOutputName`): the readout's last column, and which of a platform's paths plays.
        latency_ms: *const fn () f64,
        name: *const fn () []const u8,
        stop: *const fn () void,
        /// Whether the output calls the renderer from a thread of its own - a device's audio thread - rather than
        /// from the main thread. Then the main side never runs the renderer itself: it waits for a full queue to empty
        /// (`Mixer.sendToRenderer`), and frees samples only once the renderer lets them go (`Mixer.releaseSamples`).
        calls_renderer_from_another_thread: bool = false,
        /// A renderer in another memory the platform may offer - the browser's audio worklet - which the mixer then
        /// forwards to instead of rendering itself (`ForwardingOutput`); null where there is none.
        forwarding: ?ForwardingOutput = null,
    };

    /// An output whose renderer runs in another memory, reached only by messages: the browser's audio worklet, a second
    /// instance of the app's module (`RendererHost`, `worklet_abi`). The mixer forwards each frame's commands to it
    /// (`forwardCommands`) and reads the notices it sends back (`acceptNoticeBytes`); its own renderer stays unused.
    pub const ForwardingOutput = struct {
        /// Starts the renderer's output, and returns the format it plays at; null when the platform cannot forward
        /// after all - the page's worklet did not load - and the mixer then starts the platform's other output (the
        /// page's: pulled on the main thread, `startAudioPull`).
        start: *const fn (wanted: contract.AudioFormat) ?contract.AudioFormat,
        /// A command's bytes, as `CommandSink.send_command_bytes` hands them.
        send_command_bytes: *const fn (command_bytes: []const u8) void,
        /// Samples to register under an id, as `CommandSink.send_samples` hands them.
        send_samples: *const fn (samples_id: SamplesId, samples: []const f32) void,
        /// A key's event for the instrument, as plain values - a platform cannot name the mixer's types.
        /// A note, with the times it is measured from (`NoteEvent.requested_at_ms`, `pressed_at_ms`): the renderer in
        /// the other memory measures its start as one of its own would be (`LatencySample`).
        send_note: *const fn (
            key: u8,
            is_down: bool,
            velocity: f32,
            requested_at_ms: f64,
            pressed_at_ms: f64,
        ) void,
        /// Copies into `notice_bytes` as many whole notices, of `notice_byte_count` bytes each, as came back and fit,
        /// and says how many bytes it wrote.
        take_notice_bytes: *const fn (notice_bytes: []u8, notice_byte_count: usize) usize,
        /// A forwarded stream's frames, written by the game since the last ones sent, interleaved, as plain values:
        /// the stream's number, its channels and its rate (`ForwardedStream`). Null on a platform that does not carry
        /// them yet: a stream then does not play there (`Mixer.play`).
        send_stream_frames: ?*const fn (
            stream_id: u8,
            channels: u8,
            frames_per_second: u32,
            frames: []const f32,
        ) void = null,
        /// Asks the renderer in the other memory for its last frames mixed, for an analyser (`analyser.read`): at
        /// most one request waits at a time, the next asked once the answer came. Null on a platform that does not
        /// carry them: an analyser there reads silence.
        ask_analysis: ?*const fn () void = null,
        /// Copies the last `frames.len` frames of the renderer's last answer into `frames`, oldest first, and says how
        /// many it copied: `frames.len`, or 0 before the first answer.
        take_analysis_frames: ?*const fn (frames: []f32) usize = null,
    };

    /// The output of the platform the program was built for (`platform.current`), on the thread its kind names
    /// (`audio_output_kind`).
    pub fn platformOutput() Output {
        return outputOf(platform.current);
    }

    /// The output of `Platform`, one of `platform.zig`'s: the tests name the headless one, whose clock they drive,
    /// whatever system they run on.
    fn outputOf(comptime Platform: type) Output {
        const output_kind: contract.AudioOutputKind = comptime Platform.audio_output_kind;
        return .{
            .start_pulling = &Platform.startAudioPull,
            .clock_ms = &Platform.audioClockMilliseconds,
            .latency_ms = &Platform.audioOutputLatencyMilliseconds,
            .name = &Platform.audioOutputName,
            .stop = &Platform.stopAudio,
            .calls_renderer_from_another_thread = output_kind == .pull_on_audio_thread,
            .forwarding = if (@hasDecl(Platform, "startAudioForwarding")) .{
                .start = &Platform.startAudioForwarding,
                .send_command_bytes = &Platform.forwardAudioCommandBytes,
                .send_samples = &Platform.forwardAudioSamples,
                .send_note = &Platform.forwardAudioNote,
                .take_notice_bytes = &Platform.takeAudioNoticeBytes,
                .send_stream_frames = if (@hasDecl(Platform, "forwardAudioStreamFrames"))
                    &Platform.forwardAudioStreamFrames
                else
                    null,
                .ask_analysis = if (@hasDecl(Platform, "askAudioAnalysis")) &Platform.askAudioAnalysis else null,
                .take_analysis_frames = if (@hasDecl(Platform, "takeAudioAnalysisFrames"))
                    &Platform.takeAudioAnalysisFrames
                else
                    null,
            } else null,
        };
    }

    /// A voice's name: the index of its slot in the low 8 bits, and that slot's generation in the 24 bits above. A
    /// slot's generation moves on when its voice ends, so a name kept after its voice ended names nothing: the slot's
    /// next voice answers to a new name, and a call with the old one finds no voice and does nothing. `none` names no
    /// voice; it cannot be made by a slot, since slot 255 is past the capacity.
    pub const Voice = enum(u32) {
        none = zm.maxInt(u32),
        _,

        /// The name of the voice now playing in slot `slot_index`, whose generation is `slot_generation`.
        fn ofSlot(slot_index: usize, slot_generation: u24) Voice {
            const generation_bits: u32 = @as(u32, slot_generation) << 8;
            const slot_bits: u32 = @intCast(slot_index);
            return @fromBackingInt(generation_bits | slot_bits);
        }

        fn slotIndex(voice: Voice) usize {
            const slot_bits: u32 = @backingInt(voice) & 0xff;
            return slot_bits;
        }

        fn generation(voice: Voice) u24 {
            const generation_bits: u32 = @backingInt(voice) >> 8;
            return @intCast(generation_bits);
        }
    };

    /// Samples in memory, played from their start: interleaved, `channels` of them per frame (1 or 2), recorded at
    /// their own `sample_rate`. A source recorded at another rate than the mixer's still plays at its own speed: its
    /// voice's position moves by its rate over the mixer's each mixed frame.
    pub const Samples = struct {
        samples: []const f32,
        channels: u8,
        sample_rate: u32,
        is_looping: bool = false,
    };

    /// A source that makes its frames when they are needed - a tone, a synthesizer. `generate` writes stereo frames
    /// into `frames` (two samples each, left then right), the first of them being frame `first_frame` of the voice,
    /// at the mixer's rate. A generator does not end by itself; stopping its voice ends it.
    ///
    /// Its state - a frequency, a phase, a filter's memory - is the voice's own. `play` copies `initial_state` into
    /// the voice (at most `generator_state_capacity` bytes, needing no more alignment than 16), and `generate` is
    /// handed the voice's copy, to read and change as it likes. Nothing is shared: `generate` runs where the renderer
    /// runs - on a device's audio thread, or in the browser's audio worklet, which cannot see the app's memory at
    /// all - and the main side changes the sound through the voice's commands, never by writing to a state.
    ///
    /// `channels` says what its frames hold, as a sample source's does, and so how a pan places it (`panLawOf`): 1 when
    /// both samples of a frame are the same sound - a mono tone, placed at constant power - and 2 when they are two
    /// channels of a stereo sound, balanced.
    pub const Generator = struct {
        generate: *const fn (state: *anyopaque, frames: []f32, first_frame: u64) void,
        initial_state: []const u8 = &.{},
        channels: u8 = 1,
    };

    /// The most bytes a generator's state may hold (`Generator.initial_state`): it travels inside the play command.
    pub const generator_state_capacity: usize = 64;

    /// The frequency of a MIDI key: each key a semitone, a twelfth of an octave, from key 69, the A at 440 Hz. An
    /// octave doubles the frequency, so `n` semitones multiply it by 2 to the power `n / 12`.
    pub fn frequencyOfKey(key: u8) f32 {
        const semitones_from_a440: f32 = float(key) - 69;
        return 440 * exp2(semitones_from_a440 / 12);
    }

    /// The simplest instrument: a sine at the key's frequency, struck at the key's velocity, held while the key is
    /// down, then fading by half every 50 ms once it is up - an exponential release, as a string or a filter's
    /// output dies away. A note falls silent when its level is below 1/10 000 (-80 dB). Its state is a
    /// `SineNoteState`.
    pub const sine_instrument: Instrument = .{
        .generate = &generateSineNote,
        .start_note = &startSineNote,
        .release_note = &releaseSineNote,
        .has_fallen_silent = &hasSineNoteFallenSilent,
    };

    /// A sine note's state: where it is in its cycle, how far it moves each frame, its level now, and the factor the
    /// level is multiplied by each frame - 1 while held, a little under 1 once released.
    ///
    /// The phase is kept here, in turns, and wrapped back below one turn at every frame, rather than computed from
    /// the frame's number. Computed as `frequency x frame / rate`, it grows without end: after 20 seconds at 440 Hz it
    /// is 8 800 turns, where a 32-bit float can only tell values apart every thousandth of a turn - and that rounding
    /// is heard as noise, 46 dB below the note (measured). Wrapped, it never passes one turn, and kept in 64 bits the
    /// step's own rounding takes days to amount to anything.
    const SineNoteState = struct {
        phase_turns: f64,
        phase_step_turns: f64,
        level: f32,
        level_factor_per_frame: f32,
    };
    /// The release's half-life: 50 ms, 2 400 frames. Halving every 2 400 frames is multiplying by 2^(-1/2400) each
    /// frame.
    const sine_release_half_life_frames: f32 = 2_400;
    const silent_level: f32 = 1.0e-4;

    fn startSineNote(state: *anyopaque, key: u8, velocity: f32) void {
        const note: *SineNoteState = @ptrCast(@alignCast(state));
        const frequency: f64 = frequencyOfKey(key);
        const phase_step_turns: f64 = frequency / float64(sample_rate);
        note.* = .{
            .phase_turns = 0,
            .phase_step_turns = phase_step_turns,
            .level = velocity,
            .level_factor_per_frame = 1,
        };
    }

    fn releaseSineNote(state: *anyopaque) void {
        const note: *SineNoteState = @ptrCast(@alignCast(state));
        note.level_factor_per_frame = exp2(-1 / sine_release_half_life_frames);
    }

    fn hasSineNoteFallenSilent(state: *anyopaque) bool {
        const note: *const SineNoteState = @ptrCast(@alignCast(state));
        return note.level < silent_level;
    }

    /// The sine at the note's phase, which carries over from block to block in the state, so that the note is
    /// continuous across blocks; each frame's sample is the sine times the level, then the phase moves by its step,
    /// wrapped below one turn, and the level by its factor. The frame number is not needed: the state knows where the
    /// note is.
    fn generateSineNote(state: *anyopaque, frames: []f32, first_frame: u64) void {
        _ = first_frame;
        const note: *SineNoteState = @ptrCast(@alignCast(state));
        const frame_count: usize = frames.len / channel_count;
        for (0..frame_count) |frame_offset| {
            const phase_turns: f32 = @floatCast(note.phase_turns);
            const value: f32 = note.level * sinTurns(phase_turns);
            frames[frame_offset * channel_count] = value;
            frames[frame_offset * channel_count + 1] = value;
            const next_phase_turns: f64 = note.phase_turns + note.phase_step_turns;
            note.phase_turns = next_phase_turns - @floor(next_phase_turns);
            note.level *= note.level_factor_per_frame;
        }
    }

    comptime {
        if (@sizeOf(SineNoteState) > generator_state_capacity) {
            @compileError("a sine note's state must fit in a voice's generator state");
        }
    }

    /// Shepard tones: each note is its pitch class sounding in every octave at once, so that the notes differ in pitch
    /// class - C, C sharp, D ... - and not in height. A scale played up and around the circle of twelve neither rises
    /// nor falls; played on and on, it seems to rise for ever (Roger Shepard's illusion, 1964).
    ///
    /// A note is a sum of sines an octave apart - `f, 2f, 4f, ...` across the audible range - each with the height of
    /// one bell at its frequency: a Gaussian in log-frequency, centred at 400 Hz, one octave wide (its standard
    /// deviation). The same bell for every note:
    ///
    ///     amplitude
    ///       |                    _.-~~~-._
    ///       |                _.-'    |    '-._              the bell, over octaves from its centre
    ///       |       ___..--''   |    |    |   ''--..___
    ///       +---------+----+----+----+----+----+----+-----  octaves from 400 Hz
    ///                -3   -2   -1    0    1    2    3
    ///          C's partials:  |    |    |    |    |    |    one an octave
    ///          D's:             |    |    |    |    |    |  the same, a whole tone up
    ///
    /// so each note's partials sit under it at the same spacing, shifted by the note's place in the octave. Two
    /// properties follow, and the tests measure both.
    ///
    /// The same height. A note's spectrum, weighted by amplitude, has its centroid in log-frequency at the bell's
    /// centre, for every pitch class. The partials sample the bell at whole octaves from an offset - the note's place
    /// in the octave - and the mean of a Gaussian sampled at evenly spaced points moves with their offset only by
    /// about `4 pi sigma^2 exp(-2 pi^2 sigma^2)` of the spacing (Poisson summation: the sampled sum's Fourier series,
    /// whose first term carries that factor): 3e-8 octaves for a width `sigma` of one octave - a cent is 1/1200 of an
    /// octave.
    ///
    /// The same loudness. The partials' frequencies differ, so their powers add: a note's power is the sum of its
    /// partials' squared amplitudes, the bell squared sampled at the same points - again the same for every offset,
    /// to a few parts in 100 000.
    ///
    /// That holds for octaves on both sides of the centre without end; cut short, the bell's tails would be cut
    /// unevenly. So a note's partials reach five octaves either side of the centre, where the bell is below four
    /// millionths of its peak: ten partials, the lowest between 12.5 and 25 Hz - inaudible, and weighted too little
    /// to matter - and the highest between 6.4 and 12.8 kHz. The key's octave is ignored by design: only its pitch
    /// class, `key mod 12`, chooses the partials.
    ///
    /// The amplitudes are scaled by the bell's whole area, so that the partials' amplitudes sum to 1 at most - the
    /// loudest a note can be, its partials all at their peaks at once - and a note's level is its key's velocity,
    /// times that. A note rises from silence over `shepard_attack_frames` (2 ms) rather than starting at its level: a
    /// sudden start is heard as a click, and a chord's thirty partials starting together click louder than one sine.
    /// Its release is the sine instrument's: half its level every 50 ms once its key is up, silent below -80 dB.
    pub const shepard_instrument: Instrument = .{
        .generate = &generateShepardNote,
        .start_note = &startShepardNote,
        .release_note = &releaseShepardNote,
        .has_fallen_silent = &hasShepardNoteFallenSilent,
    };

    /// The bell all Shepard notes sit under: its centre, and its width - the Gaussian's standard deviation - in
    /// octaves.
    pub const shepard_bell_centre_hz: f64 = 400;
    pub const shepard_bell_width_octaves: f64 = 1;
    /// How far a note's partials reach either side of the bell's centre, in octaves, and so how many there are: one an
    /// octave, across twice that reach.
    const shepard_reach_octaves: f64 = 5;
    pub const shepard_partial_count: usize = 10;
    /// A note's attack: its level rises from 0 to the key's velocity over 96 frames, 2 ms.
    pub const shepard_attack_frames: u32 = 96;

    /// What a Shepard note of one pitch class plays: the step of its lowest partial, in turns a frame, and each
    /// partial's amplitude, the lowest partial's first.
    const ShepardPitchClass = struct {
        lowest_phase_step_turns: f64,
        partial_amplitudes: [shepard_partial_count]f32,
    };

    /// The partials of each of the twelve pitch classes, C first, computed when compiling - they depend only on the
    /// pitch class.
    const shepard_pitch_classes: [12]ShepardPitchClass = shepardPitchClasses();

    fn shepardPitchClasses() [12]ShepardPitchClass {
        var pitch_classes: [12]ShepardPitchClass = undefined;
        // The bell's area, sampled at unit spacing: the sum of all its samples, whatever their offset - the scale that
        // makes the partials' amplitudes sum to 1.
        const bell_area: f64 = shepard_bell_width_octaves * sqrt(@as(f64, 2 * pi));
        for (&pitch_classes, 0..) |*pitch_class, semitones_above_c| {
            // The pitch class in middle C's octave - key 60 and up - as `frequencyOfKey` gives it, and how many
            // octaves that is from the bell's centre.
            const semitones_from_a440: f64 = float64(semitones_above_c) + 60 - 69;
            const key_frequency: f64 = 440 * exp2(semitones_from_a440 / 12);
            const octaves_from_centre: f64 = log2(key_frequency / shepard_bell_centre_hz);
            // The same pitch class whole octaves down, to the reach's lower end: the lowest partial, between 5 and 4
            // octaves below the centre.
            const octaves_above_reach_start: f64 = octaves_from_centre + shepard_reach_octaves;
            const lowest_octaves_from_centre: f64 =
                octaves_above_reach_start - floor(octaves_above_reach_start) - shepard_reach_octaves;
            const lowest_frequency: f64 = shepard_bell_centre_hz * exp2(lowest_octaves_from_centre);
            pitch_class.lowest_phase_step_turns = lowest_frequency / float64(sample_rate);
            for (&pitch_class.partial_amplitudes, 0..) |*partial_amplitude, partial_index| {
                const partial_octaves_from_centre: f64 =
                    lowest_octaves_from_centre + float64(partial_index);
                const standard_deviations: f64 = partial_octaves_from_centre / shepard_bell_width_octaves;
                const bell_height: f64 = exp(-0.5 * standard_deviations * standard_deviations);
                partial_amplitude.* = @floatCast(bell_height / bell_area);
            }
        }
        return pitch_classes;
    }

    /// A Shepard note's state: the lowest partial's phase and step, as a sine note keeps them (`SineNoteState`
    /// explains why in turns, wrapped, in 64 bits); its level now, and what changes it each frame - the attack's step
    /// added until the level reaches the velocity, the release's factor multiplied once the key is up; and its pitch
    /// class, which picks its partials' amplitudes.
    const ShepardNoteState = struct {
        phase_turns: f64,
        phase_step_turns: f64,
        level: f32,
        velocity: f32,
        attack_step_per_frame: f32,
        level_factor_per_frame: f32,
        pitch_class: u8,
    };

    fn startShepardNote(state: *anyopaque, key: u8, velocity: f32) void {
        const note: *ShepardNoteState = @ptrCast(@alignCast(state));
        const pitch_class: u8 = key % 12;
        note.* = .{
            .phase_turns = 0,
            .phase_step_turns = shepard_pitch_classes[pitch_class].lowest_phase_step_turns,
            .level = 0,
            .velocity = velocity,
            .attack_step_per_frame = velocity / float(shepard_attack_frames),
            .level_factor_per_frame = 1,
            .pitch_class = pitch_class,
        };
    }

    /// The release: the attack stops where it is, and the level halves every 50 ms from there.
    fn releaseShepardNote(state: *anyopaque) void {
        const note: *ShepardNoteState = @ptrCast(@alignCast(state));
        note.attack_step_per_frame = 0;
        note.level_factor_per_frame = exp2(-1 / sine_release_half_life_frames);
    }

    /// Silent once released and below -80 dB. A held note is never silent, though it starts at level 0 - its attack
    /// begins there.
    fn hasShepardNoteFallenSilent(state: *anyopaque) bool {
        const note: *const ShepardNoteState = @ptrCast(@alignCast(state));
        const is_released: bool = note.level_factor_per_frame < 1;
        return is_released and note.level < silent_level;
    }

    /// Each frame: the partials summed, times the level; then the phase, the attack and the release move on.
    ///
    /// The partials from one sine and one cosine. Partial `k` is at `2^k` times the lowest partial's angle, so each is
    /// the one below it, doubled: `sin 2a = 2 sin a cos a` and `cos 2a = cos^2 a - sin^2 a`. Starting from the lowest
    /// partial's sine and cosine, nine doublings give the other nine - two trigonometric functions a frame instead of
    /// ten, which matters for a chord: three notes of ten partials, 48 000 frames a second. Each doubling doubles the
    /// rounding error of the angle, so the highest partial's is 512 times the lowest's: 512 times f32's 6e-8 turns is
    /// 3e-5 turns, and that partial's amplitude is four millionths - far below hearing either way.
    fn generateShepardNote(state: *anyopaque, frames: []f32, first_frame: u64) void {
        _ = first_frame;
        const note: *ShepardNoteState = @ptrCast(@alignCast(state));
        const partial_amplitudes: *const [shepard_partial_count]f32 =
            &shepard_pitch_classes[note.pitch_class].partial_amplitudes;
        const frame_count: usize = frames.len / channel_count;
        for (0..frame_count) |frame_offset| {
            const lowest_phase_turns: f32 = @floatCast(note.phase_turns);
            var partial_sine: f32 = sinTurns(lowest_phase_turns);
            var partial_cosine: f32 = cosTurns(lowest_phase_turns);
            var partials_sum: f32 = 0;
            for (partial_amplitudes) |partial_amplitude| {
                partials_sum += partial_amplitude * partial_sine;
                const octave_up_sine: f32 = 2 * partial_sine * partial_cosine;
                const octave_up_cosine: f32 = partial_cosine * partial_cosine - partial_sine * partial_sine;
                partial_sine = octave_up_sine;
                partial_cosine = octave_up_cosine;
            }
            const value: f32 = note.level * partials_sum;
            frames[frame_offset * channel_count] = value;
            frames[frame_offset * channel_count + 1] = value;
            const next_phase_turns: f64 = note.phase_turns + note.phase_step_turns;
            note.phase_turns = next_phase_turns - @floor(next_phase_turns);
            note.level = @min(note.level + note.attack_step_per_frame, note.velocity);
            note.level *= note.level_factor_per_frame;
        }
    }

    comptime {
        if (@sizeOf(ShepardNoteState) > generator_state_capacity) {
            @compileError("a Shepard note's state must fit in a voice's generator state");
        }
    }

    /// What a voice plays.
    pub const Source = union(enum) {
        samples: Samples,
        generator: Generator,
        stream: Stream,
    };

    /// A source the game makes as it plays - a synthesizer's output, a decoder's - written as it goes into a ring the
    /// game owns (`StreamRing`), and read out by the voice at the ring's rate and the voice's pitch, as samples are
    /// read. A stream does not end by itself: a ring run dry plays silence, counted, and stopping the voice ends it.
    /// The ring is read where it lies, so a stream plays only where the renderer shares the game's memory - natively,
    /// headless, and the page's script processor; to a page's audio worklet, which has a memory of its own, `play`
    /// refuses one.
    pub const Stream = struct {
        ring: *StreamRing,
    };

    /// An instrument: what plays a note while its key is held, and after. It runs on the renderer's side, in the
    /// instrument's slots (`first_instrument_slot`), so that a key's note starts at the next block the output asks
    /// for - not at the app's next frame, which may be a whole frame and its drawing away. Each note is a voice
    /// playing a generator, `generate`, whose state - the note's own, `generator_state_capacity` bytes - the other
    /// three functions fill and read:
    ///
    ///     key down    start_note(state, key, velocity)   the note's state made: its frequency, its envelope
    ///     each block  generate(state, frames, first)     the note's frames, as any generator's (`Generator`)
    ///     key up      release_note(state)                its envelope turns to its release
    ///     each block  has_fallen_silent(state)           true once the release has died away: the slot is freed
    ///
    /// The functions are function pointers, and so the same functions in the browser's worklet instance as in the
    /// app's (`Generator` explains why). A note's frames are mono: both samples of a frame alike, placed at the centre.
    pub const Instrument = struct {
        generate: *const fn (state: *anyopaque, frames: []f32, first_frame: u64) void,
        start_note: *const fn (state: *anyopaque, key: u8, velocity: f32) void,
        release_note: *const fn (state: *anyopaque) void,
        has_fallen_silent: *const fn (state: *anyopaque) bool,
        /// Whether a note starts at its own moment within its block (`Renderer.startNote`) rather than at the block's
        /// first frame. A note requested a little after the block before was asked for starts that much into its
        /// block - 0.5 ms later, 24 frames in - so that notes requested a few milliseconds apart sound as far apart,
        /// whatever moments the blocks are asked for at. The price is a constant delay of up to one block more. Off
        /// by default: a note starts in the next block.
        places_notes_by_time: bool = false,
    };

    /// A key going down or up, for the instrument. `key` numbers the notes as MIDI does: 60 is middle C, 69 the A
    /// above it at 440 Hz, one step per semitone. `velocity`, from 0 to 1, is how hard the key went down; a key going
    /// up carries none.
    pub const NoteEvent = struct {
        key: u8,
        is_down: bool,
        velocity: f32 = 1,
        /// When the key moved, on the output's clock (`Output.clock_ms`): set by an input thread from the key's own
        /// time; `sendNote` stamps a note sent without one with the time it is sent. 0 is no time known.
        requested_at_ms: f64 = 0,
        /// When the press that asked for the note happened, on the same clock - the input event's own time
        /// (`z.getKeyPressTime`, `z.getLastPressTime`) - when the app passes it; 0 otherwise. The note's lag is then
        /// measured from the press, the frame's wait before the app asked included (`LatencySample`).
        pressed_at_ms: f64 = 0,
    };

    /// What a start of sound took, measured: when it was asked for, when the renderer applied it - the start of the
    /// block that began it - and when that block's first frame reaches the output. All three are on the output's clock,
    /// so `applied - requested` is the wait for the renderer and `out - applied` the sound queued ahead of it; past the
    /// output lie only the driver and the speaker. The renderer records one for each play and note it starts, when its
    /// output says when blocks are heard (`contract.AudioRenderTiming`).
    pub const LatencySample = struct {
        kind: enum { play, note },
        requested_at_ms: f64,
        applied_at_ms: f64,
        first_frame_out_ms: f64,
        /// When the press behind it happened (`NoteEvent.pressed_at_ms`, `PlayOptions.pressed_at_ms`); 0 unknown.
        pressed_at_ms: f64 = 0,
    };

    /// How a voice starts: its volume (1 plays the source as recorded), its pan (-1 left, 0 centre, 1 right; see
    /// `PanLaw`), its pitch (2 plays an octave up, and twice as fast; 0.5 an octave down, and half as fast; held to at
    /// least `lowest_pitch`).
    pub const PlayOptions = struct {
        volume: f32 = 1,
        pan: f32 = 0,
        pitch: f32 = 1,
        /// When the press that asked for the sound happened, on the output's clock - the input event's own time
        /// (`z.getLastPressTime`) - when the app passes it; 0 otherwise. Its lag is then measured from the press
        /// (`LatencySample`).
        pressed_at_ms: f64 = 0,
    };

    /// The lowest pitch a voice plays at: 1/64, six octaves down. A pitch of 0 would hold a voice on one sample
    /// forever.
    pub const lowest_pitch: f32 = 1.0 / 64.0;
    /// The highest pitch a voice plays at: 64, six octaves up, as far above as `lowest_pitch` is below. A position's
    /// step - pitch times the source's rate over the mixer's, in units of 2^-32 of a frame - must fit 64 bits.
    pub const highest_pitch: f32 = 64.0;

    comptime {
        // A voice's name keeps its slot in 8 bits; `Voice.none`'s slot bits, all ones, must name no slot.
        if (voice_capacity >= 0xff) {
            @compileError("the mixer's voice slots must number fewer than 255, " ++
                "so that a voice's name keeps its slot in 8 bits");
        }
    }

    /// How long a voice takes to fade to silence when stopped or paused: 5 ms. A voice cut off mid-waveform jumps
    /// to zero between two samples, and a jump is heard as a click; 5 ms is too short to hear as a fade.
    pub const fade_out_frames: u32 = 240;

    /// A fade out a voice has pending: the next mix ramps it to silence over `fade_out_frames`, then ends it
    /// (`stopVoice`) or pauses it (`pauseVoice`).
    const FadeOut = enum { none, then_stop, then_pause };

    /// The fixed-point position in a source (`readSampleSource` explains it): 32 bits of fraction, so one whole source
    /// frame is 2^32.
    const position_fraction_bits: u6 = 32;
    const position_one_frame: u64 = @as(u64, 1) << position_fraction_bits;
    /// The mask taking a position's fraction, and the factor turning that fraction into a float from 0 to 1.
    const position_fraction_mask: u64 = position_one_frame - 1;
    const position_fraction_to_float: f32 = 1.0 / float(position_one_frame);

    /// A pair of gains, one per channel.
    const StereoGains = struct {
        left: f32,
        right: f32,
    };

    /// One voice's slot: what it plays, where it is, and how loud and where in the stereo field.
    const VoiceSlot = struct {
        /// Moves on each time the slot's voice ends (`endVoice`), so that an old name no longer matches.
        generation: u24 = 0,
        is_playing: bool = false,
        /// Started and not yet mixed: nothing of it has been heard, so a stop or a pause before its first block ends
        /// it at once, with no fade (`stopVoice`, `pauseVoice`).
        is_new: bool = false,
        /// How many frames into its first block the voice starts: a note placed by its time
        /// (`Renderer.placementOfNote`); 0 for every other voice, and once it has been mixed.
        start_delay_frames: u32 = 0,
        /// Paused (`pauseVoice`): the voice keeps its slot and its place in its source, and is not mixed.
        is_paused: bool = false,
        /// A fade to silence under way, before the voice stops or pauses, and its frames still to mix: a fade lasts
        /// `fade_out_frames` whatever the blocks it falls across.
        fade_out: FadeOut = .none,
        fade_frames_left: u32 = 0,
        /// The id of the registered samples the voice plays (`SamplesId`); null for a generator, and once the voice
        /// plays its own copy of its last frames (`Renderer.fadeVoicesReading`).
        samples_id: ?SamplesId = null,
        /// The pan law the voice started with (`panLawOf` its source), kept when its source is replaced by its tail.
        pan_law: PanLaw = .constant_power,
        /// A generator voice's state, copied from its play command (`Generator.initial_state`) and handed to its
        /// `generate`.
        generator_state: [generator_state_capacity]u8 align(16) = undefined,
        source: Source = undefined,
        /// Where the voice is in a sample source, in the source's frames, 32.32 fixed point.
        source_position: u64 = 0,
        /// How many frames a generator source has made so far: the next block's `first_frame`.
        generated_frame_count: u64 = 0,
        /// A stream source's two frames the voice reads between (`readStreamSource`) - the one it is at, then the next,
        /// each left and right - and whether they hold the stream's first two yet.
        stream_window: [2][channel_count]f32 = @splat(@splat(0)),
        is_stream_window_primed: bool = false,
        volume: f32 = 1,
        pan: f32 = 0,
        pitch: f32 = 1,
        /// The gains the last mixed block ended with. The next block moves from them to the gains its volume and pan
        /// ask for, a step each frame, so that a change of either makes no click (`mixVoiceInto`).
        last_block_gains: StereoGains = .{ .left = 0, .right = 0 },
        /// For a note of the instrument: the key it sounds for, and whether that key is still held - a released
        /// note goes on sounding through its release, but a key going up again reaches only a held note.
        note_key: u8 = 0,
        is_note_held: bool = false,
    };

    /// The calling thread's floating point control as it was before `enterFlushToZero` changed it - x86-64's MXCSR
    /// register, AArch64's FPCR - for `restoreFloatingPointMode` to put back. Unused on targets without such a control.
    const FloatingPointMode = struct {
        control: u64,
    };

    /// MXCSR's two bits for subnormal numbers on x86-64: flush-to-zero (bit 15) makes a result too small to be a
    /// normal number zero, and denormals-are-zero (bit 6) reads such a number as zero when it is an operand.
    const mxcsr_flush_to_zero: u32 = 1 << 15;
    const mxcsr_denormals_are_zero: u32 = 1 << 6;
    /// FPCR's bit for subnormal numbers on AArch64: flush-to-zero (bit 24) does both, for results and operands.
    const fpcr_flush_to_zero: u64 = 1 << 24;

    /// Sets the calling thread's floating point unit to treat subnormal numbers as zero, and returns its mode as it
    /// was, for `restoreFloatingPointMode`. The renderer computes each block this way (`Renderer.render`).
    ///
    /// Why. A float has a smallest normal magnitude - about 1.2e-38 for an f32 - and below it, down to 1.4e-45, the
    /// subnormal numbers: the exponent stops shrinking and the mantissa loses digits instead. Many processors compute
    /// with them far more slowly than with normal numbers - on x86 a multiplication with a subnormal operand or result
    /// can take a hundred cycles instead of four. Sound makes them easily: a release multiplies a level by 0.9997
    /// each frame, a filter feeds its output back scaled down, and a decaying value passes through the subnormal
    /// range on its way to zero. A block in which every sample takes a hundred cycles more is a block that misses its
    /// deadline - heard as a gap - so real-time audio code runs with them flushed: a value that small is silence by
    /// a margin of 700 dB, and zero is the same silence, computed at full speed. JUCE sets the same bits for each
    /// block it renders (`ScopedNoDenormals`), as do most audio engines.
    ///
    /// Set for a block and put back after it, rather than once for the thread: the renderer runs on an audio thread
    /// of its own on Windows, but on the main thread for the headless output, whose app must keep the ordinary
    /// arithmetic. Reading and writing the register costs some tens of cycles a block.
    ///
    /// Each write is declared to change the register (the `.mxcsr` and `.fpcr` clobbers), so that the compiler keeps
    /// the block's float operations between the two writes rather than moving one across either.
    ///
    /// Where there is no such register. WebAssembly - the renderer in the browser's worklet - has none: its arithmetic
    /// is fixed by its specification, subnormal numbers included, so a block there is computed as it is, and the
    /// renderer keeps its own values out of the subnormal range instead (an instrument's note ends at -80 dB). Any
    /// other CPU is a compile error until its register is added here: a native port to a new CPU must decide, not
    /// inherit silence. (A GPU's equivalent is no register either: SPIR-V's float controls are execution modes fixed
    /// when a shader is compiled, and WebGPU exposes none - nothing here applies to shaders.)
    fn enterFlushToZero() FloatingPointMode {
        switch (builtin.cpu.arch) {
            .x86_64 => {
                // MXCSR moves only through memory: `stmxcsr` stores it at an address, `ldmxcsr` loads it from one.
                // The address is passed in rax and named in the template, a form both of Zig's x86-64 code generators
                // accept - its own, which builds debug programs, rejects a memory operand made from an operand's name.
                var saved_control: u32 = undefined;
                asm volatile ("stmxcsr (%%rax)"
                    :
                    : [control_address] "{rax}" (&saved_control),
                    : .{ .memory = true });
                const flushing_control: u32 = saved_control | mxcsr_flush_to_zero | mxcsr_denormals_are_zero;
                asm volatile ("ldmxcsr (%%rax)"
                    :
                    : [control_address] "{rax}" (&flushing_control),
                    : .{ .memory = true, .mxcsr = true });
                return .{ .control = saved_control };
            },
            .aarch64 => {
                const saved_control: u64 = asm volatile ("mrs %[control], fpcr"
                    : [control] "=r" (-> u64),
                );
                asm volatile ("msr fpcr, %[control]"
                    :
                    : [control] "r" (saved_control | fpcr_flush_to_zero),
                    : .{ .fpcr = true });
                return .{ .control = saved_control };
            },
            .wasm32, .wasm64 => return .{ .control = 0 },
            else => @compileError("enterFlushToZero: no floating point control for this CPU yet - add its register " ++
                "beside MXCSR and FPCR, or say here why it has none"),
        }
    }

    /// Puts the calling thread's floating point mode back as `enterFlushToZero` found it.
    fn restoreFloatingPointMode(saved_mode: FloatingPointMode) void {
        switch (builtin.cpu.arch) {
            .x86_64 => {
                const saved_control: u32 = @intCast(saved_mode.control);
                asm volatile ("ldmxcsr (%%rax)"
                    :
                    : [control_address] "{rax}" (&saved_control),
                    : .{ .memory = true, .mxcsr = true });
            },
            .aarch64 => {
                asm volatile ("msr fpcr, %[control]"
                    :
                    : [control] "r" (saved_mode.control),
                    : .{ .fpcr = true });
            },
            .wasm32, .wasm64 => {},
            else => @compileError("restoreFloatingPointMode: no floating point control for this CPU yet"),
        }
    }

    /// The most bytes a voice slot may take. A block reads every playing slot - its source, its position, its gains -
    /// and the slots lie one after another in the renderer, so the smaller a slot, the fewer cache lines a block
    /// touches: 64 slots of at most 256 bytes are 16 KB, which stays in a phone's first-level data cache. What a slot
    /// needs only rarely lives elsewhere: the copy of a released voice's last frames is the renderer's
    /// (`Renderer.tail_copies`), indexed by the slot.
    const voice_slot_most_bytes: usize = 256;

    comptime {
        if (@sizeOf(VoiceSlot) > voice_slot_most_bytes) {
            @compileError("a voice slot must stay within voice_slot_most_bytes: what a block reads of every slot " ++
                "must stay compact; move what is read rarely out of the slot, as the tail copies are");
        }
    }

    /// The copy of a voice's last frames that `Renderer.fadeVoicesReading` makes when the samples it reads are about
    /// to be freed: `fade_out_frames` frames of interleaved stereo, at the mixer's rate, its pitch applied.
    const TailCopy = [fade_out_frames * channel_count]f32;

    /// How a voice's pan places it between the two speakers, by what its source holds.
    ///
    /// Loudness. A gain multiplies a sound's amplitude - how far its samples swing - and the power it carries goes with
    /// the amplitude squared. Two speakers playing the same sound are heard about as loud as the sum of their powers:
    /// left gain squared plus right gain squared. Loudness is compared in decibels (dB), ten times the base-10
    /// logarithm of a ratio of powers: half the power is 3 dB less, a quarter 6 dB less. So a gain of 0.707 - whose
    /// square is one half - is 3 dB down, and a gain of 0.5 is 6 dB down.
    ///
    /// A mono source - one channel of samples, or a generator of one - is one sound, to be placed somewhere between
    /// the speakers by the constant-power law. The pan, from -1 (left) to 1 (right), turns an angle from 0, through an
    /// eighth of a turn at the centre (45 degrees), to a quarter turn at the right (90 degrees); the left gain is the
    /// angle's cosine and the right gain its sine. Cosine squared plus sine squared is always 1, so the sound keeps
    /// the same power, and the same loudness, wherever it is placed. A plain crossfade - the left gain falling in a
    /// straight line as the right one rises - would carry 0.5 to each speaker at the centre: half the power, 3 dB
    /// quieter in the middle than at either side.
    ///
    /// A stereo source already holds its own placement - its left channel for the left speaker, its right for the
    /// right - and at the centre both play as recorded. Its pan is a balance: the side it moves toward stays as
    /// recorded, and the other side fades out along a cosine. Placed by the constant-power law instead, a stereo
    /// recording would play 3 dB quieter than recorded at the centre.
    ///
    ///     pan      constant power       balance           plain crossfade
    ///              left    right        left    right     left    right    power
    ///     -1       1.000   0.000        1.000   0.000     1.000   0.000    1.000
    ///     -0.5     0.924   0.383        1.000   0.707     0.750   0.250    0.625   (-2 dB)
    ///      0       0.707   0.707        1.000   1.000     0.500   0.500    0.500   (-3 dB)
    ///      0.5     0.383   0.924        0.707   1.000     0.250   0.750    0.625   (-2 dB)
    ///      1       0.000   1.000        0.000   1.000     0.000   1.000    1.000
    ///
    /// Angles here are in turns, as `cosTurns` and `sinTurns` take them: a whole turn is 360 degrees.
    const PanLaw = enum { constant_power, balance };

    /// A voice's left and right gains: its volume, times the gains its pan gives by `pan_law` (`PanLaw`).
    fn gainsForPan(volume: f32, pan: f32, pan_law: PanLaw) StereoGains {
        const clamped_pan: f32 = clamp(pan, -1, 1);
        switch (pan_law) {
            .constant_power => {
                // From 0 at the left to 2 at the right, then to an angle from 0 to a quarter turn.
                const pan_from_left_edge: f32 = clamped_pan + 1;
                const pan_angle_turns: f32 = pan_from_left_edge / 8;
                const left_gain: f32 = cosTurns(pan_angle_turns);
                const right_gain: f32 = sinTurns(pan_angle_turns);
                return .{ .left = volume * left_gain, .right = volume * right_gain };
            },
            .balance => {
                // The side away from the pan fades along a cosine, from 1 at the centre to 0 at the edge: at pan
                // 0.5 an eighth of a turn, 0.707.
                const far_side_angle_turns: f32 = @abs(clamped_pan) / 4;
                const far_side_gain: f32 = cosTurns(far_side_angle_turns);
                const is_toward_right: bool = clamped_pan > 0;
                const left_gain: f32 = if (is_toward_right) far_side_gain else 1;
                const right_gain: f32 = if (is_toward_right) 1 else far_side_gain;
                return .{ .left = volume * left_gain, .right = volume * right_gain };
            },
        }
    }

    /// The pan law for a source (`PanLaw`): balance for a source of two channels or more - samples, or a generator
    /// saying so - and constant power otherwise.
    fn panLawOf(source: Source) PanLaw {
        return switch (source) {
            .samples => |sample_source| if (sample_source.channels >= 2) .balance else .constant_power,
            .generator => |generator| if (generator.channels >= 2) .balance else .constant_power,
            .stream => |stream| if (stream.ring.channels >= 2) .balance else .constant_power,
        };
    }

    // ---- The two sides of the mixer ----
    //
    // A thread is one line of execution: a program can run several at once, each on its own processor core, all
    // reading and writing the same memory. Sound gets a thread of its own, the audio thread, because the device asks
    // for each block of sound at a time of its own choosing - every few milliseconds - and a block not ready in time is
    // a gap heard. The main thread, which runs the app and draws its frames, may be busy for longer than that.
    //
    // So the mixer has two sides. The renderer owns the voices and renders them, block by block, where the sound is
    // played - on the audio thread when the device asks from there. The main side, `Mixer`, is what the app calls: it
    // names the voices, and asks the renderer for every change by a command. Commands travel one way through a queue;
    // notices - a voice ended, samples let go of - travel back through another. The two sides share nothing else, so
    // they need no lock: a lock would let one thread make the other wait, and the audio thread must never wait.
    //
    //     main side (Mixer), main thread                          renderer (Renderer), audio thread
    //       play(sound)    names the voice: slot 5, at once
    //                      command "start it in slot 5"  ----->     applied at the start of its next block
    //                                                               ... the voice plays, block after block ...
    //       each frame     reads: slot 5 is free again   <-----     notice "slot 5's voice ended"

    /// A queue of items between two threads - one only ever pushing items in, the other only ever popping them out -
    /// with no lock: neither thread ever waits for the other.
    ///
    /// The items lie in a ring of `capacity` places, used round and round. Two counters say where things stand:
    /// `pushed_count`, the items pushed since the start, and `popped_count`, the items popped. Each is written by one
    /// thread only - the pushing thread writes its count, the popping thread its own - so no two threads ever write the
    /// same variable. Their difference is the items waiting: none means empty, `capacity` means full. An item's place
    /// is its count modulo the capacity. With room for 4, after 6 pushes and 3 pops:
    ///
    ///     place          0       1       2       3
    ///     item           item 4  item 5  -       item 3       pushed_count 6, popped_count 3: 3 waiting
    ///                                    ^ next push (6 mod 4 = 2)          ^ next pop (3 mod 4 = 3)
    ///
    /// The capacity is a power of two, so "modulo the capacity" is a bit mask: 6 mod 4 is 6 & 3, which keeps the low
    /// two bits of 110 - 10, that is 2 - and needs no division.
    ///
    /// The order of writes. A processor, and the compiler before it, may make writes visible to other cores in another
    /// order than the program wrote them. So the counters are atomic, and their stores and loads say what must be seen
    /// in order: the pushing thread writes the item, then stores its counter with release ordering - every write before
    /// it is visible to a thread that loads the counter with acquire ordering and sees the new count. So the popping
    /// thread, loading the count before reading the item, always finds the item whole. The same holds the other way:
    /// the popping thread stores its count after reading the item out, and the pushing thread loads that count before
    /// it writes over the place, so it never overwrites an item not yet read.
    ///
    /// Cache lines. Cores pass memory between them in lines of 64 bytes (128 on some), and a core writing a line takes
    /// it from the others. Were both counters on one line, each push would take the line from the popping core and each
    /// pop would take it back. So each side's counter sits on a line of its own; and each side keeps the other's
    /// counter as it last loaded it, loading the real one only when that copy says the queue is full (for the pushing
    /// thread) or empty (for the popping thread) - most calls touch no line the other side writes. A copy can only be
    /// behind the real counter, which only makes the queue look fuller or emptier than it is: never wrong.
    ///
    /// Wrapping. The counters are `usize` - a 32-bit target has no 64-bit atomic operations - so after 4 294 967 295
    /// pushes a count wraps around to 0. Every subtraction and addition of counts wraps the same way (`-%`, `+%`), and
    /// the difference stays right: pushed 2 (after wrapping) less popped 4 294 967 294 (not yet) is 4, the true number
    /// waiting. And a power of two divides 2^32, so the mask still finds the right place.
    pub fn SingleProducerSingleConsumerQueue(comptime Item: type, comptime capacity: usize) type {
        comptime {
            const is_power_of_two: bool = capacity != 0 and (capacity & (capacity - 1)) == 0;
            if (!is_power_of_two) {
                @compileError("a queue's capacity is a power of two");
            }
        }
        return struct {
            /// What the queue carries.
            pub const Element = Item;
            /// The ring of places.
            items: [capacity]Item = undefined,
            /// The pushing thread's cache line, and the popping thread's.
            pushing_side: PushingSide align(cache_line) = .{},
            popping_side: PoppingSide align(cache_line) = .{},

            const Queue = @This();
            /// A count's place in the ring is its low bits: the capacity less one, as a mask.
            const item_index_mask: usize = capacity - 1;

            const PushingSide = struct {
                /// Items pushed since the start, wrapping: stored by the pushing thread, loaded by the popping one.
                pushed_count: std.atomic.Value(usize) = .{ .raw = 0 },
                /// `popped_count` as the pushing thread last loaded it, never ahead of the real one.
                popped_count_last_seen: usize = 0,
            };

            const PoppingSide = struct {
                /// Items popped since the start, wrapping: stored by the popping thread, loaded by the pushing one.
                popped_count: std.atomic.Value(usize) = .{ .raw = 0 },
                /// `pushed_count` as the popping thread last loaded it, never ahead of the real one.
                pushed_count_last_seen: usize = 0,
            };

            /// Appends `item`; false, and nothing appended, when the queue is full. Pushing thread only.
            pub fn push(queue: *Queue, item: Item) bool {
                const pushed_count: usize = queue.pushing_side.pushed_count.load(.monotonic);
                const waiting_by_last_seen_count: usize = pushed_count -% queue.pushing_side.popped_count_last_seen;
                if (waiting_by_last_seen_count == capacity) {
                    // Full by the popping thread's count as last seen - it may have popped since: load its count.
                    queue.pushing_side.popped_count_last_seen = queue.popping_side.popped_count.load(.acquire);
                    const waiting_now: usize = pushed_count -% queue.pushing_side.popped_count_last_seen;
                    if (waiting_now == capacity) {
                        return false;
                    }
                }
                const item_index: usize = pushed_count & item_index_mask;
                queue.items[item_index] = item;
                // Stored after the item is written: a popping thread that sees the new count sees the item whole.
                const new_pushed_count: usize = pushed_count +% 1;
                queue.pushing_side.pushed_count.store(new_pushed_count, .release);
                return true;
            }

            /// Takes the oldest item; null when the queue is empty. Popping thread only.
            pub fn pop(queue: *Queue) ?Item {
                const popped_count: usize = queue.popping_side.popped_count.load(.monotonic);
                const is_empty_by_last_seen_count: bool = popped_count == queue.popping_side.pushed_count_last_seen;
                if (is_empty_by_last_seen_count) {
                    // Empty by the pushing thread's count as last seen - it may have pushed since: load its count.
                    queue.popping_side.pushed_count_last_seen = queue.pushing_side.pushed_count.load(.acquire);
                    const is_empty_now: bool = popped_count == queue.popping_side.pushed_count_last_seen;
                    if (is_empty_now) {
                        return null;
                    }
                }
                const item_index: usize = popped_count & item_index_mask;
                const item: Item = queue.items[item_index];
                // Stored after the item is read out: a pushing thread that sees the new count may write over its place.
                const new_popped_count: usize = popped_count +% 1;
                queue.popping_side.popped_count.store(new_popped_count, .release);
                return item;
            }
        };
    }

    /// A ring of a stream's frames between two threads: the main side writes them in as the game makes them - a
    /// synthesizer's output, a decoder's - and the renderer reads them out as it mixes the stream's voice. It is the
    /// mixer's queue (`SingleProducerSingleConsumerQueue`) made for frames: the same two counters, each on its own
    /// cache line, stored with release ordering after the samples are written or read and loaded with acquire ordering
    /// before, each side keeping the other's as last seen; but it moves frames in runs - a run written or read is one
    /// count stored, however long - and its room is set when it is made, from samples the main side owns.
    ///
    ///     capacity 8 frames:   [ . . r r r r . . ]      r: frames written, not yet read
    ///                                ^read    ^written  a run of 3 written lands from `written`, wrapping past the end
    ///
    /// The counts are of frames since the start, wrapping as the queue's do; a count's place in the ring is its low
    /// bits, the capacity being a power of two. A read finding fewer frames than it wanted counts the missing ones as
    /// dry (`takeDryFrames`): the renderer plays silence in their place, and the main side can see that it fell behind.
    pub const StreamRing = struct {
        /// The ring's samples: `capacity_frames` frames of `channels` samples each, interleaved.
        samples: []f32,
        channels: u8,
        /// The rate the stream's frames were made at; the voice reads them at that rate, whatever the mixer's.
        sample_rate: u32,
        capacity_frames: usize,
        writing_side: WritingSide align(cache_line) = .{},
        reading_side: ReadingSide align(cache_line) = .{},

        const WritingSide = struct {
            /// Frames written since the start, wrapping: stored by the writing thread, loaded by the reading one.
            written_frames: std.atomic.Value(usize) = .{ .raw = 0 },
            /// `read_frames` as the writing thread last loaded it, never ahead of the real one.
            read_frames_last_seen: usize = 0,
        };

        const ReadingSide = struct {
            /// Frames read since the start, wrapping: stored by the reading thread, loaded by the writing one.
            read_frames: std.atomic.Value(usize) = .{ .raw = 0 },
            /// `written_frames` as the reading thread last loaded it, never ahead of the real one.
            written_frames_last_seen: usize = 0,
            /// Frames a read wanted and did not find, since the main side last took the count.
            dry_frames: std.atomic.Value(usize) = .{ .raw = 0 },
        };

        /// A ring over `samples`, which the caller owns and keeps until no voice reads it: its length a power of two
        /// frames of `channels` samples, made at `frames_per_second`.
        pub fn initOver(samples: []f32, channels: u8, frames_per_second: u32) StreamRing {
            assert(channels != 0, @src());
            const capacity_frames: usize = samples.len / channels;
            const is_power_of_two: bool = capacity_frames != 0 and (capacity_frames & (capacity_frames - 1)) == 0;
            assert(is_power_of_two and samples.len == capacity_frames * channels, @src());
            return .{
                .samples = samples,
                .channels = channels,
                .sample_rate = frames_per_second,
                .capacity_frames = capacity_frames,
            };
        }

        /// The frames there is room for now. Writing thread only.
        pub fn freeFrames(ring: *StreamRing) usize {
            const written_frames: usize = ring.writing_side.written_frames.load(.monotonic);
            ring.writing_side.read_frames_last_seen = ring.reading_side.read_frames.load(.acquire);
            const waiting_frames: usize = written_frames -% ring.writing_side.read_frames_last_seen;
            return ring.capacity_frames - waiting_frames;
        }

        /// Writes as many of `frames` - interleaved, `channels` samples a frame - as there is room for, and returns
        /// how many frames it wrote. Writing thread only.
        pub fn write(ring: *StreamRing, frames: []const f32) usize {
            const offered_frames: usize = frames.len / ring.channels;
            const written_frames: usize = ring.writing_side.written_frames.load(.monotonic);
            var waiting_frames: usize = written_frames -% ring.writing_side.read_frames_last_seen;
            if (waiting_frames + offered_frames > ring.capacity_frames) {
                // Full by the reading thread's count as last seen - it may have read since: load its count.
                ring.writing_side.read_frames_last_seen = ring.reading_side.read_frames.load(.acquire);
                waiting_frames = written_frames -% ring.writing_side.read_frames_last_seen;
            }
            const frames_to_write: usize = @min(offered_frames, ring.capacity_frames - waiting_frames);
            const run: []const f32 = frames[0 .. frames_to_write * ring.channels];
            const pieces: RunPieces = ring.piecesOfRun(written_frames, run.len);
            @memcpy(pieces.before_end, run[0..pieces.before_end.len]);
            @memcpy(pieces.from_start, run[pieces.before_end.len..]);
            // Stored after the samples are written: a reading thread that sees the new count sees them whole.
            ring.writing_side.written_frames.store(written_frames +% frames_to_write, .release);
            return frames_to_write;
        }

        /// Reads up to `into.len / channels` frames into `into`, oldest first, and returns how many frames it read; the
        /// frames it wanted and did not find are counted as dry. Reading thread only.
        pub fn read(ring: *StreamRing, into: []f32) usize {
            const wanted_frames: usize = into.len / ring.channels;
            const read_frames: usize = ring.reading_side.read_frames.load(.monotonic);
            var waiting_frames: usize = ring.reading_side.written_frames_last_seen -% read_frames;
            if (waiting_frames < wanted_frames) {
                // Short by the writing thread's count as last seen - it may have written since: load its count.
                ring.reading_side.written_frames_last_seen = ring.writing_side.written_frames.load(.acquire);
                waiting_frames = ring.reading_side.written_frames_last_seen -% read_frames;
            }
            const frames_to_read: usize = @min(wanted_frames, waiting_frames);
            const run: []f32 = into[0 .. frames_to_read * ring.channels];
            const pieces: RunPieces = ring.piecesOfRun(read_frames, run.len);
            @memcpy(run[0..pieces.before_end.len], pieces.before_end);
            @memcpy(run[pieces.before_end.len..], pieces.from_start);
            // Stored after the samples are read out: a writing thread that sees the new count may write over them.
            ring.reading_side.read_frames.store(read_frames +% frames_to_read, .release);
            const missing_frames: usize = wanted_frames - frames_to_read;
            if (missing_frames != 0) {
                _ = ring.reading_side.dry_frames.fetchAdd(missing_frames, .monotonic);
            }
            return frames_to_read;
        }

        /// The frames reads have found missing since the last call, and the count starts again. Any thread.
        pub fn takeDryFrames(ring: *StreamRing) usize {
            return ring.reading_side.dry_frames.swap(0, .monotonic);
        }

        /// Where a run of samples lies in the ring: from its place to the ring's end, then - when it wraps - on from
        /// the ring's start. Either piece may be empty.
        const RunPieces = struct {
            before_end: []f32,
            from_start: []f32,
        };

        /// The ring's pieces for a run of `sample_count` samples - whole frames - from frame count `first_frame_count`.
        fn piecesOfRun(
            ring: *StreamRing,
            first_frame_count: usize,
            sample_count: usize,
        ) RunPieces {
            const first_sample_index: usize = (first_frame_count & (ring.capacity_frames - 1)) * ring.channels;
            const samples_before_end: usize = @min(sample_count, ring.samples.len - first_sample_index);
            return .{
                .before_end = ring.samples[first_sample_index..][0..samples_before_end],
                .from_start = ring.samples[0 .. sample_count - samples_before_end],
            };
        }
    };

    /// A voice's name and whether its sample source is to loop (`Mixer.setLooping`).
    const VoiceLoopingChange = struct {
        voice: Voice,
        is_looping: bool,
    };

    /// A voice's name and a number: what a setter asks for.
    const VoiceParameterChange = struct {
        voice: Voice,
        value: f32,
    };

    /// A sample buffer's name in the registry both sides keep (`Mixer.samples_registry`,
    /// `Renderer.registered_samples`): its index there. A play command names its samples by it rather than by an
    /// address, so that the command means the same in the renderer's memory wherever that memory is - in the browser's
    /// audio worklet, a memory of its own, into which the buffer was copied when it was registered (`RendererHost`).
    pub const SamplesId = u16;

    /// The most sample buffers registered at once: every sound loaded and played, and every buffer an app plays itself.
    pub const samples_registry_capacity: usize = 512;

    /// Registered samples as a play command carries them: by their id, with their format.
    const RegisteredSamplesSource = struct {
        samples_id: SamplesId,
        /// 1 for mono, 2 for stereo; a buffer of more channels gives its first two (`readSampleSource`).
        channels: u8,
        /// The frames a second the buffer was recorded at; the renderer reads it at the mixer's rate.
        sample_rate: u32,
        is_looping: bool,
    };

    /// A generator as a play command carries it: its function and its channels; its state travels beside it
    /// (`VoiceToStart.generator_state`). The function's address means the same function on both sides: natively the
    /// two sides are one program; in the browser, a function's address in wasm is its index in the module's table of
    /// functions, the same in every instance of the module - the worklet's included.
    const GeneratorToStart = struct {
        generate: *const fn (state: *anyopaque, frames: []f32, first_frame: u64) void,
        channels: u8,
    };

    /// A source as a play command carries it: samples by their id, a generator by its function - nothing that points
    /// into the main side's memory.
    const SourceToStart = union(enum) {
        samples: RegisteredSamplesSource,
        generator: GeneratorToStart,
        /// A stream's ring, by its address in the game's memory - the renderer reading it there.
        stream: *StreamRing,
        /// A stream by its number, as a voice's start crosses to a renderer in another memory: the host there puts its
        /// own ring's address in its place before the renderer sees the command (`RendererHost.acceptCommandBytes`).
        forwarded_stream: ForwardedStream,
    };

    /// The streams a renderer in another memory can play at once, each by its number: as many as an app's stream table
    /// holds.
    pub const forwarded_stream_capacity: usize = 32;

    /// A stream's number across memories: the main side's name for a stream it forwards, by which the renderer's host
    /// in the other memory finds its own ring for it (`RendererHost.acceptStreamFrames`).
    pub const ForwardedStreamId = u8;

    /// A stream as a renderer in another memory knows it: its number, its generation, and what its frames are - their
    /// channels and rate. Its frames come in messages of their own; its ring is the host's. A number is given to
    /// another stream once its voice has ended; the generation, counted for each number, tells the two apart in the
    /// host's reports, one from the stream before still on its way back when the next has begun.
    pub const ForwardedStream = struct {
        id: ForwardedStreamId,
        generation: u8 = 0,
        channels: u8,
        sample_rate: u32,
    };

    /// A stream the main side forwards (`Mixer.forwarded_streams`): the ring the game writes - null where the number is
    /// free - the voice that plays it on the other side, and two counts of the ring's frames since it began: those sent
    /// across (`Mixer.forwardStreamFrames`), and those the other side's voice has read, as last reported
    /// (`StreamRead`). The frames between the two are in flight or waiting there; the game's ring keeps all those not
    /// yet read, so its room means what it means natively: frames the game may write without passing what still has to
    /// play.
    /// The counts are the ring's own, from its first frame: the stream begins at the ring's read position when it
    /// starts (`first_frame`) - a ring played before goes on from where it was read, as it does natively - and the
    /// host's counts, from its own ring's start, are taken as counts past it.
    const ForwardedStreamRecord = struct {
        ring: ?*StreamRing = null,
        voice: Voice = .none,
        generation: u8 = 0,
        first_frame: usize = 0,
        forwarded_frames: usize = 0,
        read_frames: usize = 0,
    };

    /// What a host in another memory reports of a forwarded stream's ring (`RendererHost.takeNotices`): the frames
    /// its voice has read since the ring opened, wrapping, and those it wanted and did not find since the last report.
    /// The main side keeps the frames in its own ring until they are read here, so this is what frees its room.
    pub const StreamRead = struct {
        id: ForwardedStreamId,
        /// The generation of the stream whose ring it is (`ForwardedStream.generation`).
        generation: u8,
        dry_frames: u16,
        read_frames: u32,
    };

    /// A voice to start: the slot and generation its name was given by the main side, its source, its options, and -
    /// for a generator - its state, copied in when the command is sent, so that the caller's may go at once.
    const VoiceToStart = struct {
        voice: Voice,
        source: SourceToStart,
        /// Its volume, pan and pitch to start at.
        options: PlayOptions,
        generator_state: [generator_state_capacity]u8 align(16) = undefined,
        /// When `Mixer.play` was called, on the output's clock; 0 when no output was started.
        requested_at_ms: f64 = 0,
    };

    /// Samples entering the registry under an id. It is the one command that holds an address - where the samples lie
    /// in the main side's memory: natively the renderer reads them there; for the browser's worklet the samples
    /// themselves are sent, and copied into its memory (`forwardCommands`).
    const SamplesToRegister = struct {
        samples_id: SamplesId,
        samples: []const f32,
    };

    /// What the main side asks of the renderer: applied at the start of the renderer's next block, in the order asked
    /// (`Renderer.applyCommand`). A command naming a voice that has ended since reaches nothing.
    const RendererCommand = union(enum) {
        /// Start a voice, in the slot its name was given.
        play: VoiceToStart,
        /// Fade the voice out over `fade_out_frames`, then end it.
        stop: Voice,
        /// Fade the voice out, then hold it where it fell silent.
        pause: Voice,
        /// Play a paused voice on from where it fell silent.
        resume_voice: Voice,
        /// The voice's volume, pan or pitch from the next block on.
        set_volume: VoiceParameterChange,
        set_pan: VoiceParameterChange,
        set_pitch: VoiceParameterChange,
        /// Whether the voice's sample buffer loops.
        set_looping: VoiceLoopingChange,
        /// The volume of all the sound at once.
        set_master_volume: f32,
        /// The instrument the notes play from now on; the notes of the one before end at once.
        set_instrument: Instrument,
        /// Take these samples into the registry, under their id.
        register_samples: SamplesToRegister,
        /// Let go of the samples registered under this id: every voice reading them copies what it still needs and
        /// fades out over the copy (`Renderer.fadeVoicesReading`), the id leaves the registry, and the renderer says
        /// so (`RendererNotice.samples_released`).
        release_samples: SamplesId,
        /// A forwarded stream given up, its voice ended: the host in the other memory frees its ring
        /// (`RendererHost.acceptCommandBytes`). The renderer itself does nothing with it.
        release_stream: ForwardedStreamId,
    };

    /// What the renderer tells the main side (`Mixer.readRendererNotices`).
    const RendererNotice = union(enum) {
        /// The voice in this slot ended - its source ran out, or its fade was done - and the slot is free again. A
        /// slot's index fits in 8 bits: there are fewer than 255 slots (checked with `voice_capacity`).
        voice_ended: u8,
        /// Nothing reads the samples registered under this id any more, and the id is free: the main side may free
        /// them.
        samples_released: SamplesId,
        /// A forwarded stream's frames read, from a host in another memory (`StreamRead`). Made when the notices are
        /// taken, from each ring as it stands - never queued, so the queue's room below is not counted for it.
        stream_read: StreamRead,
        /// A start of sound measured by a renderer in another memory (`LatencySample`): its host drains the
        /// renderer's measurements into the notices it sends (`RendererHost.takeNotices`), so that the main side's
        /// readout shows them as a renderer of its own memory's (`Mixer.recentStarts`). Never queued, as
        /// `stream_read`.
        start_measured: LatencySample,
    };

    /// The command queue: room for the commands of many frames - more than an app sends in one - and the renderer
    /// takes them all at each block.
    const RendererCommandQueue = SingleProducerSingleConsumerQueue(RendererCommand, 1024);

    /// The places in the notice queue. It never fills: a slot ends once, and is not used again before the main side
    /// reads its notice; an id is released once, and is not used again before its notice is read either. So at most
    /// one notice per slot and one per id wait at once - 64 + 512 = 576 of the 1 024 places.
    const notice_queue_capacity: usize = 1024;
    const RendererNoticeQueue = SingleProducerSingleConsumerQueue(RendererNotice, notice_queue_capacity);

    /// The note queue: the keys' events, from wherever they arrive to the renderer, which takes them all at each
    /// block. It is a queue of its own, not the commands', because each queue has exactly one producer: the
    /// commands' is the main side, and the notes' may be a thread that does nothing but read the keyboard. 256
    /// events is more than any player makes between two blocks.
    pub const NoteQueue = SingleProducerSingleConsumerQueue(NoteEvent, 256);

    /// The queue of measurements, renderer to main side. Unlike the notices it may fill - a burst of starts - and a
    /// measurement that finds it full is dropped: it costs nothing to lose one.
    pub const LatencyQueue = SingleProducerSingleConsumerQueue(LatencySample, 64);

    comptime {
        const most_notices_waiting: usize = voice_capacity + samples_registry_capacity;
        if (most_notices_waiting > notice_queue_capacity) {
            @compileError("the notice queue must hold a notice for every voice slot and every samples id at once");
        }
    }

    /// The queues between the sides. Each has exactly one producer and one consumer, which is what lets it work
    /// without a lock (`SingleProducerSingleConsumerQueue`): commands from the main side, notices from the renderer,
    /// and two queues of notes - one from the main side (`Mixer.sendNote`), for keys an app reads at its frame, and
    /// one from an input thread (`Mixer.sendNoteFromInputThread`), for keys read the moment they move. Two threads
    /// writing one queue would race for its places; each producer has its own queue, and the renderer takes from
    /// both.
    pub const RendererQueues = struct {
        commands: RendererCommandQueue = .{},
        notices: RendererNoticeQueue = .{},
        notes: NoteQueue = .{},
        input_thread_notes: NoteQueue = .{},
        latency: LatencyQueue = .{},
    };

    /// The rendering side: the voices, mixed block by block (`render`).
    ///
    /// The words, for a reader new to sound. A sound is a sequence of samples: numbers from -1 to 1, the positions of a
    /// loudspeaker's cone at evenly spaced instants - 48 000 of them each second (`sample_rate`). Stereo sound has two
    /// channels, left and right, and a frame is one sample of each; the mixer's samples are interleaved - a left
    /// sample, then a right one, frame after frame. A block is a run of frames rendered at once: the 128 frames a
    /// browser asks for, or a device's period of a few milliseconds. A voice is one sound playing - a buffer of samples
    /// being read, or a generator making its frames - with its volume (how loud: 1 as recorded, 0 silent), its pan
    /// (where between the speakers: -1 left, 0 centre, 1 right) and its pitch (how fast it is read: 2 is twice as fast,
    /// an octave up). Volume and pan together make a voice's gains: one multiplier for each channel (`gainsForPan`).
    /// Mixing is adding: each voice's frames, multiplied by its gains, are added into the block, and the sum is what
    /// the speaker plays.
    ///
    /// The renderer applies the main side's commands at the start of each block, and tells the main side of each voice
    /// that ends. It runs where its output calls it: on the main thread for an output the mixer pushes blocks to
    /// (`Mixer.mixFrame`) and for the headless output, which pulls at each frame; on a device's audio thread for an
    /// output that pulls from there; and in the browser, in the audio worklet's own instance (`RendererHost`). It
    /// reaches the main side only through the two queues, so it works the same in all of them.
    /// How many of the last frames mixed the renderer keeps for analysis (`Renderer.analysis_ring`): 2048, Web Audio's
    /// default analysis size, and the largest an analyser reads (`analyser.attach`).
    pub const analysis_ring_frames: usize = 2048;

    /// How many analysers a mixer holds at once (`Mixer.analysers`).
    pub const analyser_capacity: usize = 4;

    /// An analyser attached to a mixer (`analyser`): its size, and its magnitudes smoothed from one read to the next.
    pub const AnalyserSlot = struct {
        is_in_use: bool = false,
        /// The frames it analyses, a power of two from 32 to `analysis_ring_frames`; half as many bins.
        fft_size: u32 = 0,
        /// Each bin's magnitude, smoothed over the reads so far (`analyser.analyseFrames`).
        smoothed_magnitudes: [analysis_ring_frames / 2]f32 = @splat(0),
    };

    pub const Renderer = struct {
        /// The voices, each in a slot of its own; a slot is free once its voice has ended.
        voice_slots: [voice_capacity]VoiceSlot = @splat(.{}),
        /// For each slot, room for its voice's last frames, copied when the samples the voice reads are released under
        /// it (`fadeVoicesReading`): the voice then fades out over its copy. Kept here rather than in the slot, which a
        /// block reads for every voice playing, because a copy is made only on a release - 1 920 bytes a slot that
        /// would otherwise sit between every two slots' hot fields. A slot finds its copy by its own index.
        tail_copies: [voice_capacity]TailCopy = undefined,
        /// Every mixed sample is multiplied by it, after the voices are summed: the volume of all the sound at once.
        master_volume: f32 = 1,
        /// The samples registered under each id (`SamplesId`), in the renderer's own memory; empty for an id not in
        /// use.
        registered_samples: [samples_registry_capacity][]const f32 = @splat(&.{}),
        /// One voice's frames, read from its source before its gains are applied, with room for the largest block.
        voice_scratch_samples: []f32 = &.{},
        /// What the notes play (`set_instrument`); null until the main side sets one, and notes until then are dropped.
        instrument: ?Instrument = null,
        /// The fade of a note that gave up its slot to a new one (`keepFadeOfStolenNote`): its next `fade_out_frames`
        /// frames, ramped down to silence, waiting to be added into the blocks that follow - the first
        /// `stolen_tail_frames_left` of them, from the start. Past those, every sample is zero, so a second note
        /// stolen before the first fade is done adds its fade on top.
        stolen_note_tail: [fade_out_frames * channel_count]f32 = @splat(0),
        stolen_tail_frames_left: u32 = 0,
        /// When the block being rendered was asked for and when it will be heard, as its output said; null for an
        /// output that does not say, and between blocks. Each start in the block is measured against it
        /// (`recordStart`).
        current_block_timing: ?contract.AudioRenderTiming = null,
        /// When the block before this one was asked for, on the output's clock - what a note placed by its time is
        /// measured from (`Instrument.places_notes_by_time`); 0 before a timed block.
        previous_block_asked_at_ms: f64 = 0,
        /// The frames of the block being made (`render`), for a note placed within it.
        current_block_frame_count: usize = 0,
        /// The click watch (`watchForClicks`): each channel's last two samples, the older first, carried from block to
        /// block so that a jump between two blocks is seen as one within a block is; and the clicks counted since the
        /// diagnostics last took them, with the largest jump seen.
        click_watch_history: [channel_count][2]f32 = @splat(@splat(0)),
        clicks_since_taken: u32 = 0,
        largest_jump_since_taken: f32 = 0,
        /// Each channel's recent curvature: the mean square of its second differences, averaged over some 5 ms
        /// (`watchForClicks`) - what a smooth sound's own curvature is, against which a click must stand out.
        click_watch_mean_square: [channel_count]f32 = @splat(0),
        /// The frames the mix would have clipped since the diagnostics last took the count: past full scale before the
        /// limiter (`limitAndBend`).
        clipped_samples_since_taken: u32 = 0,
        /// The last `analysis_ring_frames` frames mixed, each the mean of its channels - what an analyser reads
        /// (`analyser`): written after each block (`recordForAnalysis`), the next frame's place at
        /// `analysis_write_position`, a count of every frame written that wraps; read whole by the main side -
        /// natively straight from here (`copyAnalysisFrames`), on a page from the worklet. Each sample is stored by
        /// its bits with an atomic store, the position with release, so that a reader on another thread reads whole
        /// samples and, behind the position, the frames written before it: a frame or two of a block being written may
        /// already be the new block's, which only an analysis sees.
        analysis_ring: [analysis_ring_frames]u32 = @splat(0),
        analysis_write_position: u32 = 0,
        /// The limiter's peak envelope and its gain, carried from block to block (`limitAndBend`).
        limiter_envelope: f32 = 0,
        limiter_gain: f32 = 1,

        /// Renders one block: applies the commands waiting - so that a sound asked for since the last block starts in
        /// this one - then mixes every playing voice into `mix_block`. The block is computed with subnormal numbers
        /// flushed to zero, and the thread's floating point mode is put back as it was when the block is done
        /// (`enterFlushToZero` explains why).
        pub fn render(
            renderer: *Renderer,
            renderer_queues: *RendererQueues,
            mix_block: []f32,
        ) void {
            const saved_floating_point_mode: FloatingPointMode = enterFlushToZero();
            defer restoreFloatingPointMode(saved_floating_point_mode);
            renderer.current_block_frame_count = mix_block.len / channel_count;
            renderer.applyCommands(renderer_queues);
            renderer.applyNotes(renderer_queues);
            renderer.mixInto(renderer_queues, mix_block);
            renderer.endSilentNotes();
            renderer.watchForClicks(mix_block);
            renderer.recordForAnalysis(mix_block);
            if (renderer.current_block_timing) |timing| {
                renderer.previous_block_asked_at_ms = timing.asked_at_ms;
            }
        }

        /// Writes the block into the analysis ring (`analysis_ring`), each frame the mean of its channels - the
        /// mono an analyser reads, as Web Audio mixes stereo down for its own: half of each side.
        fn recordForAnalysis(renderer: *Renderer, mix_block: []const f32) void {
            const frame_count: usize = mix_block.len / channel_count;
            var position: u32 = @atomicLoad(u32, &renderer.analysis_write_position, .monotonic);
            for (0..frame_count) |frame_index| {
                var channel_sum: f32 = 0;
                for (mix_block[frame_index * channel_count ..][0..channel_count]) |sample| {
                    channel_sum += sample;
                }
                const mono: f32 = channel_sum / float(channel_count);
                const place: *u32 = &renderer.analysis_ring[position % analysis_ring_frames];
                @atomicStore(u32, place, @bitCast(mono), .monotonic);
                position +%= 1;
            }
            @atomicStore(u32, &renderer.analysis_write_position, position, .release);
        }

        /// Copies the last `out.len` frames mixed - at most `analysis_ring_frames` - into `out`, the oldest first:
        /// for an analyser on the main side, while the renderer may be writing on its own thread.
        pub fn copyAnalysisFrames(renderer: *const Renderer, out: []f32) void {
            const is_within_ring: bool = out.len <= analysis_ring_frames;
            assertf(is_within_ring, @src(), "sound: an analysis of {d} frames, past the ring's", .{out.len});
            const end: u32 = @atomicLoad(u32, &renderer.analysis_write_position, .acquire);
            const start: u32 = end -% @as(u32, @intCast(out.len));
            for (out, 0..) |*sample, index| {
                const position: u32 = start +% @as(u32, @intCast(index));
                const place: *const u32 = &renderer.analysis_ring[position % analysis_ring_frames];
                sample.* = @bitCast(@atomicLoad(u32, place, .monotonic));
            }
        }

        /// The jump in the sound's slope above which a sample counts as a click, at the least (`watchForClicks`).
        pub const click_jump_threshold: f32 = 0.02;
        /// How far a click must stand out against the sound's recent curvature: its jump past this many times the
        /// root mean square of the recent second differences. A smooth sum of many partials peaks at three or four
        /// times its own root mean square, so eight leaves a margin; a step, whatever the sound, stands out further.
        pub const click_standout: f32 = 8;
        /// The weight a new sample's curvature gets in the running mean square: 1/240, some 5 ms at 48 000 Hz.
        const click_watch_mean_weight: f32 = 1.0 / 240.0;

        /// Watches the mixed sound for clicks: a click is a sudden jump in the sound's slope, and the measure of one at
        /// a sample is the second difference `x[n] - 2 x[n-1] + x[n-2]` - how much the change from one sample to the
        /// next itself changed. A sine of amplitude `a` and frequency `f` has a second difference of at most `a (2 pi f
        /// / rate)^2`: smooth sound keeps it small, the more so the lower it is - a Shepard note at velocity 0.5, its
        /// partials summed at their worst, about 0.0025. A step of height `h` between two samples - a sound started or
        /// cut off at once, or a block that does not carry on from the last - makes it `h` at that sample, whatever the
        /// sound around it. A dense, loud sound - sixteen notes at once - is smooth and still curves more than the
        /// fixed threshold allows, so a sample counts as a click only when its jump passes both `click_jump_threshold`,
        /// 0.02, and `click_standout` times the root mean square of the channel's recent second differences - a running
        /// mean of their squares over some 5 ms: a step stands out against its sound's own curvature, a dense chord's
        /// peaks do not. The count goes to the diagnostics (`takeClicks`), beside the samples the mix clipped: if both
        /// stay 0 while static is heard, the renderer's sound is clean, and the static comes after it - in the device,
        /// or the speaker.
        fn watchForClicks(renderer: *Renderer, mix_block: []const f32) void {
            const frame_count: usize = mix_block.len / channel_count;
            for (0..channel_count) |channel| {
                const history: *[2]f32 = &renderer.click_watch_history[channel];
                const mean_square: *f32 = &renderer.click_watch_mean_square[channel];
                var sample_before_last: f32 = history[0];
                var last_sample: f32 = history[1];
                var recent_mean_square: f32 = mean_square.*;
                for (0..frame_count) |frame_index| {
                    const sample: f32 = mix_block[frame_index * channel_count + channel];
                    const second_difference: f32 = sample - 2 * last_sample + sample_before_last;
                    const jump: f32 = @abs(second_difference);
                    // Against the curvature before this sample: a click does not raise its own bar. Compared squared -
                    // `jump^2 > standout^2 x mean square` - which asks the same without a square root at each sample.
                    const squared: f32 = second_difference * second_difference;
                    const standout_squared: f32 = click_standout * click_standout * recent_mean_square;
                    if (jump > click_jump_threshold and squared > standout_squared) {
                        renderer.clicks_since_taken += 1;
                    }
                    renderer.largest_jump_since_taken = @max(renderer.largest_jump_since_taken, jump);
                    recent_mean_square += (squared - recent_mean_square) * click_watch_mean_weight;
                    sample_before_last = last_sample;
                    last_sample = sample;
                }
                history.* = .{ sample_before_last, last_sample };
                mean_square.* = recent_mean_square;
            }
        }

        /// What the click watch counted since it was last asked: the clicks, and the largest jump among all the samples
        /// - a click or not, so that a renderer near the threshold shows it.
        pub const ClickReport = struct {
            click_count: u32,
            largest_jump: f32,
            /// The samples the mix clipped: held at full scale, their wave's top cut flat.
            clipped_sample_count: u32,
        };

        /// The clicks counted since the last call, and the counting starts again.
        pub fn takeClicks(renderer: *Renderer) ClickReport {
            const report: ClickReport = .{
                .click_count = renderer.clicks_since_taken,
                .largest_jump = renderer.largest_jump_since_taken,
                .clipped_sample_count = renderer.clipped_samples_since_taken,
            };
            renderer.clicks_since_taken = 0;
            renderer.largest_jump_since_taken = 0;
            renderer.clipped_samples_since_taken = 0;
            return report;
        }

        /// Applies every command waiting, in the order the main side sent them.
        pub fn applyCommands(renderer: *Renderer, renderer_queues: *RendererQueues) void {
            while (renderer_queues.commands.pop()) |renderer_command| {
                renderer.applyCommand(renderer_queues, renderer_command);
            }
        }

        /// Applies one command. A change of volume or pan is heard smoothly: the voice's next block moves its gains,
        /// frame by frame, from where they were to where they are now asked to be (`mixVoiceInto`), so that no sudden
        /// jump is heard as a click. A change of pitch takes effect from the next block's first frame. A command naming
        /// a voice that has ended since it was sent reaches nothing (`playingSlotNamedBy`).
        fn applyCommand(
            renderer: *Renderer,
            renderer_queues: *RendererQueues,
            renderer_command: RendererCommand,
        ) void {
            switch (renderer_command) {
                .play => |voice_to_start| renderer.startVoice(renderer_queues, voice_to_start),
                .stop => |voice| renderer.stopVoice(renderer_queues, voice),
                .pause => |voice| renderer.pauseVoice(voice),
                .resume_voice => |voice| renderer.resumeVoice(voice),
                .set_volume => |parameter_change| {
                    const voice_slot: *VoiceSlot = renderer.playingSlotNamedBy(parameter_change.voice) orelse return;
                    voice_slot.volume = parameter_change.value;
                },
                .set_pan => |parameter_change| {
                    const voice_slot: *VoiceSlot = renderer.playingSlotNamedBy(parameter_change.voice) orelse return;
                    voice_slot.pan = parameter_change.value;
                },
                .set_pitch => |parameter_change| {
                    const voice_slot: *VoiceSlot = renderer.playingSlotNamedBy(parameter_change.voice) orelse return;
                    voice_slot.pitch = parameter_change.value;
                },
                .set_looping => |looping_change| {
                    const voice_slot: *VoiceSlot = renderer.playingSlotNamedBy(looping_change.voice) orelse return;
                    // Only a sample buffer has an end to loop back from; a generator makes frames for as long as it
                    // plays.
                    switch (voice_slot.source) {
                        .samples => |*sample_source| sample_source.is_looping = looping_change.is_looping,
                        .generator, .stream => {},
                    }
                },
                .set_master_volume => |new_master_volume| renderer.master_volume = new_master_volume,
                .set_instrument => |new_instrument| {
                    // The notes playing hold states the new instrument cannot read: they end now.
                    for (first_instrument_slot..voice_capacity) |slot_index| {
                        renderer.endVoice(renderer_queues, slot_index);
                    }
                    renderer.instrument = new_instrument;
                    warmInstrument(new_instrument);
                },
                .register_samples => |samples_to_register| {
                    const samples_id: SamplesId = samples_to_register.samples_id;
                    renderer.registered_samples[samples_id] = samples_to_register.samples;
                },
                .release_samples => |samples_id| {
                    // The voices still playing these samples copy what they need and fade out over the copy; then the
                    // id leaves the registry, and the main side is told it may free the samples.
                    renderer.fadeVoicesReading(renderer_queues, samples_id);
                    renderer.registered_samples[samples_id] = &.{};
                    const released_notice: RendererNotice = .{ .samples_released = samples_id };
                    const is_noticed: bool = renderer_queues.notices.push(released_notice);
                    assert(is_noticed, @src());
                },
                // The host's to apply, in its own memory, before the command reaches here.
                .release_stream => {},
            }
        }

        /// Runs the instrument's four functions once, on a note of its own that no slot holds, so that the browser
        /// compiles them now - when the instrument is set, at the app's start - rather than in the block of the first
        /// key (`RendererHost.warmUp` explains the compiling). The note is struck at velocity 0, generated for one
        /// block, released, and generated for one more; its frames go to a stack buffer of this function's own, and its
        /// state is dropped at the end. No slot, queue or notice of the renderer is touched, so the renderer renders
        /// after it exactly as before. It runs wherever the renderer does; on a native audio thread, where nothing is
        /// compiled at run time, it costs one note's two blocks of work, once.
        fn warmInstrument(instrument: Instrument) void {
            var note_state: [generator_state_capacity]u8 align(16) = @splat(0);
            // Interleaved stereo, as a generator is always handed its block (`readVoiceSource`).
            var note_frames: [warm_instrument_frame_count * channel_count]f32 = undefined;
            const warm_up_key: u8 = 69;
            const silent_velocity: f32 = 0;
            instrument.start_note(&note_state, warm_up_key, silent_velocity);
            instrument.generate(&note_state, &note_frames, 0);
            instrument.release_note(&note_state);
            instrument.generate(&note_state, &note_frames, warm_instrument_frame_count);
            _ = instrument.has_fallen_silent(&note_state);
        }

        /// The slot of the voice `voice` names, while that voice plays; null when it has ended, or `voice` is `none`. A
        /// name is a slot and a generation (`Voice`): each time a slot's voice ends, the slot's generation counts up,
        /// so an old name - one an app kept after its voice ended - no longer matches, and reaches nothing, even once
        /// the slot holds a new voice.
        pub fn playingSlotNamedBy(renderer: *Renderer, voice: Voice) ?*VoiceSlot {
            if (voice == .none) {
                return null;
            }
            const slot_index: usize = voice.slotIndex();
            const voice_slot: *VoiceSlot = &renderer.voice_slots[slot_index];
            const is_same_generation: bool = voice_slot.generation == voice.generation();
            const is_named_voice_playing: bool = voice_slot.is_playing and is_same_generation;
            return if (is_named_voice_playing) voice_slot else null;
        }

        /// Starts a voice in the slot its name was given (by the main side, `Mixer.play`). Its samples are found by
        /// their id in the renderer's own registry, and a generator's state is copied into the slot. The voice starts
        /// at the gains its volume and pan ask for, with no ramp up from silence, so that a sound's attack - a drum's
        /// hit - stays sharp.
        fn startVoice(
            renderer: *Renderer,
            renderer_queues: *RendererQueues,
            voice_to_start: VoiceToStart,
        ) void {
            const slot_index: usize = voice_to_start.voice.slotIndex();
            const voice_slot: *VoiceSlot = &renderer.voice_slots[slot_index];
            // The main side gives a slot a new voice only after the renderer said its last one ended.
            assert(!voice_slot.is_playing, @src());
            const source: Source = switch (voice_to_start.source) {
                .samples => |registered| .{ .samples = .{
                    .samples = renderer.registered_samples[registered.samples_id],
                    .channels = registered.channels,
                    .sample_rate = registered.sample_rate,
                    .is_looping = registered.is_looping,
                } },
                .generator => |generator_to_start| .{ .generator = .{
                    .generate = generator_to_start.generate,
                    .channels = generator_to_start.channels,
                } },
                .stream => |ring| .{ .stream = .{ .ring = ring } },
                // The host gives a forwarded stream its ring before the command is queued (`acceptCommandBytes`).
                .forwarded_stream => panicf(
                    @src(),
                    "sound: a forwarded stream reached the renderer without its ring",
                    .{},
                ),
            };
            const samples_id: ?SamplesId = switch (voice_to_start.source) {
                .samples => |registered| registered.samples_id,
                .generator, .stream, .forwarded_stream => null,
            };
            const pan_law: PanLaw = panLawOf(source);
            const options: PlayOptions = voice_to_start.options;
            const starting_gains: StereoGains = gainsForPan(options.volume, options.pan, pan_law);
            voice_slot.* = .{
                .generation = voice_to_start.voice.generation(),
                .is_playing = true,
                .is_new = true,
                .pan_law = pan_law,
                .source = source,
                .samples_id = samples_id,
                .volume = options.volume,
                .pan = options.pan,
                .pitch = options.pitch,
                .last_block_gains = starting_gains,
            };
            voice_slot.generator_state = voice_to_start.generator_state;
            const play_pressed_at_ms: f64 = voice_to_start.options.pressed_at_ms;
            renderer.recordStart(renderer_queues, .play, voice_to_start.requested_at_ms, play_pressed_at_ms);
        }

        /// Measures a start in the block being rendered (`LatencySample`), when the block's output said when it would
        /// be heard and the request said when it was made; dropped when the measurements' queue is full.
        fn recordStart(
            renderer: *const Renderer,
            renderer_queues: *RendererQueues,
            kind: @FieldType(LatencySample, "kind"),
            requested_at_ms: f64,
            pressed_at_ms: f64,
        ) void {
            const timing: contract.AudioRenderTiming = renderer.current_block_timing orelse return;
            if (requested_at_ms == 0) {
                return;
            }
            const latency_sample: LatencySample = .{
                .kind = kind,
                .requested_at_ms = requested_at_ms,
                .applied_at_ms = timing.asked_at_ms,
                .first_frame_out_ms = timing.first_frame_out_ms,
                .pressed_at_ms = pressed_at_ms,
            };
            _ = renderer_queues.latency.push(latency_sample);
        }

        /// Stops a voice. Cutting a sound off in the middle of its wave would jump the output to zero between two
        /// samples, and a jump is heard as a click; so the voice fades to silence over `fade_out_frames` - 5 ms - in
        /// its next block, and only then ends and frees its slot. Its generation counts up at once, so that later
        /// commands naming it reach nothing. A voice not yet heard - started in this same block - or paused is silent
        /// already, and ends at once.
        fn stopVoice(
            renderer: *Renderer,
            renderer_queues: *RendererQueues,
            voice: Voice,
        ) void {
            const voice_slot: *VoiceSlot = renderer.playingSlotNamedBy(voice) orelse return;
            const is_silent_already: bool = voice_slot.is_new or voice_slot.is_paused;
            if (is_silent_already) {
                renderer.endVoice(renderer_queues, voice.slotIndex());
                return;
            }
            voice_slot.fade_out = .then_stop;
            voice_slot.fade_frames_left = fade_out_frames;
            voice_slot.generation +%= 1;
        }

        /// Lets every voice playing the samples registered under `samples_id` fade out before those samples are freed:
        /// a sound unloaded while voices of it, or of its aliases, still sound. A fade needs 5 ms more of the sound, so
        /// each such voice first copies its next `fade_out_frames` frames - read at its own pitch, and so already at
        /// the mixer's rate - into a buffer of its own, and fades out over that copy. Nothing reads the samples after
        /// this, and nothing is cut off. A voice not yet heard, or paused, is silent already, and ends at once.
        fn fadeVoicesReading(
            renderer: *Renderer,
            renderer_queues: *RendererQueues,
            samples_id: SamplesId,
        ) void {
            for (&renderer.voice_slots, 0..) |*voice_slot, slot_index| {
                if (!voice_slot.is_playing) {
                    continue;
                }
                // A generator, or a voice already playing its own copy, reads no registered samples.
                const voice_samples_id: SamplesId = voice_slot.samples_id orelse continue;
                const is_reading_these_samples: bool = voice_samples_id == samples_id;
                if (!is_reading_these_samples) {
                    continue;
                }
                const is_silent_already: bool = voice_slot.is_new or voice_slot.is_paused;
                if (is_silent_already) {
                    renderer.endVoice(renderer_queues, slot_index);
                    continue;
                }
                // Its next 5 ms, into the copy kept for its slot: interleaved stereo at the mixer's rate, its pitch
                // applied by the reading.
                const tail_buffer: []f32 = &renderer.tail_copies[slot_index];
                const tail_frames_read: usize = readVoiceSource(voice_slot, tail_buffer);
                const tail_sample_count: usize = tail_frames_read * channel_count;
                const tail_samples_read: []const f32 = tail_buffer[0..tail_sample_count];
                // From now on the voice plays its copy - at the mixer's rate and at pitch 1, its pitch being in the
                // copy already - fading out to the copy's end.
                voice_slot.source = .{ .samples = .{
                    .samples = tail_samples_read,
                    .channels = channel_count,
                    .sample_rate = sample_rate,
                } };
                voice_slot.samples_id = null;
                voice_slot.source_position = 0;
                voice_slot.pitch = 1;
                voice_slot.fade_out = .then_stop;
                voice_slot.fade_frames_left = fade_out_frames;
                voice_slot.generation +%= 1;
            }
        }

        /// Pauses a voice: it keeps its slot and its place in its source, and is not mixed until resumed. As a stop
        /// does, a pause fades the voice out over `fade_out_frames` first - its place in the source moving on only by
        /// those frames, so that it resumes where it fell silent. A voice not yet heard pauses at once. (With an output
        /// the mixer pushes blocks to, the voice's frames already queued still play out first.)
        fn pauseVoice(renderer: *Renderer, voice: Voice) void {
            const voice_slot: *VoiceSlot = renderer.playingSlotNamedBy(voice) orelse return;
            const is_paused_or_pausing: bool = voice_slot.is_paused or voice_slot.fade_out != .none;
            if (is_paused_or_pausing) {
                return;
            }
            if (voice_slot.is_new) {
                voice_slot.is_paused = true;
                return;
            }
            voice_slot.fade_out = .then_pause;
            voice_slot.fade_frames_left = fade_out_frames;
        }

        /// Resumes a paused voice where it fell silent, from the renderer's next block, its gains ramping up from
        /// silence across that block. A pause whose fade has not finished is simply called off: the gains ramp back up
        /// from wherever the fade had brought them. (With an output the mixer pushes blocks to, a resumed voice
        /// continues after the frames already queued - not inside them, as a new voice starts: its frames queued before
        /// the pause still play, and its continuation placed among them would sound twice.)
        fn resumeVoice(renderer: *Renderer, voice: Voice) void {
            const voice_slot: *VoiceSlot = renderer.playingSlotNamedBy(voice) orelse return;
            const is_pause_still_fading: bool = voice_slot.fade_out == .then_pause;
            if (is_pause_still_fading) {
                voice_slot.fade_out = .none;
                voice_slot.fade_frames_left = 0;
                return;
            }
            voice_slot.is_paused = false;
        }

        /// Ends the voice in a slot: it is mixed no more, its generation counts up - so that its name reaches nothing
        /// any more - and the main side is told, by a notice, that the slot is free (`Mixer.readRendererNotices`).
        fn endVoice(
            renderer: *Renderer,
            renderer_queues: *RendererQueues,
            slot_index: usize,
        ) void {
            const voice_slot: *VoiceSlot = &renderer.voice_slots[slot_index];
            if (!voice_slot.is_playing) {
                return;
            }
            voice_slot.is_playing = false;
            voice_slot.generation +%= 1;
            // The instrument's slots were never named by the main side, which has nothing to free for them.
            const is_instrument_slot: bool = slot_index >= first_instrument_slot;
            if (is_instrument_slot) {
                return;
            }
            const ended_notice: RendererNotice = .{ .voice_ended = @intCast(slot_index) };
            const is_noticed: bool = renderer_queues.notices.push(ended_notice);
            assert(is_noticed, @src());
        }

        /// Applies every key event waiting, from both note queues - each in the order its keys moved. Without an
        /// instrument they are dropped.
        fn applyNotes(renderer: *Renderer, renderer_queues: *RendererQueues) void {
            renderer.applyNoteQueue(renderer_queues, &renderer_queues.notes);
            renderer.applyNoteQueue(renderer_queues, &renderer_queues.input_thread_notes);
        }

        fn applyNoteQueue(
            renderer: *Renderer,
            renderer_queues: *RendererQueues,
            note_queue: *NoteQueue,
        ) void {
            while (note_queue.pop()) |note_event| {
                const instrument: Instrument = renderer.instrument orelse continue;
                if (note_event.is_down) {
                    renderer.startNote(instrument, note_event);
                    const note_pressed_at_ms: f64 = note_event.pressed_at_ms;
                    renderer.recordStart(renderer_queues, .note, note_event.requested_at_ms, note_pressed_at_ms);
                } else {
                    renderer.releaseNote(instrument, note_event.key);
                }
            }
        }

        /// Starts a note in an instrument slot. The same key struck again while its note is held releases that note
        /// first: it rings on in its release beside the new one, as a piano's string does when struck again, and a key
        /// holds one note at a time - a trill does not pile up held voices. The slot is the first free one; with all
        /// sixteen sounding, the one `noteSlotToSteal` names gives its note up, which fades out over 5 ms from a copy
        /// made before its slot is reused (`keepFadeOfStolenNote`), so that it ends without a click.
        fn startNote(
            renderer: *Renderer,
            instrument: Instrument,
            note_event: NoteEvent,
        ) void {
            renderer.releaseNote(instrument, note_event.key);
            const chosen_slot_index: usize = renderer.freeNoteSlot() orelse renderer.noteSlotToSteal(note_event.key);
            const voice_slot: *VoiceSlot = &renderer.voice_slots[chosen_slot_index];
            if (voice_slot.is_playing) {
                renderer.keepFadeOfStolenNote(voice_slot);
            }
            // A note starts at full gain, centred, with no ramp: its attack is the instrument's to shape.
            const centre_gains: StereoGains = gainsForPan(1, 0, .constant_power);
            voice_slot.* = .{
                .generation = voice_slot.generation +% 1,
                .is_playing = true,
                .is_new = true,
                .pan_law = .constant_power,
                .source = .{ .generator = .{ .generate = instrument.generate, .channels = 1 } },
                .last_block_gains = centre_gains,
                .note_key = note_event.key,
                .is_note_held = true,
            };
            instrument.start_note(&voice_slot.generator_state, note_event.key, note_event.velocity);
            if (instrument.places_notes_by_time) {
                voice_slot.start_delay_frames = renderer.placementOfNote(note_event);
            }
        }

        /// How many frames into the block a note placed by its time starts (`Instrument.places_notes_by_time`): its
        /// request's distance from the moment the block before was asked for, in frames. A note requested just after
        /// that block starts at this block's first frame, one requested just before this block near its last - each
        /// as far into its block as it came into the wait between the two. A note with no request time, or with no
        /// timed block before it, starts at the first frame; so does one that waited longer than a block, which is
        /// late however it is placed.
        fn placementOfNote(renderer: *const Renderer, note_event: NoteEvent) u32 {
            const previous_block_asked_at_ms: f64 = renderer.previous_block_asked_at_ms;
            const has_both_times: bool = previous_block_asked_at_ms > 0 and note_event.requested_at_ms > 0;
            if (!has_both_times) {
                return 0;
            }
            // How far into the wait between the two blocks the note was asked for, in frames.
            const into_wait_ms: f64 = note_event.requested_at_ms - previous_block_asked_at_ms;
            const into_wait_frames: f64 = @round(into_wait_ms * float64(sample_rate) / 1000);
            // A request a whole block late, or more, is late however it is placed: at the first frame.
            const block_frame_count: f64 = @floatFromInt(renderer.current_block_frame_count);
            const is_within_block: bool = into_wait_frames > 0 and into_wait_frames < block_frame_count;
            return if (is_within_block) @trunc(into_wait_frames) else 0;
        }

        /// The first instrument slot sounding nothing; null when all sixteen sound.
        fn freeNoteSlot(renderer: *const Renderer) ?usize {
            for (first_instrument_slot..voice_capacity) |slot_index| {
                if (!renderer.voice_slots[slot_index].is_playing) {
                    return slot_index;
                }
            }
            return null;
        }

        /// The slot a new note of `key` takes when all sixteen sound, chosen as JUCE's synthesiser chooses
        /// (`Synthesiser::findVoiceToSteal`), "longest-sounding" meaning the most frames generated:
        ///
        ///     1. the longest-sounding note of the same key - its own earlier sound
        ///     2. else the longest-sounding released note - one no finger holds
        ///     3. else the longest-sounding held note other than the lowest and the highest held - a chord keeps
        ///        its bass and its top
        ///     4. else the highest held note, and the lowest last
        ///
        /// A held note is lost only when every other choice is gone, and the notes that carry a chord - its
        /// lowest and its highest - last of all.
        fn noteSlotToSteal(renderer: *const Renderer, key: u8) usize {
            // The lowest and the highest held notes, which are protected.
            var lowest_held_slot: ?usize = null;
            var highest_held_slot: ?usize = null;
            for (first_instrument_slot..voice_capacity) |slot_index| {
                const voice_slot: *const VoiceSlot = &renderer.voice_slots[slot_index];
                if (!voice_slot.is_note_held) {
                    continue;
                }
                const is_lower: bool = if (lowest_held_slot) |lowest_slot|
                    voice_slot.note_key < renderer.voice_slots[lowest_slot].note_key
                else
                    true;
                const is_higher: bool = if (highest_held_slot) |highest_slot|
                    voice_slot.note_key > renderer.voice_slots[highest_slot].note_key
                else
                    true;
                if (is_lower) {
                    lowest_held_slot = slot_index;
                }
                if (is_higher) {
                    highest_held_slot = slot_index;
                }
            }
            // A single held note is both the lowest and the highest: it is the lowest, protected to the last.
            if (highest_held_slot == lowest_held_slot) {
                highest_held_slot = null;
            }
            // The longest-sounding slot of each kind.
            var same_key_slot: ?usize = null;
            var released_slot: ?usize = null;
            var unprotected_held_slot: ?usize = null;
            for (first_instrument_slot..voice_capacity) |slot_index| {
                const voice_slot: *const VoiceSlot = &renderer.voice_slots[slot_index];
                if (voice_slot.note_key == key and isLongerSounding(renderer, slot_index, same_key_slot)) {
                    same_key_slot = slot_index;
                }
                const is_protected: bool = slot_index == lowest_held_slot or slot_index == highest_held_slot;
                if (!voice_slot.is_note_held and isLongerSounding(renderer, slot_index, released_slot)) {
                    released_slot = slot_index;
                }
                const is_unprotected_held: bool = voice_slot.is_note_held and !is_protected;
                if (is_unprotected_held and isLongerSounding(renderer, slot_index, unprotected_held_slot)) {
                    unprotected_held_slot = slot_index;
                }
            }
            return same_key_slot orelse released_slot orelse unprotected_held_slot orelse
                highest_held_slot orelse lowest_held_slot.?;
        }

        /// Whether the note in `slot_index` has sounded longer than the one in `other_slot_index` - true against
        /// no slot at all.
        fn isLongerSounding(
            renderer: *const Renderer,
            slot_index: usize,
            other_slot_index: ?usize,
        ) bool {
            const other_index: usize = other_slot_index orelse return true;
            const frames: u64 = renderer.voice_slots[slot_index].generated_frame_count;
            const other_frames: u64 = renderer.voice_slots[other_index].generated_frame_count;
            return frames > other_frames;
        }

        /// Keeps the fade of a note about to lose its slot. A note cut off between two samples would jump to zero,
        /// heard as a click; a stopped voice avoids it by fading in its own slot (`stopVoice`), but a stolen note's
        /// slot is needed now. So its next `fade_out_frames` frames are generated here, at the gains its last block
        /// ended with, ramped from full to zero - frame `n` of `F` scaled by `1 - (n + 1) / F` - and added into the
        /// tail that the next blocks mix in (`addStolenNoteTail`). The note's generator continues exactly where its
        /// last block stopped, so the fade begins at the very frame the note would have played next.
        fn keepFadeOfStolenNote(renderer: *Renderer, voice_slot: *VoiceSlot) void {
            const tail_sample_count: usize = renderer.stolen_note_tail.len;
            const voice_samples: []f32 = renderer.voice_scratch_samples[0..tail_sample_count];
            _ = readVoiceSource(voice_slot, voice_samples);
            const gains: StereoGains = voice_slot.last_block_gains;
            const fade_frame_count: f32 = float(fade_out_frames);
            for (0..fade_out_frames) |frame_index| {
                const remaining_fraction: f32 = 1 - float(frame_index + 1) / fade_frame_count;
                const left_index: usize = frame_index * channel_count;
                const right_index: usize = left_index + 1;
                renderer.stolen_note_tail[left_index] += voice_samples[left_index] * gains.left * remaining_fraction;
                renderer.stolen_note_tail[right_index] += voice_samples[right_index] * gains.right * remaining_fraction;
            }
            renderer.stolen_tail_frames_left = fade_out_frames;
        }

        /// Adds the waiting fade of stolen notes into the start of `mix_block`, as much of it as the block holds;
        /// what is left moves to the front of the tail, for the next block, and the room it leaves is zeroed.
        fn addStolenNoteTail(renderer: *Renderer, mix_block: []f32) void {
            const frames_left: u32 = renderer.stolen_tail_frames_left;
            if (frames_left == 0) {
                return;
            }
            const block_frame_count: usize = mix_block.len / channel_count;
            const frames_added: usize = @min(frames_left, block_frame_count);
            const samples_added: usize = frames_added * channel_count;
            const tail: []f32 = &renderer.stolen_note_tail;
            for (mix_block[0..samples_added], tail[0..samples_added]) |*mixed_sample, tail_sample| {
                mixed_sample.* += tail_sample;
            }
            const frames_still_left: usize = frames_left - frames_added;
            const samples_still_left: usize = frames_still_left * channel_count;
            copyForwards(f32, tail[0..samples_still_left], tail[samples_added..][0..samples_still_left]);
            @memset(tail[samples_still_left..], 0);
            renderer.stolen_tail_frames_left = @intCast(frames_still_left);
        }

        /// Releases the held note of `key`: its envelope turns to its release, and it sounds on until it has fallen
        /// silent (`endSilentNotes`).
        fn releaseNote(
            renderer: *Renderer,
            instrument: Instrument,
            key: u8,
        ) void {
            for (first_instrument_slot..voice_capacity) |slot_index| {
                const voice_slot: *VoiceSlot = &renderer.voice_slots[slot_index];
                const is_held_note_of_key: bool = voice_slot.is_playing and voice_slot.is_note_held and
                    voice_slot.note_key == key;
                if (is_held_note_of_key) {
                    voice_slot.is_note_held = false;
                    instrument.release_note(&voice_slot.generator_state);
                }
            }
        }

        /// Frees the slot of every note that has fallen silent, after the block that made its last sound.
        fn endSilentNotes(renderer: *Renderer) void {
            const instrument: Instrument = renderer.instrument orelse return;
            for (first_instrument_slot..voice_capacity) |slot_index| {
                const voice_slot: *VoiceSlot = &renderer.voice_slots[slot_index];
                if (voice_slot.is_playing and instrument.has_fallen_silent(&voice_slot.generator_state)) {
                    voice_slot.is_playing = false;
                }
            }
        }

        /// Ends every voice at once: the output is closing.
        fn endEveryVoice(renderer: *Renderer, renderer_queues: *RendererQueues) void {
            for (0..voice_capacity) |slot_index| {
                renderer.endVoice(renderer_queues, slot_index);
            }
        }

        /// Mixes every playing voice into `mix_block`, interleaved stereo frames. The block starts silent; each voice
        /// adds its frames into it (`mixVoiceInto`); then the mix's last stage scales it by the master volume and
        /// keeps it within the range a device plays (`limitAndBend`) - several loud voices can add up past 1, and a
        /// device given more would cut the wave flat, or wrap the sample round to the other end.
        fn mixInto(
            renderer: *Renderer,
            renderer_queues: *RendererQueues,
            mix_block: []f32,
        ) void {
            @memset(mix_block, 0);
            renderer.addStolenNoteTail(mix_block);
            for (&renderer.voice_slots, 0..) |*voice_slot, slot_index| {
                const is_audible: bool = voice_slot.is_playing and !voice_slot.is_paused;
                if (is_audible) {
                    renderer.mixVoiceInto(renderer_queues, slot_index, mix_block);
                }
            }
            renderer.limitAndBend(mix_block);
        }

        /// The mix's last stage, frame by frame: the master volume; then the limiter (`limiter_threshold`), one gain
        /// for both channels, so that the sound's place between the speakers holds; then the soft bend under full scale
        /// (`softClip`) for what still passes the knee. The limiter follows the frame's peak with an envelope that
        /// rises at once and falls slowly - 100 ms to fall by a factor of e - and aims its gain at the threshold over
        /// the envelope, reaching for it over about a millisecond: no step in the gain, so no click, and no wait - the
        /// mix is not delayed to see a peak coming, so the first millisecond of a sudden peak passes to the bend. A
        /// sample that would pass full scale without the limiter is counted, each channel's on its own (`takeClicks`).
        fn limitAndBend(renderer: *Renderer, mix_block: []f32) void {
            const frame_count: usize = mix_block.len / channel_count;
            var envelope: f32 = renderer.limiter_envelope;
            var gain: f32 = renderer.limiter_gain;
            for (0..frame_count) |frame_index| {
                const frame: []f32 = mix_block[frame_index * channel_count ..][0..channel_count];
                var frame_peak: f32 = 0;
                for (frame) |*mixed_sample| {
                    mixed_sample.* *= renderer.master_volume;
                    const magnitude: f32 = @abs(mixed_sample.*);
                    // A sample the output would have clipped without the limiter: counted, each channel's on its own.
                    if (magnitude > 1) {
                        renderer.clipped_samples_since_taken += 1;
                    }
                    frame_peak = @max(frame_peak, magnitude);
                }
                envelope = @max(frame_peak, envelope * limiter_release_factor);
                const target_gain: f32 = if (envelope > limiter_threshold) limiter_threshold / envelope else 1;
                gain += (target_gain - gain) * limiter_attack_weight;
                // An approach by a share of the gap stalls short of its target in floating point: once a 48th of the
                // gap is under half a unit in the last place, it rounds to nothing - just below 1, where a unit is
                // 6e-8, with the gap still up to 24 units, 1.4e-6 - and the gain would stay there for good, every later
                // sample scaled by 0.9999986. Within ten millionths of its target, it takes it.
                if (@abs(target_gain - gain) < limiter_gain_snap) {
                    gain = target_gain;
                }
                for (frame) |*mixed_sample| {
                    mixed_sample.* = softClip(mixed_sample.* * gain);
                }
            }
            renderer.limiter_envelope = envelope;
            renderer.limiter_gain = gain;
        }

        /// The level past which the mix is bent toward full scale (`softClip`): 0.8.
        pub const soft_clip_knee: f32 = 0.8;

        /// The peak the limiter holds the mix to (`limitAndBend`): 0.7, under the bend's knee, so that a held loud
        /// chord is turned down rather than bent.
        pub const limiter_threshold: f32 = 0.7;
        /// The limiter's envelope, multiplied by this each frame when the peak is lower: e^(-1 / 4800), falling by a
        /// factor of e in 100 ms at 48 000 Hz. Slower than any note's waves, so the gain does not follow each cycle.
        const limiter_release_factor: f32 = 0.99979168;
        /// The share of the way from the limiter's gain to its target taken each frame: 1/48, a millisecond's time
        /// constant at 48 000 Hz.
        const limiter_attack_weight: f32 = 1.0 / 48.0;
        /// How near its target the limiter's gain is taken to have arrived: ten millionths, -0.000087 dB - past the
        /// 1.4 millionths short of 1 where its approach stalls (`limitAndBend`).
        const limiter_gain_snap: f32 = 1e-5;

        /// The mix's last stage: a sample is kept as it is up to `soft_clip_knee`, and above it bent toward full scale
        /// by a hyperbolic tangent - `knee + (1 - knee) tanh((|x| - knee) / (1 - knee))` - which leaves the knee at the
        /// same value and the same slope, 1, and approaches 1 without reaching it. Cutting the wave flat at full scale,
        /// as an output does with what passes it, makes corners - each a jump in the wave's slope, a click, a dense
        /// mix's peaks heard as crackle; the curve has none. Above the knee the sound is gently saturated rather than
        /// broken. The peaks of a loud chord of many notes pass full scale; quiet sound never reaches the knee.
        fn softClip(sample: f32) f32 {
            const magnitude: f32 = @abs(sample);
            if (magnitude <= soft_clip_knee) {
                return sample;
            }
            const headroom: f32 = 1 - soft_clip_knee;
            const overshoot_in_headrooms: f32 = (magnitude - soft_clip_knee) / headroom;
            const bent_magnitude: f32 = soft_clip_knee + headroom * tanh(overshoot_in_headrooms);
            return if (sample < 0) -bent_magnitude else bent_magnitude;
        }

        /// Adds one voice's frames for this block into `mix_block`.
        ///
        /// The voice's source is read first, into the scratch block: interleaved stereo at the mixer's rate, its pitch
        /// applied by the reading (`readVoiceSource`). Then each frame is added in, its left sample times the left gain
        /// and its right sample times the right gain. The gains never jump from one block to the next: they move in
        /// equal steps, frame by frame, from where the last block left them to where the voice's volume and pan now ask
        /// for - a change of volume is a short ramp, not a click. Raised from 0.5 to 1.0, over a block of n frames:
        ///
        ///     frame       1              2              ...   n
        ///     gain        0.5 + 0.5/n    0.5 + 1.0/n    ...   1.0
        ///
        /// A voice fading out - stopped or paused - is mixed for what remains of its fade, as much as this block holds,
        /// its gains falling by the same step every frame, so that a fade split across blocks is one straight line,
        /// reaching silence at its last frame whichever block that falls in (`gainsPartWayDown`). Its source moves on
        /// no further than it is heard, so a paused voice resumes where it fell silent. A source that runs out before
        /// the block's end - a sound that has finished - ends its voice.
        fn mixVoiceInto(
            renderer: *Renderer,
            renderer_queues: *RendererQueues,
            slot_index: usize,
            mix_block: []f32,
        ) void {
            const voice_slot: *VoiceSlot = &renderer.voice_slots[slot_index];
            // A note placed by its time starts that many frames into the block (`placementOfNote`): the voice's
            // frames are mixed from there, the block's before it left as they are.
            const delay_frame_count: usize = @min(voice_slot.start_delay_frames, mix_block.len / channel_count);
            voice_slot.start_delay_frames = 0;
            const delayed_block: []f32 = mix_block[delay_frame_count * channel_count ..];
            const block_frame_count: usize = delayed_block.len / channel_count;
            // Mixed, the voice is heard: a stop or a pause from now on fades it rather than ending it at once.
            voice_slot.is_new = false;
            const fade: FadeOut = voice_slot.fade_out;
            const is_fading_out: bool = fade != .none;
            const fade_frames_left_before: u32 = voice_slot.fade_frames_left;
            const fade_frames_in_block: usize = @min(fade_frames_left_before, block_frame_count);
            const frames_wanted: usize = if (is_fading_out) fade_frames_in_block else block_frame_count;
            const voice_sample_count: usize = frames_wanted * channel_count;
            const voice_samples: []f32 = renderer.voice_scratch_samples[0..voice_sample_count];
            const frames_read: usize = readVoiceSource(voice_slot, voice_samples);
            // The gains: from where the last block left them, to where this block must leave them.
            const starting_gains: StereoGains = voice_slot.last_block_gains;
            const fading_gains: StereoGains = gainsPartWayDown(starting_gains, frames_wanted, fade_frames_left_before);
            const panned_gains: StereoGains = gainsForPan(voice_slot.volume, voice_slot.pan, voice_slot.pan_law);
            const target_gains: StereoGains = if (is_fading_out) fading_gains else panned_gains;
            const ramp_frame_count: f32 = @floatFromInt(frames_wanted);
            const left_gain_step: f32 = (target_gains.left - starting_gains.left) / ramp_frame_count;
            const right_gain_step: f32 = (target_gains.right - starting_gains.right) / ramp_frame_count;
            var left_gain: f32 = starting_gains.left;
            var right_gain: f32 = starting_gains.right;
            var frame_index: usize = 0;
            while (frame_index < frames_read) : (frame_index += 1) {
                left_gain += left_gain_step;
                right_gain += right_gain_step;
                const left_sample_index: usize = frame_index * channel_count;
                const right_sample_index: usize = left_sample_index + 1;
                const left_voice_sample: f32 = voice_samples[left_sample_index];
                const right_voice_sample: f32 = voice_samples[right_sample_index];
                delayed_block[left_sample_index] += left_voice_sample * left_gain;
                delayed_block[right_sample_index] += right_voice_sample * right_gain;
            }
            // The gains this block ends at, exactly - whatever rounding the steps gathered - for the next to start
            // from.
            voice_slot.last_block_gains = target_gains;
            const has_source_ended: bool = frames_read < frames_wanted;
            if (has_source_ended) {
                renderer.endVoice(renderer_queues, slot_index);
                return;
            }
            if (!is_fading_out) {
                return;
            }
            voice_slot.fade_frames_left = fade_frames_left_before - @as(u32, @intCast(frames_wanted));
            const is_fade_finished: bool = voice_slot.fade_frames_left == 0;
            if (!is_fade_finished) {
                return;
            }
            switch (fade) {
                .then_stop => renderer.endVoice(renderer_queues, slot_index),
                .then_pause => {
                    voice_slot.fade_out = .none;
                    voice_slot.is_paused = true;
                },
                .none => assertUnreachable(@src(), "sound: a voice's fade ended with nothing to do after it", .{}),
            }
        }
    };

    /// The gains `frames_mixed` frames into a fall to silence that had `frames_left` frames to go: the starting gains,
    /// down by the fraction of the fall those frames make. A fall over 240 frames, 100 of them mixed in one block,
    /// leaves 140/240 of the starting gains; the next block falls from there over the 140 left - by the same step per
    /// frame, so the two blocks make one straight line down to silence.
    fn gainsPartWayDown(
        starting_gains: StereoGains,
        frames_mixed: usize,
        frames_left: u32,
    ) StereoGains {
        // No fall under way: nothing to scale (a voice not fading never uses the result).
        if (frames_left == 0) {
            return starting_gains;
        }
        const frames_mixed_float: f32 = @floatFromInt(frames_mixed);
        const frames_left_float: f32 = @floatFromInt(frames_left);
        const fraction_of_fall_done: f32 = frames_mixed_float / frames_left_float;
        const fraction_remaining: f32 = 1 - fraction_of_fall_done;
        return .{
            .left = starting_gains.left * fraction_remaining,
            .right = starting_gains.right * fraction_remaining,
        };
    }

    /// Lets other threads run, while this one waits for the renderer's thread - to take commands, or to let go of
    /// samples. A processor core runs one thread at a time, and the operating system decides which; yielding tells it
    /// this thread has nothing to do for now, so the renderer's thread, if it waits for the same core, runs sooner. A
    /// system that refuses leaves this thread looping on, which only costs it time.
    fn yieldThisThread() void {
        // A build with no threads - the browser's - has no renderer on another thread to wait for.
        if (comptime builtin.single_threaded) {
            return;
        }
        // lint:off catch-suppression: a yield refused only means this thread loops on while it waits
        std.Thread.yield() catch {};
    }

    /// A sample buffer in the main side's registry (`Mixer.samples_registry`), under the id that is its index there.
    const RegisteredSamplesRecord = struct {
        /// The buffer, in the main side's memory.
        samples: []const f32 = &.{},
        /// Whether the id is in use.
        is_registered: bool = false,
        /// Once the buffer is being released: the allocator to free it with, when the renderer says it let it go
        /// (`Mixer.releaseSamples`). Null while it may still be played.
        release_allocator: ?Allocator = null,
    };

    /// A voice's name as the main side keeps it, one for each slot (`Mixer.voice_names`). A voice's life, as its record
    /// sees it:
    ///
    ///     play             the slot held, the name live           (isPlaying: true)
    ///     stopVoice        the name dead, the slot still held      (isPlaying: false; the renderer fades it out)
    ///     ... the renderer's notice "this slot's voice ended" is read ...
    ///                      the slot free, for the next play
    ///
    /// A voice that ends by itself - its sound finished - goes from live to free at the notice.
    const VoiceNameRecord = struct {
        /// The generation the slot's current name carries (`Voice`): counted up each time a name dies, so that an old
        /// name never matches again.
        generation: u24 = 0,
        /// The renderer holds the slot: from `play` until its notice that the voice ended. A stopped voice still fading
        /// keeps its slot.
        is_slot_held: bool = false,
        /// The name still names a voice: false from `stopVoice` on, though the slot may still be fading.
        is_name_live: bool = false,
        is_paused: bool = false,
    };

    /// The main side of the mixer: what the app calls. It names each voice when it is played, registers sample buffers
    /// the first time they play, sends the renderer a command for every change, and reads back what the renderer
    /// noticed - voices ended, samples let go of. Every question - `isPlaying`, `isPaused` - is answered at once from
    /// the names it keeps, without asking the renderer: the answer may be a frame behind the sound, never wrong for
    /// long.
    pub const Mixer = struct {
        // The main side's own bookkeeping.

        /// Each slot's name, as the main side keeps it.
        voice_names: [voice_capacity]VoiceNameRecord = @splat(.{}),
        /// The sample buffers registered, each under its id - its index here (`SamplesId`).
        samples_registry: [samples_registry_capacity]RegisteredSamplesRecord = @splat(.{}),
        /// The master volume asked for, as the renderer will apply it (`setMasterVolume`).
        master_volume: f32 = 1,
        /// The last `recent_start_capacity` starts the renderer measured (`LatencySample`), in a ring: the one at
        /// `recent_start_count - 1` (modulo the capacity) is the newest (`recentStarts`).
        recent_starts: [recent_start_capacity]LatencySample = undefined,
        recent_start_count: usize = 0,

        // The renderer and the two queues to it - in the browser, a renderer in another memory is reached instead
        // (`RendererHost`), and this one stays unused.

        renderer_queues: RendererQueues = .{},
        renderer: Renderer = .{},
        /// The analysers attached (`analyser`), and the room one read's analysis is done in: the frames, windowed in
        /// place, their spectrum, and the transform's scratch.
        analysers: [analyser_capacity]AnalyserSlot = @splat(.{}),
        analysis_frames: [analysis_ring_frames]f32 = undefined,
        analysis_spectrum: [analysis_ring_frames / 2 + 1]zn.ComplexNumber(f32) = undefined,
        analysis_scratch: [analysis_ring_frames / 2]zn.ComplexNumber(f32) = undefined,

        // The output.

        /// The output the mixer plays through; null until `start`, and after `stop`.
        output: ?Output = null,
        /// The renderer in another memory the commands are forwarded to, while the output forwards
        /// (`Output.forwarding`); null otherwise.
        forwarding: ?ForwardingOutput = null,
        /// A frame's forwarded commands, gathered to travel as one message (`sendForwardBatch`) - as JUCE's
        /// `MidiBuffer` keeps a block's events in one array of bytes: a message per command would cost the page a
        /// `postMessage`, and a buffer, each. `forward_batch_length` bytes of it are waiting.
        forward_batch: [forward_batch_command_capacity * @sizeOf(RendererCommand)]u8 = undefined,
        forward_batch_length: usize = 0,
        /// The streams this side forwards to a renderer in another memory, each under its number
        /// (`ForwardedStreamRecord`).
        forwarded_streams: [forwarded_stream_capacity]ForwardedStreamRecord = @splat(.{}),
        /// Each stream number's generation, counted on each stream given it (`ForwardedStream.generation`).
        forwarded_stream_generations: [forwarded_stream_capacity]u8 = @splat(0),
        /// Whether the renderer on an audio thread took nothing for a whole wait (`sendToRenderer`, `sendNote`): the
        /// next sends do not wait for it, until one finds room again.
        has_renderer_stalled: bool = false,
        /// Whether the renderer runs on another thread than this one (`Output.calls_renderer_from_another_thread`).
        is_renderer_on_another_thread: bool = false,
        /// What allocated the blocks, to free them at `stop`.
        allocator: ?Allocator = null,

        // For an output the mixer pushes blocks to only: the margin it keeps queued ahead of the device, and what
        // decides it (`mixFrame`).

        /// Opens `output` at the mixer's format: 48 000 frames a second, stereo. The platform grants it - Windows and a
        /// browser convert from it to their device's own format - so the mixer mixes at its own rate whatever the
        /// device's. Where the platform offers a renderer in another memory (`Output.forwarding`) and it starts, the
        /// commands go there; otherwise the output pulls from the renderer here, handed `renderForPullingOutput`. The
        /// renderer's scratch block is allocated here, once, so that rendering allocates nothing. A mixer already
        /// started is stopped first.
        pub fn start(
            engine_mixer: *Mixer,
            allocator: Allocator,
            output: Output,
        ) Allocator.Error!void {
            // Started again: the earlier output is closed and its blocks freed first, so that nothing leaks.
            engine_mixer.stop();
            const largest_block_frame_count: usize = render_block_most_frames;
            const largest_block_sample_count: usize = largest_block_frame_count * channel_count;
            engine_mixer.renderer.voice_scratch_samples = try allocator.alloc(f32, largest_block_sample_count);
            engine_mixer.allocator = allocator;
            const wanted_format: contract.AudioFormat = .{ .sample_rate = sample_rate, .channels = channel_count };
            // An output that pulls is handed the renderer, reached through this mixer - which must stay where it is
            // while the output runs, as the engine's own does, inside the app.
            const render_callback: contract.AudioRenderCallback = .{
                .context = engine_mixer,
                .render = &renderForPullingOutput,
            };
            engine_mixer.is_renderer_on_another_thread = output.calls_renderer_from_another_thread;
            // A renderer in another memory, when the platform has one and it started: the commands go there, and the
            // renderer here stays unused. It counts as on another thread: samples wait for its notice to be freed.
            const forwarded_format: ?contract.AudioFormat = if (output.forwarding) |forwarding|
                forwarding.start(wanted_format)
            else
                null;
            if (forwarded_format != null) {
                engine_mixer.forwarding = output.forwarding;
                engine_mixer.is_renderer_on_another_thread = true;
            }
            const granted_format: contract.AudioFormat = forwarded_format orelse
                output.start_pulling(wanted_format, render_callback);
            const is_rate_granted: bool = granted_format.sample_rate == sample_rate;
            const are_channels_granted: bool = granted_format.channels == channel_count;
            if (!is_rate_granted or !are_channels_granted) {
                std.log.scoped(.mixer).warn("the output granted {d} Hz, {d} channels, not the mix's", .{
                    granted_format.sample_rate,
                    granted_format.channels,
                });
            }
            engine_mixer.output = output;
        }

        /// Closes the output, applies the commands not yet applied - so that a release among them still frees its
        /// samples - ends every voice, and frees the renderer's scratch block.
        pub fn stop(engine_mixer: *Mixer) void {
            const output: Output = engine_mixer.output orelse return;
            output.stop();
            engine_mixer.output = null;
            if (engine_mixer.forwarding != null) {
                engine_mixer.stopForwarding();
            }
            engine_mixer.is_renderer_on_another_thread = false;
            // The output is stopped, so nothing renders any more: this thread may take the renderer's part.
            engine_mixer.renderer.applyCommands(&engine_mixer.renderer_queues);
            engine_mixer.renderer.endEveryVoice(&engine_mixer.renderer_queues);
            engine_mixer.readRendererNotices();
            if (engine_mixer.allocator) |allocator| {
                allocator.free(engine_mixer.renderer.voice_scratch_samples);
            }
            engine_mixer.renderer.voice_scratch_samples = &.{};
        }

        /// Ends forwarding with the output closed: the renderer in the other memory is gone, and the notices it would
        /// have sent never come. So every voice it held is ended here, by name, and the samples waiting for its notice
        /// of release are freed now - the other memory held only its own copies of them.
        fn stopForwarding(engine_mixer: *Mixer) void {
            engine_mixer.forwarding = null;
            engine_mixer.forward_batch_length = 0;
            for (&engine_mixer.voice_names) |*voice_name| {
                if (voice_name.is_slot_held) {
                    voice_name.* = .{ .generation = voice_name.generation +% 1 };
                }
            }
            for (&engine_mixer.samples_registry) |*record| {
                if (record.release_allocator) |release_allocator| {
                    release_allocator.free(record.samples);
                }
                record.* = .{};
            }
            // Commands and notes not yet forwarded are dropped with the renderer they were for.
            while (engine_mixer.renderer_queues.commands.pop()) |_| {}
            while (engine_mixer.renderer_queues.notes.pop()) |_| {}
        }

        pub fn isStarted(engine_mixer: *const Mixer) bool {
            return engine_mixer.output != null;
        }

        /// How many slots the renderer holds: voices playing or paused, and stopped voices still fading.
        pub fn playingVoiceCount(engine_mixer: *const Mixer) u32 {
            var held_slot_count: u32 = 0;
            for (engine_mixer.voice_names) |voice_name| {
                if (voice_name.is_slot_held) {
                    held_slot_count += 1;
                }
            }
            return held_slot_count;
        }

        /// Starts a voice playing `source`, at its volume, pan and pitch (`options`), and returns its name;
        /// `Voice.none` when it cannot play - a source that could not sound, every slot held, every samples id in use.
        /// The voice is named at once; the renderer starts it in its next block.
        pub fn play(engine_mixer: *Mixer, source: Source, options: PlayOptions) Voice {
            if (!isPlayable(source)) {
                return .none;
            }
            // A stream's ring is read where it lies, natively; to a renderer with a memory of its own - the page's
            // audio worklet, the commands forwarded to it - the stream goes by a number, its frames sent after it.
            const is_stream: bool = source == .stream;
            const forwarded_stream_id: ?ForwardedStreamId = if (is_stream and engine_mixer.forwarding != null)
                engine_mixer.freeForwardedStreamId(source.stream.ring) orelse return .none
            else
                null;
            const slot_index: usize = engine_mixer.firstFreeSlotIndex() orelse return .none;
            // Samples are named by their id: registered the first time they play.
            const samples_id: ?SamplesId = switch (source) {
                .samples => |sample_source| engine_mixer.samplesIdOf(sample_source.samples) orelse
                    engine_mixer.registerSamples(sample_source.samples) orelse {
                    std.log.scoped(.mixer).warn("no sound plays: every one of the {d} ids for samples is in use", .{
                        samples_registry_capacity,
                    });
                    return .none;
                },
                .generator, .stream => null,
            };
            const voice_name: *VoiceNameRecord = &engine_mixer.voice_names[slot_index];
            voice_name.* = .{ .generation = voice_name.generation, .is_slot_held = true, .is_name_live = true };
            const voice: Voice = .ofSlot(slot_index, voice_name.generation);
            var voice_to_start: VoiceToStart = voiceToStartOf(voice, source, samples_id, options);
            voice_to_start.requested_at_ms = engine_mixer.clockMilliseconds();
            if (forwarded_stream_id) |stream_id| {
                const ring: *StreamRing = source.stream.ring;
                const generation: u8 = engine_mixer.forwarded_stream_generations[stream_id] +% 1;
                engine_mixer.forwarded_stream_generations[stream_id] = generation;
                voice_to_start.source = .{ .forwarded_stream = .{
                    .id = stream_id,
                    .generation = generation,
                    .channels = ring.channels,
                    .sample_rate = ring.sample_rate,
                } };
                const first_frame: usize = ring.reading_side.read_frames.load(.acquire);
                engine_mixer.forwarded_streams[stream_id] = .{
                    .ring = ring,
                    .voice = voice,
                    .generation = generation,
                    .first_frame = first_frame,
                    .forwarded_frames = first_frame,
                    .read_frames = first_frame,
                };
            }
            const is_sent: bool = engine_mixer.sendToRenderer(.{ .play = voice_to_start });
            if (!is_sent) {
                // The renderer takes no commands: the name is given back, and nothing plays.
                voice_name.* = .{ .generation = voice_name.generation };
                if (forwarded_stream_id) |stream_id| {
                    engine_mixer.forwarded_streams[stream_id] = .{};
                }
                return .none;
            }
            return voice;
        }

        /// A number for a stream to forward, its ring `ring`: the first free; null - said why - when the platform does
        /// not carry a stream's frames yet, the ring is larger than the other side's (`RendererHost.HostStreamRing`),
        /// or every number is in use.
        fn freeForwardedStreamId(engine_mixer: *const Mixer, ring: *const StreamRing) ?ForwardedStreamId {
            if (engine_mixer.forwarding.?.send_stream_frames == null) {
                std.log.scoped(.mixer).warn("this platform does not carry a stream's frames to its renderer yet", .{});
                return null;
            }
            if (ring.capacity_frames > RendererHost.host_stream_ring_frames) {
                std.log.scoped(.mixer).warn("a stream's ring of {d} frames is more than the renderer's holds", .{
                    ring.capacity_frames,
                });
                return null;
            }
            // A ring has one reader: a second voice on a ring forwarded already would move its read position as well.
            for (engine_mixer.forwarded_streams) |record| {
                if (record.ring == ring) {
                    std.log.scoped(.mixer).warn("a stream's ring is played by one voice at a time", .{});
                    return null;
                }
            }
            for (engine_mixer.forwarded_streams, 0..) |record, stream_index| {
                if (record.ring == null) {
                    return @intCast(stream_index);
                }
            }
            std.log.scoped(.mixer).warn("no stream plays: every one of the {d} streams forwarded is in use", .{
                forwarded_stream_capacity,
            });
            return null;
        }

        /// The other side's report on a forwarded stream (`StreamRead`): its frames read move the game's ring on - the
        /// count carried in 32 bits, wrapping, widened by its change since the last - and its frames wanted and missing
        /// are counted on the game's ring, as a voice reading it here would count them. A report on a number given up
        /// since, or on its stream before - another generation - is late, and dropped.
        fn acceptStreamRead(engine_mixer: *Mixer, stream_read: StreamRead) void {
            const record: *ForwardedStreamRecord = &engine_mixer.forwarded_streams[stream_read.id];
            const ring: *StreamRing = record.ring orelse return;
            if (stream_read.generation != record.generation) {
                return;
            }
            // The host counts from its ring's start, which is this ring's `first_frame`.
            const last_read_low_bits: u32 = @truncate(record.read_frames -% record.first_frame);
            const newly_read_frames: u32 = stream_read.read_frames -% last_read_low_bits;
            // Never past what was sent: the read position passing the written one would make the ring's room negative.
            const unread_sent_frames: usize = record.forwarded_frames -% record.read_frames;
            record.read_frames +%= @min(newly_read_frames, unread_sent_frames);
            ring.reading_side.read_frames.store(record.read_frames, .release);
            _ = ring.reading_side.dry_frames.fetchAdd(stream_read.dry_frames, .monotonic);
        }

        /// The voice in slot `slot_index` has ended: if it played a forwarded stream, the number is given up, and the
        /// other side told to free its ring. Its voice has ended there too, so nothing reads that ring any more.
        fn releaseForwardedStreamOfSlot(engine_mixer: *Mixer, slot_index: usize) void {
            for (&engine_mixer.forwarded_streams, 0..) |*record, stream_index| {
                if (record.ring == null or record.voice.slotIndex() != slot_index) {
                    continue;
                }
                record.* = .{};
                _ = engine_mixer.sendToRenderer(.{ .release_stream = @intCast(stream_index) });
            }
        }

        /// Sends each forwarded stream's frames written since the last sent - the ring wrapping, in two pieces - and
        /// counts them sent. They stay in the game's ring until the other side reports them read.
        fn forwardStreamFrames(engine_mixer: *Mixer) void {
            const SendStreamFrames = *const fn (u8, u8, u32, []const f32) void;
            const send_stream_frames: SendStreamFrames = engine_mixer.forwarding.?.send_stream_frames orelse return;
            for (&engine_mixer.forwarded_streams, 0..) |*record, stream_index| {
                const ring: *StreamRing = record.ring orelse continue;
                const written_frames: usize = ring.writing_side.written_frames.load(.acquire);
                const unsent_frames: usize = written_frames -% record.forwarded_frames;
                if (unsent_frames == 0) {
                    continue;
                }
                const unsent_samples: usize = unsent_frames * ring.channels;
                const pieces: StreamRing.RunPieces = ring.piecesOfRun(record.forwarded_frames, unsent_samples);
                const stream_id: u8 = @intCast(stream_index);
                send_stream_frames(stream_id, ring.channels, ring.sample_rate, pieces.before_end);
                if (pieces.from_start.len > 0) {
                    send_stream_frames(stream_id, ring.channels, ring.sample_rate, pieces.from_start);
                }
                record.forwarded_frames = written_frames;
            }
        }

        /// Whether `source` could sound: a sample source needs channels and a rate - with no channels there are no
        /// frames to count, and with no rate it would never move on - and a generator's state must fit in a voice.
        fn isPlayable(source: Source) bool {
            switch (source) {
                .samples => |sample_source| {
                    const has_channels: bool = sample_source.channels != 0;
                    const has_rate: bool = sample_source.sample_rate != 0;
                    return has_channels and has_rate;
                },
                .generator => |generator| {
                    const state_length: usize = generator.initial_state.len;
                    const does_state_fit: bool = state_length <= generator_state_capacity;
                    if (!does_state_fit) {
                        std.log.scoped(.mixer).warn("a generator's state of {d} bytes is more than a voice holds", .{
                            state_length,
                        });
                    }
                    return does_state_fit;
                },
                .stream => |stream| {
                    const ring: *const StreamRing = stream.ring;
                    const has_mono_or_stereo: bool = ring.channels == 1 or ring.channels == 2;
                    return has_mono_or_stereo and ring.sample_rate != 0;
                },
            }
        }

        /// The first of the main side's slots - those below `first_instrument_slot` - that the renderer does not hold;
        /// null when it holds them all.
        fn firstFreeSlotIndex(engine_mixer: *const Mixer) ?usize {
            const main_side_names: []const VoiceNameRecord = engine_mixer.voice_names[0..first_instrument_slot];
            for (main_side_names, 0..) |voice_name, slot_index| {
                if (!voice_name.is_slot_held) {
                    return slot_index;
                }
            }
            return null;
        }

        /// The play command for `voice`: its source as a command carries it - samples by their id, a generator by its
        /// function - its options, and a generator's state, copied in here so that the caller's may go at once.
        fn voiceToStartOf(
            voice: Voice,
            source: Source,
            samples_id: ?SamplesId,
            options: PlayOptions,
        ) VoiceToStart {
            const source_to_start: SourceToStart = switch (source) {
                .samples => |sample_source| .{ .samples = .{
                    .samples_id = samples_id.?,
                    .channels = sample_source.channels,
                    .sample_rate = sample_source.sample_rate,
                    .is_looping = sample_source.is_looping,
                } },
                .generator => |generator| .{ .generator = .{
                    .generate = generator.generate,
                    .channels = generator.channels,
                } },
                .stream => |stream| .{ .stream = stream.ring },
            };
            var voice_to_start: VoiceToStart = .{ .voice = voice, .source = source_to_start, .options = options };
            switch (source) {
                .generator => |generator| {
                    const state_length: usize = generator.initial_state.len;
                    const state_room: []u8 = voice_to_start.generator_state[0..state_length];
                    @memcpy(state_room, generator.initial_state);
                },
                .samples, .stream => {},
            }
            return voice_to_start;
        }

        /// The record kept for `voice`, while it names a live voice; null for a name that has died, or `Voice.none`.
        fn voiceNameOf(engine_mixer: *Mixer, voice: Voice) ?*VoiceNameRecord {
            if (voice == .none) {
                return null;
            }
            const slot_index: usize = voice.slotIndex();
            const voice_name: *VoiceNameRecord = &engine_mixer.voice_names[slot_index];
            const is_same_generation: bool = voice_name.generation == voice.generation();
            const is_live_voice: bool = voice_name.is_name_live and is_same_generation;
            return if (is_live_voice) voice_name else null;
        }

        /// Whether `voice` still plays (or is paused). The answer comes from the names kept here, so a sound that
        /// finished by itself is still reported playing until the renderer's notice is read, at the next frame.
        pub fn isPlaying(engine_mixer: *Mixer, voice: Voice) bool {
            return engine_mixer.voiceNameOf(voice) != null;
        }

        /// Whether the renderer may still be reading `voice`'s source, a voice the app has stopped: the name died at
        /// once (`stopVoice`), but the renderer fades the voice out first, and holds its slot until its notice that the
        /// voice ended. The stop moved the slot's generation one past the voice's; the notice clears the hold and keeps
        /// the generation; a new voice in the slot takes a live name. So the stopped voice is still held exactly while
        /// the slot is held, its name dead, and its generation one past the voice's - and once its source is read no
        /// more, the memory under it can be given back.
        pub fn isStoppedVoiceStillHeld(engine_mixer: *const Mixer, voice: Voice) bool {
            const voice_name: VoiceNameRecord = engine_mixer.voice_names[voice.slotIndex()];
            const generation_after_stop: u24 = voice.generation() +% 1;
            const is_same_dead_name: bool = !voice_name.is_name_live and voice_name.generation == generation_after_stop;
            return voice_name.is_slot_held and is_same_dead_name;
        }

        /// Stops a voice. Its name dies at once - `isPlaying` says false, and the setters reach nothing - while the
        /// renderer fades it out over `fade_out_frames` and then frees its slot.
        pub fn stopVoice(engine_mixer: *Mixer, voice: Voice) void {
            const voice_name: *VoiceNameRecord = engine_mixer.voiceNameOf(voice) orelse return;
            voice_name.is_name_live = false;
            voice_name.is_paused = false;
            voice_name.generation +%= 1;
            _ = engine_mixer.sendToRenderer(.{ .stop = voice });
        }

        /// The voice's volume: 1 as recorded, 0 silent, above 1 louder. Heard from the renderer's next block, ramped
        /// over it rather than jumping.
        pub fn setVolume(engine_mixer: *Mixer, voice: Voice, volume: f32) void {
            if (engine_mixer.voiceNameOf(voice) == null) {
                return;
            }
            const volume_change: VoiceParameterChange = .{ .voice = voice, .value = volume };
            _ = engine_mixer.sendToRenderer(.{ .set_volume = volume_change });
        }

        /// The voice's pan: -1 full left, 0 centre, 1 full right (`gainsForPan`). Heard from the renderer's next block,
        /// ramped over it.
        pub fn setPan(engine_mixer: *Mixer, voice: Voice, pan: f32) void {
            if (engine_mixer.voiceNameOf(voice) == null) {
                return;
            }
            const pan_change: VoiceParameterChange = .{ .voice = voice, .value = pan };
            _ = engine_mixer.sendToRenderer(.{ .set_pan = pan_change });
        }

        /// The voice's pitch: how fast its source is read - 1 as recorded, 2 twice as fast and an octave up, 0.5 an
        /// octave down. From the renderer's next block on.
        pub fn setPitch(engine_mixer: *Mixer, voice: Voice, pitch: f32) void {
            if (engine_mixer.voiceNameOf(voice) == null) {
                return;
            }
            const pitch_change: VoiceParameterChange = .{ .voice = voice, .value = pitch };
            _ = engine_mixer.sendToRenderer(.{ .set_pitch = pitch_change });
        }

        /// Whether a voice's sample source loops, from the renderer's next block on: a loop plays from its end back to
        /// its start without a gap. A generator has no end, and is unchanged.
        pub fn setLooping(engine_mixer: *Mixer, voice: Voice, is_looping: bool) void {
            if (engine_mixer.voiceNameOf(voice) == null) {
                return;
            }
            const looping_change: VoiceLoopingChange = .{ .voice = voice, .is_looping = is_looping };
            _ = engine_mixer.sendToRenderer(.{ .set_looping = looping_change });
        }

        /// Pauses a voice where it is: the renderer fades it out over `fade_out_frames` and keeps its place, for
        /// `resumeVoice`. `isPaused` says true at once.
        pub fn pauseVoice(engine_mixer: *Mixer, voice: Voice) void {
            const voice_name: *VoiceNameRecord = engine_mixer.voiceNameOf(voice) orelse return;
            voice_name.is_paused = true;
            _ = engine_mixer.sendToRenderer(.{ .pause = voice });
        }

        /// Resumes a paused voice where it fell silent, from the renderer's next block.
        pub fn resumeVoice(engine_mixer: *Mixer, voice: Voice) void {
            const voice_name: *VoiceNameRecord = engine_mixer.voiceNameOf(voice) orelse return;
            voice_name.is_paused = false;
            _ = engine_mixer.sendToRenderer(.{ .resume_voice = voice });
        }

        pub fn isPaused(engine_mixer: *Mixer, voice: Voice) bool {
            const voice_name: *VoiceNameRecord = engine_mixer.voiceNameOf(voice) orelse return false;
            return voice_name.is_paused;
        }

        /// Every mixed sample is multiplied by `volume`, from the renderer's next block on: the volume of all the sound
        /// at once.
        pub fn setMasterVolume(engine_mixer: *Mixer, volume: f32) void {
            engine_mixer.master_volume = volume;
            _ = engine_mixer.sendToRenderer(.{ .set_master_volume = volume });
        }

        /// Sets what the notes play (`Instrument`), from the renderer's next block; notes sounding then end.
        pub fn setInstrument(engine_mixer: *Mixer, instrument: Instrument) void {
            _ = engine_mixer.sendToRenderer(.{ .set_instrument = instrument });
        }

        /// Sends a key's event to the instrument, from the main thread; the renderer applies it at its next block,
        /// before mixing. False when the queue is full, which takes a player pressing 256 keys between two blocks.
        pub fn sendNote(engine_mixer: *Mixer, note_event: NoteEvent) bool {
            var stamped_note: NoteEvent = note_event;
            if (stamped_note.requested_at_ms == 0) {
                stamped_note.requested_at_ms = engine_mixer.clockMilliseconds();
            }
            // The queue - 256 events - fills as the commands' does, and is met the same way (`sendToRenderer`):
            // forwarding, this side's backlog is forwarded at once; with the renderer on this thread, the events
            // waiting are applied here; with it on an audio thread, this side waits for room, then drops the event,
            // saying so. A key's release must not be lost quietly: its note would sound on.
            const note_queue: *NoteQueue = &engine_mixer.renderer_queues.notes;
            if (note_queue.push(stamped_note)) {
                engine_mixer.has_renderer_stalled = false;
                return true;
            }
            if (engine_mixer.forwarding != null) {
                engine_mixer.forwardToOtherMemory();
                const is_sent: bool = note_queue.push(stamped_note);
                assertf(is_sent, @src(), "sound: the note queue full after forwarding its backlog", .{});
                return true;
            }
            if (!engine_mixer.is_renderer_on_another_thread) {
                engine_mixer.renderer.applyNotes(&engine_mixer.renderer_queues);
                const is_sent: bool = note_queue.push(stamped_note);
                assertf(is_sent, @src(), "sound: the note queue full after applying its notes", .{});
                return true;
            }
            if (engine_mixer.waitForRenderer(NoteQueue, note_queue, stamped_note)) {
                return true;
            }
            std.log.scoped(.mixer).err("the audio thread takes no notes: key {d} was dropped", .{stamped_note.key});
            return false;
        }

        /// The output's clock now (`Output.clock_ms`); 0 before the output starts, which no measurement uses.
        fn clockMilliseconds(engine_mixer: *const Mixer) f64 {
            const output: Output = engine_mixer.output orelse return 0;
            return output.clock_ms();
        }

        /// The latest measured starts, newest first, copied into `out_samples` - as many as it holds, up to the
        /// `recent_start_capacity` kept - and the part of it filled.
        pub fn recentStarts(engine_mixer: *const Mixer, out_samples: []LatencySample) []LatencySample {
            const kept_count: usize = @min(engine_mixer.recent_start_count, recent_start_capacity);
            const copied_count: usize = @min(kept_count, out_samples.len);
            for (0..copied_count) |newest_offset| {
                const ring_index: usize = (engine_mixer.recent_start_count - 1 - newest_offset) % recent_start_capacity;
                out_samples[newest_offset] = engine_mixer.recent_starts[ring_index];
            }
            return out_samples[0..copied_count];
        }

        /// What lies past the output's queue, in milliseconds, as the platform can tell (`Output.latency_ms`); 0
        /// before the output starts.
        pub fn outputLatencyMilliseconds(engine_mixer: *const Mixer) f64 {
            const output: Output = engine_mixer.output orelse return 0;
            return output.latency_ms();
        }

        /// The output's name: which of the platform's paths plays (`Output.name`).
        pub fn outputName(engine_mixer: *const Mixer) []const u8 {
            const output: Output = engine_mixer.output orelse return "no output";
            return output.name();
        }

        /// The latency readout's header, above its lines (`formatLatencyLine`), in milliseconds.
        pub const latency_readout_header: []const u8 = "       frame    wait  queued    past   total  (ms)";

        /// One measured start as a line of the latency readout, under `latency_readout_header`:
        ///
        ///            frame    wait  queued    past   total  (ms)
        ///     note      8.3     0.9    10.0    43.4    62.6
        ///
        /// `frame` is the wait from the press to the request, `t1` - the frame's wait before the app asked - when the
        /// start carries its press's time (`NoteEvent.pressed_at_ms`, `PlayOptions.pressed_at_ms`), a dash when it
        /// does not; `wait` the wait for the renderer, `t2` (requested to applied); `queued` the sound ahead of it in
        /// the output's queue, `t3` (applied to its first frame out); `past` what lies past the queue as the platform
        /// reports it now (`outputLatencyMilliseconds`, `t4` - on a page the browser's `baseLatency` and
        /// `outputLatency`); `total` their sum - the whole lag, from the press when it is known, but whatever the
        /// platform cannot report. A headless run renders after the fact, so its `queued` reads negative, by up to a
        /// frame.
        pub fn formatLatencyLine(
            latency_sample: LatencySample,
            past_output_ms: f64,
            line_buffer: []u8,
        ) []const u8 {
            const wait_ms: f64 = latency_sample.applied_at_ms - latency_sample.requested_at_ms;
            const queued_ms: f64 = latency_sample.first_frame_out_ms - latency_sample.applied_at_ms;
            const is_press_known: bool = latency_sample.pressed_at_ms > 0;
            if (!is_press_known) {
                const total_ms: f64 = wait_ms + queued_ms + past_output_ms;
                return bufPrint(line_buffer, "{t:<5}      -  {d:>6.1}  {d:>6.1}  {d:>6.1}  {d:>6.1}", .{
                    latency_sample.kind,
                    wait_ms,
                    queued_ms,
                    past_output_ms,
                    total_ms,
                }) catch line_buffer[0..0];
            }
            const frame_ms: f64 = latency_sample.requested_at_ms - latency_sample.pressed_at_ms;
            const total_ms: f64 = frame_ms + wait_ms + queued_ms + past_output_ms;
            return bufPrint(line_buffer, "{t:<5} {d:>6.1}  {d:>6.1}  {d:>6.1}  {d:>6.1}  {d:>6.1}", .{
                latency_sample.kind,
                frame_ms,
                wait_ms,
                queued_ms,
                past_output_ms,
                total_ms,
            }) catch line_buffer[0..0];
        }

        /// The same, from the one thread that reads the keyboard as its keys move (a platform's input thread): its
        /// own queue, since the main thread writes the other. No other thread may call it.
        pub fn sendNoteFromInputThread(engine_mixer: *Mixer, note_event: NoteEvent) bool {
            return engine_mixer.renderer_queues.input_thread_notes.push(note_event);
        }

        /// The id `samples` is registered under; null when it is not registered, or is being released. A buffer is the
        /// very same one when it starts at the same address and has the same length - two buffers holding equal
        /// samples are two buffers.
        pub fn samplesIdOf(engine_mixer: *const Mixer, samples: []const f32) ?SamplesId {
            for (engine_mixer.samples_registry, 0..) |record, samples_index| {
                const is_same_buffer: bool = record.samples.ptr == samples.ptr and record.samples.len == samples.len;
                const is_playable_record: bool = record.is_registered and record.release_allocator == null;
                if (is_playable_record and is_same_buffer) {
                    return @intCast(samples_index);
                }
            }
            return null;
        }

        /// Whether `samples` - the very buffer - was released, and the renderer has not yet said it let it go.
        fn isBeingReleased(engine_mixer: *const Mixer, samples: []const f32) bool {
            for (engine_mixer.samples_registry) |record| {
                const is_same_buffer: bool = record.samples.ptr == samples.ptr and record.samples.len == samples.len;
                const is_release_pending: bool = record.is_registered and record.release_allocator != null;
                if (is_release_pending and is_same_buffer) {
                    return true;
                }
            }
            return false;
        }

        /// Registers `samples` under a free id, telling the renderer; null when every id is in use, or the renderer
        /// takes no commands.
        fn registerSamples(engine_mixer: *Mixer, samples: []const f32) ?SamplesId {
            for (&engine_mixer.samples_registry, 0..) |*record, samples_index| {
                if (record.is_registered) {
                    continue;
                }
                const samples_id: SamplesId = @intCast(samples_index);
                const samples_to_register: SamplesToRegister = .{ .samples_id = samples_id, .samples = samples };
                const is_sent: bool = engine_mixer.sendToRenderer(.{ .register_samples = samples_to_register });
                if (!is_sent) {
                    return null;
                }
                record.* = .{ .samples = samples, .is_registered = true };
                return samples_id;
            }
            return null;
        }

        /// Frees `samples`, allocated by `allocator`, once nothing reads them. Samples never played were never
        /// registered, and go at once. Otherwise every voice playing them - a sound's and its aliases' - first copies
        /// what it still needs and fades out over the copy (`Renderer.fadeVoicesReading`), their id leaves the
        /// registry, and the renderer says so. With the renderer on this thread all of that happens here, before the
        /// call returns; with it on an audio thread, at its next block, and the samples are freed when this side reads
        /// its notice (`readRendererNotices`, each frame). Releasing a buffer twice is a mistake, as freeing it twice
        /// is, and is caught.
        pub fn releaseSamples(
            engine_mixer: *Mixer,
            allocator: Allocator,
            samples: []const f32,
        ) void {
            const samples_id: SamplesId = engine_mixer.samplesIdOf(samples) orelse {
                // Not registered: never played - or already released, which would free it a second time at the notice.
                const is_released_twice: bool = engine_mixer.isBeingReleased(samples);
                assert(!is_released_twice, @src());
                allocator.free(samples);
                return;
            };
            const record: *RegisteredSamplesRecord = &engine_mixer.samples_registry[samples_id];
            record.release_allocator = allocator;
            const is_sent: bool = engine_mixer.sendToRenderer(.{ .release_samples = samples_id });
            if (!is_sent) {
                // The audio thread takes no commands: it reads nothing either, and the samples can go now.
                allocator.free(samples);
                record.* = .{};
                return;
            }
            if (!engine_mixer.is_renderer_on_another_thread) {
                engine_mixer.renderer.applyCommands(&engine_mixer.renderer_queues);
                engine_mixer.readRendererNotices();
            }
        }

        /// Waits for room in `queue` - the renderer on an audio thread empties it at every block - and pushes `item`
        /// there: a million yields at most, longer than any device's block. A renderer that took nothing for a whole
        /// wait has stalled - its device lost, say - and the sends after are not held up by it again, each a second of
        /// the game's: they drop at once, until one finds room (`has_renderer_stalled`). False when `item` was not
        /// pushed.
        fn waitForRenderer(
            engine_mixer: *Mixer,
            comptime Queue: type,
            queue: *Queue,
            item: Queue.Element,
        ) bool {
            if (engine_mixer.has_renderer_stalled) {
                return false;
            }
            const most_attempts: u32 = 1_000_000;
            var attempt_count: u32 = 0;
            while (attempt_count < most_attempts) : (attempt_count += 1) {
                yieldThisThread();
                if (queue.push(item)) {
                    return true;
                }
            }
            engine_mixer.has_renderer_stalled = true;
            return false;
        }

        /// Sends a command to the renderer; false when it could not be sent. The queue fills only when commands of
        /// many frames wait unapplied. With the renderer on this thread, this side applies them itself, here. With it
        /// on an audio thread, which empties the queue at every block, a full queue means that thread is late: this
        /// side waits for room - a million yields at most, longer than any device's block - and then drops the
        /// command, saying so.
        fn sendToRenderer(engine_mixer: *Mixer, renderer_command: RendererCommand) bool {
            const command_queue: *RendererCommandQueue = &engine_mixer.renderer_queues.commands;
            if (command_queue.push(renderer_command)) {
                engine_mixer.has_renderer_stalled = false;
                return true;
            }
            // Forwarding, a full queue is this side's own backlog: forwarded now, it has room again.
            if (engine_mixer.forwarding != null) {
                engine_mixer.forwardToOtherMemory();
                const is_sent: bool = command_queue.push(renderer_command);
                assertf(is_sent, @src(), "sound: the command queue full after forwarding its backlog", .{});
                return true;
            }
            if (!engine_mixer.is_renderer_on_another_thread) {
                engine_mixer.renderer.applyCommands(&engine_mixer.renderer_queues);
                const is_sent: bool = command_queue.push(renderer_command);
                assertf(is_sent, @src(), "sound: the command queue full after applying its commands", .{});
                return true;
            }
            if (engine_mixer.waitForRenderer(RendererCommandQueue, command_queue, renderer_command)) {
                return true;
            }
            std.log.scoped(.mixer).err("the audio thread takes no commands: a {t} was dropped", .{renderer_command});
            return false;
        }

        /// Reads the renderer's measurements of starts, keeping the latest (`recentStarts`), then its notices. A voice
        /// ended frees its slot for the next play; and a voice that ended by
        /// itself - its sound finished, `stopVoice` never called - also has its name die here, so `isPlaying` says
        /// false from now on. A release of samples frees them: no voice reads them any more.
        fn readRendererNotices(engine_mixer: *Mixer) void {
            while (engine_mixer.renderer_queues.latency.pop()) |latency_sample| {
                engine_mixer.keepRecentStart(latency_sample);
            }
            const notice_queue: *RendererNoticeQueue = &engine_mixer.renderer_queues.notices;
            while (notice_queue.pop()) |renderer_notice| {
                switch (renderer_notice) {
                    .voice_ended => |slot_index| {
                        const voice_name: *VoiceNameRecord = &engine_mixer.voice_names[slot_index];
                        const has_ended_by_itself: bool = voice_name.is_name_live;
                        if (has_ended_by_itself) {
                            voice_name.generation +%= 1;
                        }
                        voice_name.* = .{ .generation = voice_name.generation };
                        engine_mixer.releaseForwardedStreamOfSlot(slot_index);
                    },
                    .samples_released => |samples_id| {
                        const record: *RegisteredSamplesRecord = &engine_mixer.samples_registry[samples_id];
                        if (record.release_allocator) |release_allocator| {
                            release_allocator.free(record.samples);
                        }
                        record.* = .{};
                    },
                    .stream_read => |stream_read| engine_mixer.acceptStreamRead(stream_read),
                    .start_measured => |latency_sample| engine_mixer.keepRecentStart(latency_sample),
                }
            }
        }

        /// Keeps a measured start among the recent ones the readout shows (`recentStarts`), the oldest kept giving way.
        fn keepRecentStart(engine_mixer: *Mixer, latency_sample: LatencySample) void {
            const ring_index: usize = engine_mixer.recent_start_count % recent_start_capacity;
            engine_mixer.recent_starts[ring_index] = latency_sample;
            engine_mixer.recent_start_count += 1;
        }

        /// Renders the frames an output that pulls asks for (`contract.AudioRenderCallback`), in blocks no larger than
        /// the renderer's scratch room: a device may ask for more at once - after a long stall, say.
        fn renderForPullingOutput(
            context: *anyopaque,
            samples: []f32,
            timing: contract.AudioRenderTiming,
        ) void {
            const engine_mixer: *Mixer = @ptrCast(@alignCast(context));
            const largest_block_sample_count: usize = engine_mixer.renderer.voice_scratch_samples.len;
            const milliseconds_per_sample: f64 = 1000.0 / float64(@as(u32, sample_rate) * channel_count);
            var first_sample: usize = 0;
            while (first_sample < samples.len) {
                const samples_left: usize = samples.len - first_sample;
                const block_sample_count: usize = @min(samples_left, largest_block_sample_count);
                const block: []f32 = samples[first_sample..][0..block_sample_count];
                // Each block is heard after the ones before it in the same request.
                const block_out_ms: f64 = timing.first_frame_out_ms + float64(first_sample) * milliseconds_per_sample;
                engine_mixer.renderer.current_block_timing = .{
                    .asked_at_ms = timing.asked_at_ms,
                    .first_frame_out_ms = block_out_ms,
                };
                engine_mixer.renderer.render(&engine_mixer.renderer_queues, block);
                first_sample += block_sample_count;
            }
            engine_mixer.renderer.current_block_timing = null;
        }

        /// Renders `mix_block` on this thread and reads the notices: for an output that is not running, and for tests.
        pub fn mixInto(engine_mixer: *Mixer, mix_block: []f32) void {
            engine_mixer.renderer.render(&engine_mixer.renderer_queues, mix_block);
            engine_mixer.readRendererNotices();
        }

        /// Once a frame, after the app's update. The renderer is asked for its blocks by the output itself, as the
        /// device needs them, so the frame only exchanges what the two sides have for each other: forwarding, it sends
        /// the frame's commands, registrations and notes to the renderer in the other memory and takes the notices
        /// that came back; pulled, it reads the renderer's notices - a voice ended, samples let go.
        pub fn mixFrame(engine_mixer: *Mixer) void {
            if (engine_mixer.output == null) {
                return;
            }
            if (engine_mixer.forwarding != null) {
                engine_mixer.forwardToOtherMemory();
                return;
            }
            engine_mixer.readRendererNotices();
        }

        /// Forwards everything waiting to the renderer in the other memory (`forwardCommands`, through the output's
        /// sink), then takes the notices it sent back and reads them as any renderer's.
        fn forwardToOtherMemory(engine_mixer: *Mixer) void {
            const command_sink: CommandSink = .{
                .context = engine_mixer,
                .send_command_bytes = &forwardedCommandBytes,
                .send_samples = &forwardedSamples,
                .send_note = &forwardedNote,
            };
            forwardCommands(engine_mixer, command_sink);
            engine_mixer.sendForwardBatch();
            engine_mixer.forwardStreamFrames();
            const forwarding: ForwardingOutput = engine_mixer.forwarding.?;
            var notice_bytes: [64 * @sizeOf(RendererNotice)]u8 = undefined;
            while (true) {
                const byte_count: usize = forwarding.take_notice_bytes(&notice_bytes, @sizeOf(RendererNotice));
                if (byte_count == 0) {
                    break;
                }
                acceptNoticeBytes(engine_mixer, notice_bytes[0..byte_count]);
            }
            engine_mixer.readRendererNotices();
        }

        /// Sends the commands gathered (`forward_batch`) as one message, and empties the batch.
        fn sendForwardBatch(engine_mixer: *Mixer) void {
            if (engine_mixer.forward_batch_length == 0) {
                return;
            }
            const gathered_bytes: []const u8 = engine_mixer.forward_batch[0..engine_mixer.forward_batch_length];
            engine_mixer.forwarding.?.send_command_bytes(gathered_bytes);
            engine_mixer.forward_batch_length = 0;
        }

        /// A command to forward: gathered with the frame's others, the batch sent first when it has no room.
        fn forwardedCommandBytes(context: *anyopaque, command_bytes: []const u8) void {
            const engine_mixer: *Mixer = @ptrCast(@alignCast(context));
            const room_bytes: usize = engine_mixer.forward_batch.len - engine_mixer.forward_batch_length;
            if (room_bytes < command_bytes.len) {
                engine_mixer.sendForwardBatch();
            }
            const batch_end: usize = engine_mixer.forward_batch_length + command_bytes.len;
            @memcpy(engine_mixer.forward_batch[engine_mixer.forward_batch_length..batch_end], command_bytes);
            engine_mixer.forward_batch_length = batch_end;
        }

        fn forwardedSamples(
            context: *anyopaque,
            samples_id: SamplesId,
            samples: []const f32,
        ) void {
            const engine_mixer: *Mixer = @ptrCast(@alignCast(context));
            // What was gathered goes first, so that the other side meets everything in the order it was sent.
            engine_mixer.sendForwardBatch();
            engine_mixer.forwarding.?.send_samples(samples_id, samples);
        }

        fn forwardedNote(context: *anyopaque, note_event: NoteEvent) void {
            const engine_mixer: *Mixer = @ptrCast(@alignCast(context));
            // A note after its frame's commands - after `setInstrument`, say - as it was sent.
            engine_mixer.sendForwardBatch();
            engine_mixer.forwarding.?.send_note(
                note_event.key,
                note_event.is_down,
                note_event.velocity,
                note_event.requested_at_ms,
                note_event.pressed_at_ms,
            );
        }
    };

    /// Reads a voice's next frames from its source into `voice_samples` - interleaved stereo, at the mixer's rate,
    /// before the voice's gains are applied - and returns how many frames it read: as many as asked for, or fewer when
    /// a sample buffer that does not loop reaches its end. A generator makes its frames itself: it is handed its state,
    /// the block to fill, and the index of the block's first frame since the voice started, so that a tone, say, can
    /// work out its phase from where it is.
    fn readVoiceSource(voice_slot: *VoiceSlot, voice_samples: []f32) usize {
        const frames_wanted: usize = voice_samples.len / channel_count;
        switch (voice_slot.source) {
            .generator => |generator| {
                const first_frame_index: u64 = voice_slot.generated_frame_count;
                generator.generate(&voice_slot.generator_state, voice_samples, first_frame_index);
                voice_slot.generated_frame_count += frames_wanted;
                return frames_wanted;
            },
            .samples => |sample_source| return readSampleSource(voice_slot, sample_source, voice_samples),
            .stream => |stream| return readStreamSource(voice_slot, stream, voice_samples),
        }
    }

    /// The most frames a stream voice reads from its ring at a time (`StreamPuller`): enough that the ring's counters
    /// are loaded and stored once a run rather than once a frame, few enough to sit on the stack.
    const stream_chunk_frames: usize = 64;

    /// A stream voice's frames, taken one at a time from its ring: read in chunks, each as large as what is still to
    /// be taken this block allows - never more, so that no frame is read out of the ring and then left unplayed when
    /// the block ends. A frame the ring did not have - it ran dry - is silence; the ring counts it.
    const StreamPuller = struct {
        ring: *StreamRing,
        /// Frames still to take this block, the chunk's included.
        frames_left_to_take: usize,
        chunk: [stream_chunk_frames * channel_count]f32 = undefined,
        chunk_frame_count: usize = 0,
        next_chunk_frame: usize = 0,

        /// The next frame, left and right: a mono stream's one sample twice.
        fn take(puller: *StreamPuller) [channel_count]f32 {
            if (puller.next_chunk_frame == puller.chunk_frame_count) {
                puller.refill();
            }
            const ring_channels: usize = puller.ring.channels;
            const first_sample_index: usize = puller.next_chunk_frame * ring_channels;
            const right_channel_offset: usize = if (ring_channels > 1) 1 else 0;
            const frame: [channel_count]f32 = .{
                puller.chunk[first_sample_index],
                puller.chunk[first_sample_index + right_channel_offset],
            };
            puller.next_chunk_frame += 1;
            puller.frames_left_to_take -= 1;
            return frame;
        }

        /// Reads the next chunk from the ring: as many frames as are still to take, up to a chunk's room. What the
        /// ring did not have is filled with silence.
        fn refill(puller: *StreamPuller) void {
            const ring_channels: usize = puller.ring.channels;
            const wanted_frames: usize = @min(puller.frames_left_to_take, stream_chunk_frames);
            const wanted_samples: []f32 = puller.chunk[0 .. wanted_frames * ring_channels];
            const read_frames: usize = puller.ring.read(wanted_samples);
            @memset(wanted_samples[read_frames * ring_channels ..], 0);
            puller.chunk_frame_count = wanted_frames;
            puller.next_chunk_frame = 0;
        }
    };

    /// Reads a stream voice's next frames into `voice_samples` - interleaved stereo, at the mixer's rate - from its
    /// ring, at the ring's rate and the voice's pitch, as `readSampleSource` reads samples: on the same fixed-point
    /// grid, a straight line drawn between two frames and read at the position's fraction. Samples can be read where
    /// the position falls; a stream's frames come in order and only once, so the voice keeps the two it is between -
    /// the window - and slides it on a frame each time the position passes a whole frame, taking the next from the
    /// ring. Begun, the window holds the stream's first two frames, so that at the mixer's rate and pitch 1 the voice
    /// plays the ring's frames exactly. A stream does not end by itself: every frame wanted is made, silent where the
    /// ring ran dry.
    fn readStreamSource(
        voice_slot: *VoiceSlot,
        stream: Stream,
        voice_samples: []f32,
    ) usize {
        const frames_wanted: usize = voice_samples.len / channel_count;
        const source_rate: f64 = @floatFromInt(stream.ring.sample_rate);
        const mixer_rate: f64 = @floatFromInt(sample_rate);
        const pitch: f64 = clamp(voice_slot.pitch, lowest_pitch, highest_pitch);
        const source_frames_per_mixed_frame: f64 = pitch * source_rate / mixer_rate;
        const one_frame_as_float: f64 = @floatFromInt(position_one_frame);
        const position_step: u64 = @round(source_frames_per_mixed_frame * one_frame_as_float);
        // The frames the window moves on by this block: whole frames the position passes - and two more, to begin.
        var position: u64 = voice_slot.source_position;
        const frames_passed: u64 = (position + position_step * frames_wanted) >> position_fraction_bits;
        const priming_frames: usize = if (voice_slot.is_stream_window_primed) 0 else 2;
        const frames_to_take: usize = @as(usize, @intCast(frames_passed)) + priming_frames;
        var puller: StreamPuller = .{ .ring = stream.ring, .frames_left_to_take = frames_to_take };
        var window: [2][channel_count]f32 = voice_slot.stream_window;
        if (!voice_slot.is_stream_window_primed) {
            window[0] = puller.take();
            window[1] = puller.take();
            voice_slot.is_stream_window_primed = true;
        }
        for (0..frames_wanted) |frame_index| {
            const fraction_as_integer: u64 = position & position_fraction_mask;
            const fraction_as_integer_float: f32 = @floatFromInt(fraction_as_integer);
            const fraction_between_frames: f32 = fraction_as_integer_float * position_fraction_to_float;
            for (0..channel_count) |channel| {
                const change: f32 = window[1][channel] - window[0][channel];
                const interpolated: f32 = window[0][channel] + change * fraction_between_frames;
                voice_samples[frame_index * channel_count + channel] = interpolated;
            }
            position += position_step;
            while (position >= position_one_frame) {
                position -= position_one_frame;
                window[0] = window[1];
                window[1] = puller.take();
            }
        }
        voice_slot.source_position = position;
        voice_slot.stream_window = window;
        return frames_wanted;
    }

    /// Reads a buffer of samples at the voice's pitch, resampled to the mixer's rate.
    ///
    /// Resampling. A buffer recorded at 44 100 frames a second, played by a mixer making 48 000, must be read a little
    /// slower than one source frame per mixed frame: 44 100 / 48 000 = 0.91875 source frames for each mixed frame. The
    /// pitch multiplies that speed - at pitch 2 the buffer is read twice as fast, so it sounds an octave higher and
    /// lasts half as long. So the voice keeps a position in its source, which each mixed frame moves on by
    ///
    ///     step = pitch x source rate / mixer rate          (0.91875 at pitch 1, for 44 100 played at 48 000)
    ///
    /// Fixed point. The position is not a float but a 64-bit integer counting 2^32ths of a source frame: its high 32
    /// bits are the whole frame, its low 32 bits the fraction of the way to the next one.
    ///
    ///     position 1.8375 frames  =  1 x 2^32  +  0.8375 x 2^32
    ///                                high 32 bits: 1          low 32 bits: 3 597 035 110
    ///
    /// The step is rounded to that grid once - 0.91875 x 2^32 = 3 946 001 203.2, so 3 946 001 203 - and then added
    /// exactly, frame after frame. The only error is that one rounding: at most about a ten-billionth of a frame per
    /// mixed frame, a fiftieth of a frame after an hour of playing. A float position would lose precision as it grew -
    /// at a million frames a float32 holds the fraction only to an eighth of a frame, and past 2^24 frames, under six
    /// minutes at 48 000 a second, not at all - and a float step, added millions of times, rounds at every addition.
    ///
    /// Interpolation. A position usually falls between two source frames, `index` and `index + 1`, a `fraction` of the
    /// way from the first to the second; the sample there is read off the straight line between them:
    ///
    ///     sample  =  s[index] + (s[index + 1] - s[index]) x fraction
    ///     at 1.8375, between s[1] = 0.2 and s[2] = 0.6:   0.2 + 0.4 x 0.8375  =  0.535
    ///
    /// A straight line is the simplest curve through the samples, and the cheapest: two reads, a subtraction and a
    /// multiplication. It softens the highest frequencies a little; and read fast, at a high pitch, it lets
    /// frequencies above what the mixer's rate can carry fold back as false tones (aliasing). Finer filters avoid both
    /// at many times the cost; for a game's sounds the straight line is the usual choice.
    ///
    /// The end. A buffer that does not loop stops at its end, and the voice reads fewer frames than asked for - which
    /// ends it (`Renderer.mixVoiceInto`). A looping buffer goes on from its start, the position wrapped by the
    /// remainder of the buffer's length: a step can be longer than the whole buffer - a short loop at a high pitch -
    /// and one subtraction of the length could leave the position still past the end. At the last frame there is no
    /// next one to draw the line to: a looping buffer draws it to its first frame, the one heard next; one that does
    /// not loop holds its last sample.
    ///
    /// Channels. A mono buffer's single sample goes to both channels. A stereo buffer gives its left and its right; a
    /// buffer of more channels gives its first two.
    fn readSampleSource(
        voice_slot: *VoiceSlot,
        sample_source: Samples,
        voice_samples: []f32,
    ) usize {
        const frames_wanted: usize = voice_samples.len / channel_count;
        const source_channel_count: usize = sample_source.channels;
        const source_frame_count: usize = sample_source.samples.len / source_channel_count;
        if (source_frame_count == 0) {
            return 0;
        }
        // The step: source frames per mixed frame, then on the fixed-point grid.
        const source_rate: f64 = @floatFromInt(sample_source.sample_rate);
        const mixer_rate: f64 = @floatFromInt(sample_rate);
        // A pitch of 0 would hold the voice on one sample forever, and a negative one would read backward past the
        // start: pitch is held between 1/64 - six octaves down - and 64.
        const pitch: f64 = clamp(voice_slot.pitch, lowest_pitch, highest_pitch);
        const source_frames_per_mixed_frame: f64 = pitch * source_rate / mixer_rate;
        const one_frame_as_float: f64 = @floatFromInt(position_one_frame);
        const position_step: u64 = @round(source_frames_per_mixed_frame * one_frame_as_float);
        const source_end_position: u64 = @as(u64, source_frame_count) << position_fraction_bits;
        // A frame's right sample is its second, or - in a mono buffer - the same one as its left.
        const right_channel_offset: usize = if (source_channel_count > 1) 1 else 0;
        // The position, in a local for the loop and written back to the slot once, however the loop ends. Kept in
        // the slot, it would be read and written through memory every frame: `voice_samples` is a slice of floats
        // the compiler cannot prove apart from the slot, so each write to it could have changed the position.
        var source_position: u64 = voice_slot.source_position;
        defer voice_slot.source_position = source_position;
        var frame_index: usize = 0;
        while (frame_index < frames_wanted) : (frame_index += 1) {
            const is_past_source_end: bool = source_position >= source_end_position;
            if (is_past_source_end) {
                if (!sample_source.is_looping) {
                    return frame_index;
                }
                source_position %= source_end_position;
            }
            // The position, split: its whole frame, and its fraction of the way to the next.
            const source_frame_index: usize = @intCast(source_position >> position_fraction_bits);
            const fraction_as_integer: u64 = source_position & position_fraction_mask;
            const fraction_as_integer_float: f32 = @floatFromInt(fraction_as_integer);
            const fraction_between_frames: f32 = fraction_as_integer_float * position_fraction_to_float;
            // The frame the line is drawn to: the next one; at the last frame, the first again (looping) or the last
            // itself.
            const is_last_source_frame: bool = source_frame_index + 1 >= source_frame_count;
            const next_source_frame_index: usize = if (!is_last_source_frame)
                source_frame_index + 1
            else if (sample_source.is_looping)
                0
            else
                source_frame_index;
            const first_sample_index: usize = source_frame_index * source_channel_count;
            const next_sample_index: usize = next_source_frame_index * source_channel_count;
            const left_at_frame: f32 = sample_source.samples[first_sample_index];
            const left_at_next_frame: f32 = sample_source.samples[next_sample_index];
            const right_at_frame: f32 = sample_source.samples[first_sample_index + right_channel_offset];
            const right_at_next_frame: f32 = sample_source.samples[next_sample_index + right_channel_offset];
            // The straight line between the two frames, read at the fraction.
            const left_change: f32 = left_at_next_frame - left_at_frame;
            const right_change: f32 = right_at_next_frame - right_at_frame;
            const interpolated_left: f32 = left_at_frame + left_change * fraction_between_frames;
            const interpolated_right: f32 = right_at_frame + right_change * fraction_between_frames;
            const left_sample_index: usize = frame_index * channel_count;
            const right_sample_index: usize = left_sample_index + 1;
            voice_samples[left_sample_index] = interpolated_left;
            voice_samples[right_sample_index] = interpolated_right;
            source_position += position_step;
        }
        return frames_wanted;
    }

    /// A test's sine tone: amplitude 0.5 at the frequency `context` points to, the same on both channels. The sample
    /// at frame `n` is `0.5 sin(2 pi f n / rate)` - in turns, `0.5 sinTurns(f n / rate)`.
    // ---- A renderer in another memory ----
    //
    // A wasm module is a compiled program; an instance is one running copy of it, with its own memory - a single array
    // of bytes holding all its variables, addressed from 0. In the browser the renderer runs in the audio worklet, on
    // the audio thread, in a second instance of the app's own module: the same code, so the same layout of every type,
    // but a memory of its own, which the main thread's instance cannot see. (Two instances may share one memory only
    // on a page served with particular security headers, which a page opened from a file, or shown inside a viewer,
    // does not have.) So the two sides talk by messages: the browser copies each message's data from one thread to
    // the other.
    //
    // A command that holds no address is plain data: its bytes, copied into the other instance, mean the same command
    // there, since both instances lay the type out alike. So each command is sent as its bytes (`forwardCommands`).
    // One kind of command holds an address: a registration, which names samples by where they lie in the main side's
    // memory - an address that means nothing in the worklet's. For it the samples themselves are sent; the worklet
    // copies them into its own memory and registers that copy under the same id (`RendererHost.acceptSamples`). From
    // then on a play names the samples by the id, which means the same on both sides. The renderer's notices come
    // back the same way, as plain data (`RendererHost.takeNotices`, `acceptNotices`).
    //
    //     main instance, main thread                        worklet instance, audio thread: RendererHost
    //       Mixer: commands queued
    //       forwardCommands:  a command, as its bytes  --->   acceptCommandBytes: queued for the next block
    //                         a registration, samples  --->   acceptSamples: copied here, registered by its id
    //                                                         render: the next block, the commands applied first
    //       acceptNotices: read as any renderer's      <---   takeNotices: a release frees the copy here

    /// Where `forwardCommands` hands the commands, in order: in the browser, one message to the worklet for each. Its
    /// two functions are called with `context`, a pointer to whatever state they need - Zig has no closures, functions
    /// that carry state with them, so a function and the state it works on travel as a pair.
    pub const CommandSink = struct {
        context: *anyopaque,
        /// A command other than a registration, as its bytes.
        send_command_bytes: *const fn (context: *anyopaque, command_bytes: []const u8) void,
        /// A registration: the id, and the samples themselves, to be copied into the other memory.
        send_samples: *const fn (
            context: *anyopaque,
            samples_id: SamplesId,
            samples: []const f32,
        ) void,
        /// A key's event for the instrument (`Mixer.sendNote`), sent on the main side.
        send_note: *const fn (context: *anyopaque, note_event: NoteEvent) void,
    };

    /// Takes every command waiting on the main side and hands each to `command_sink`, in the order they were sent. The
    /// order matters: the worklet applies the commands in the order they arrive, so a play naming samples by their id
    /// must arrive after the registration that gave the samples that id.
    pub fn forwardCommands(engine_mixer: *Mixer, command_sink: CommandSink) void {
        const main_side_commands: *RendererCommandQueue = &engine_mixer.renderer_queues.commands;
        while (main_side_commands.pop()) |renderer_command| {
            switch (renderer_command) {
                .register_samples => |samples_to_register| {
                    const samples_id: SamplesId = samples_to_register.samples_id;
                    const samples_in_main_memory: []const f32 = samples_to_register.samples;
                    command_sink.send_samples(command_sink.context, samples_id, samples_in_main_memory);
                },
                else => {
                    const command_bytes: []const u8 = asBytes(&renderer_command);
                    command_sink.send_command_bytes(command_sink.context, command_bytes);
                },
            }
        }
        // The notes sent on the main side, after the commands: an instrument set this frame plays this frame's notes.
        // A key's event read in the browser's own event handler goes to the worklet directly instead, without
        // waiting for the frame; these are the ones read at the frame.
        const main_side_notes: *NoteQueue = &engine_mixer.renderer_queues.notes;
        while (main_side_notes.pop()) |note_event| {
            command_sink.send_note(command_sink.context, note_event);
        }
    }

    /// Hands the main side the notices of a renderer in another memory, as its host took them
    /// (`RendererHost.takeNotices`): they are read as any renderer's, at the next frame (`Mixer.readRendererNotices`).
    /// A voice's slot ends once, and an id is released once, before the main side reads the notice and may use the
    /// slot or the id again; but a forwarded stream reports what it has read as long as it plays, and its reports pile
    /// up while the main side reads none - a hidden page's frames stop, its worklet plays on. A full queue is read
    /// here, the notices waiting applied, before the next is queued: none is dropped, and the order holds.
    pub fn acceptNotices(engine_mixer: *Mixer, renderer_notices: []const RendererNotice) void {
        const main_side_notices: *RendererNoticeQueue = &engine_mixer.renderer_queues.notices;
        for (renderer_notices) |renderer_notice| {
            if (main_side_notices.push(renderer_notice)) {
                continue;
            }
            engine_mixer.readRendererNotices();
            const is_accepted: bool = main_side_notices.push(renderer_notice);
            assertf(is_accepted, @src(), "sound: the notice queue full after its notices were read", .{});
        }
    }

    /// The notices of a renderer in another memory as a message brings them: bytes, whole notices one after another,
    /// each laid out as this side's `RendererNotice` - the worklet's instance is the same module, so the layout is the
    /// same (`worklet_abi.notice_byte_count` bytes each). The bytes may sit at any address, so each notice is copied
    /// out into a notice of its own before it is read, then handed to `acceptNotices`.
    pub fn acceptNoticeBytes(engine_mixer: *Mixer, notice_bytes: []const u8) void {
        const notice_byte_count: usize = @sizeOf(RendererNotice);
        const holds_whole_notices: bool = notice_bytes.len % notice_byte_count == 0;
        assert(holds_whole_notices, @src());
        var notice_start: usize = 0;
        while (notice_start < notice_bytes.len) : (notice_start += notice_byte_count) {
            var one_notice: [1]RendererNotice = undefined;
            const notice_storage: []u8 = asBytes(&one_notice);
            @memcpy(notice_storage, notice_bytes[notice_start..][0..notice_byte_count]);
            acceptNotices(engine_mixer, &one_notice);
        }
    }

    /// A renderer in a memory of its own - the browser's audio worklet's - with what it needs there: its own queues,
    /// the block it renders into, and its own copies of the main side's samples, made when they are registered and
    /// freed when the renderer lets them go. The worklet's program reaches it through these calls, all on the audio
    /// thread: `start` and `stop`; `acceptCommandBytes` and `acceptSamples` - or `allocateUploadedSamples` then
    /// `registerUploadedSamples`, which let the samples be copied straight into this memory - for what the main side
    /// sends; `render`, at each block the browser asks for; and `takeNotices`, for what goes back.
    pub const RendererHost = struct {
        renderer: Renderer = .{},
        /// The host's own pair of queues: commands from the main side waiting for the next block, and the renderer's
        /// notices waiting to go back. The worklet's one thread both pushes and pops them.
        renderer_queues: RendererQueues = .{},
        /// The block rendered at each request: interleaved stereo - for each frame, a left sample and then a right
        /// one - with room for the largest block a request may ask for (`render_block_most_frames`).
        render_block_samples: []f32 = &.{},
        /// This memory's copies of the main side's samples, each under its id; empty where an id is not in use.
        uploaded_samples: [samples_registry_capacity][]f32 = @splat(&.{}),
        /// This memory's rings for the streams the main side forwards, each under its number (`acceptStreamFrames`);
        /// null where a number is not in use.
        stream_rings: [forwarded_stream_capacity]?*HostStreamRing = @splat(null),
        /// Each ring's frames read as last reported (`takeNotices`): a ring is reported again once its voice has read
        /// more.
        stream_read_frames_reported: [forwarded_stream_capacity]usize = @splat(0),
        /// The frames rendered since the streams' reads were last reported (`takeNotices`).
        frames_since_stream_reports: usize = 0,
        allocator: ?Allocator = null,
        /// The loudest sample rendered since the worklet's program last took it (`takePeak`): its report to the page
        /// says whether the renderer makes any sound at all.
        peak_since_taken: f32 = 0,
        /// The largest jump, and the clipped samples, of the clicks last taken (`takeClicks`).
        largest_jump_taken: f32 = 0,
        clipped_samples_taken: u32 = 0,

        /// Allocates the blocks, once: from then on rendering allocates nothing, since the audio thread must never
        /// wait - and asking for memory can mean waiting.
        pub fn start(renderer_host: *RendererHost, allocator: Allocator) Allocator.Error!void {
            const largest_block_frame_count: usize = render_block_most_frames;
            const largest_block_sample_count: usize = largest_block_frame_count * channel_count;
            renderer_host.render_block_samples = try allocator.alloc(f32, largest_block_sample_count);
            errdefer allocator.free(renderer_host.render_block_samples);
            renderer_host.renderer.voice_scratch_samples = try allocator.alloc(f32, largest_block_sample_count);
            renderer_host.allocator = allocator;
        }

        /// Frees the blocks and every copy of samples still held.
        pub fn stop(renderer_host: *RendererHost) void {
            const allocator: Allocator = renderer_host.allocator orelse return;
            allocator.free(renderer_host.render_block_samples);
            allocator.free(renderer_host.renderer.voice_scratch_samples);
            for (&renderer_host.uploaded_samples) |*uploaded_copy| {
                allocator.free(uploaded_copy.*);
                uploaded_copy.* = &.{};
            }
            for (&renderer_host.stream_rings) |*stream_ring_slot| {
                if (stream_ring_slot.*) |host_stream_ring| {
                    allocator.destroy(host_stream_ring);
                }
                stream_ring_slot.* = null;
            }
            renderer_host.allocator = null;
        }

        /// The frames between two reports of what the forwarded streams have read (`takeNotices`): 512, about 11 ms at
        /// 48 000 Hz - more often than a game's frame reads them, at 60 a second, and a message every four blocks
        /// rather than every block. A ring that has run dry is reported at once.
        const stream_report_interval_frames: usize = 512;

        /// The frames a forwarded stream's ring in this memory holds: 4 096, twice the 2 048 a stream's ring holds on
        /// the main side. The main side keeps its frames until they are read here and sends each once, so this ring
        /// never holds more than the main side's own does.
        const host_stream_ring_frames: usize = 4096;

        /// A forwarded stream's ring and its samples, in one allocation of this memory's: room for stereo, a mono
        /// ring using the first half.
        const HostStreamRing = struct {
            ring: StreamRing,
            /// The generation of the stream it plays, as its voice's start gave it (`ForwardedStream.generation`): its
            /// reports carry it back.
            generation: u8 = 0,
            samples: [host_stream_ring_frames * channel_count]f32,
        };

        /// The ring for `stream`, made at its first use - its first frames, or a voice's start, whichever comes
        /// first; null when this memory has no room for it.
        fn openStreamRing(renderer_host: *RendererHost, stream: ForwardedStream) ?*HostStreamRing {
            assertf(stream.id < forwarded_stream_capacity, @src(), "sound: forwarded stream {d}, of {d}", .{
                stream.id,
                forwarded_stream_capacity,
            });
            if (renderer_host.stream_rings[stream.id]) |host_stream_ring| {
                return host_stream_ring;
            }
            const allocator: Allocator = renderer_host.allocator orelse return null;
            const host_stream_ring: *HostStreamRing = allocator.create(HostStreamRing) catch return null;
            const ring_samples: []f32 = host_stream_ring.samples[0 .. host_stream_ring_frames * stream.channels];
            host_stream_ring.ring = .initOver(ring_samples, stream.channels, stream.sample_rate);
            renderer_host.stream_rings[stream.id] = host_stream_ring;
            renderer_host.stream_read_frames_reported[stream.id] = 0;
            return host_stream_ring;
        }

        /// A forwarded stream's frames, as the main side sent them: written into its ring here, opened at the first.
        /// They always fit - the main side never has more unread than this ring holds - and should they not, those
        /// past its room are lost, as a dry ring's silence is: never a trap, which would end the page's sound.
        pub fn acceptStreamFrames(
            renderer_host: *RendererHost,
            stream: ForwardedStream,
            frames: []const f32,
        ) void {
            const host_stream_ring: *HostStreamRing = renderer_host.openStreamRing(stream) orelse return;
            _ = host_stream_ring.ring.write(frames);
        }

        /// A command's bytes, as the main side sent them (`forwardCommands`): copied back into a command - whose layout
        /// is the same in both instances - and queued for the renderer's next block. The queue fills when commands
        /// keep coming and no block is asked for - while the audio context is suspended, the worklet still takes its
        /// messages - and then the commands waiting are applied at once: the renderer is this thread's, as a mixer's on
        /// its own thread is (`Mixer.sendToRenderer`). None is dropped; each still applies in the order it was sent.
        pub fn acceptCommandBytes(renderer_host: *RendererHost, command_bytes: []const u8) void {
            const expected_byte_count: usize = @sizeOf(RendererCommand);
            assert(command_bytes.len == expected_byte_count, @src());
            var renderer_command: RendererCommand = undefined;
            const command_storage: []u8 = asBytes(&renderer_command);
            @memcpy(command_storage, command_bytes);
            // What only the host can do, in its memory: a forwarded stream's ring freed; a voice's start naming a
            // forwarded stream given that ring's address - or, where no ring can be made, the voice told ended at
            // once, so that the main side does not hold its slot for ever.
            switch (renderer_command) {
                .release_stream => |stream_id| {
                    const host_stream_ring: *HostStreamRing = renderer_host.stream_rings[stream_id] orelse return;
                    renderer_host.allocator.?.destroy(host_stream_ring);
                    renderer_host.stream_rings[stream_id] = null;
                    return;
                },
                .play => |*voice_to_start| switch (voice_to_start.source) {
                    .forwarded_stream => |stream| {
                        const host_stream_ring: *HostStreamRing = renderer_host.openStreamRing(stream) orelse {
                            const slot_index: u8 = @intCast(voice_to_start.voice.slotIndex());
                            const ended_notice: RendererNotice = .{ .voice_ended = slot_index };
                            _ = renderer_host.renderer_queues.notices.push(ended_notice);
                            return;
                        };
                        host_stream_ring.generation = stream.generation;
                        voice_to_start.source = .{ .stream = &host_stream_ring.ring };
                    },
                    .samples, .generator, .stream => {},
                },
                else => {},
            }
            if (renderer_host.renderer_queues.commands.push(renderer_command)) {
                return;
            }
            renderer_host.renderer.applyCommands(&renderer_host.renderer_queues);
            const is_queued: bool = renderer_host.renderer_queues.commands.push(renderer_command);
            assertf(is_queued, @src(), "sound: the host's command queue full after applying its commands", .{});
        }

        /// Room in this memory for the `sample_count` samples the main side registered under `samples_id`: the caller
        /// copies them in, then registers them (`registerUploadedSamples`). The id is free here: the main side uses an
        /// id again only after the release notice that freed this side's copy.
        pub fn allocateUploadedSamples(
            renderer_host: *RendererHost,
            samples_id: SamplesId,
            sample_count: usize,
        ) Allocator.Error![]f32 {
            const allocator: Allocator = renderer_host.allocator.?;
            const is_id_free_here: bool = renderer_host.uploaded_samples[samples_id].len == 0;
            assert(is_id_free_here, @src());
            const uploaded_copy: []f32 = try allocator.alloc(f32, sample_count);
            renderer_host.uploaded_samples[samples_id] = uploaded_copy;
            return uploaded_copy;
        }

        /// Registers the samples copied in under `samples_id`, for the renderer's next block - before any command that
        /// arrives after it, a play of those samples among them.
        pub fn registerUploadedSamples(renderer_host: *RendererHost, samples_id: SamplesId) void {
            const uploaded_copy: []const f32 = renderer_host.uploaded_samples[samples_id];
            const samples_to_register: SamplesToRegister = .{ .samples_id = samples_id, .samples = uploaded_copy };
            const register_command: RendererCommand = .{ .register_samples = samples_to_register };
            const is_queued: bool = renderer_host.renderer_queues.commands.push(register_command);
            assert(is_queued, @src());
        }

        /// Copies `samples` into this memory and registers the copy under `samples_id`.
        pub fn acceptSamples(
            renderer_host: *RendererHost,
            samples_id: SamplesId,
            samples: []const f32,
        ) Allocator.Error!void {
            const uploaded_copy: []f32 = try renderer_host.allocateUploadedSamples(samples_id, samples.len);
            @memcpy(uploaded_copy, samples);
            renderer_host.registerUploadedSamples(samples_id);
        }

        /// Renders the next `frame_count` frames - the commands waiting applied first - and returns them, interleaved.
        /// The worklet asks for 128 frames at a time; a request never passes the block's room.
        pub fn render(renderer_host: *RendererHost, frame_count: usize) []const f32 {
            const sample_count: usize = frame_count * channel_count;
            const is_within_room: bool = sample_count <= renderer_host.render_block_samples.len;
            assert(is_within_room, @src());
            const rendered_block: []f32 = renderer_host.render_block_samples[0..sample_count];
            renderer_host.renderer.render(&renderer_host.renderer_queues, rendered_block);
            renderer_host.frames_since_stream_reports += frame_count;
            for (rendered_block) |rendered_sample| {
                renderer_host.peak_since_taken = @max(renderer_host.peak_since_taken, @abs(rendered_sample));
            }
            return rendered_block;
        }

        /// The clicks the renderer counted since the last call (`Renderer.takeClicks`); the largest jump among them is
        /// kept for `takenLargestJump`, the worklet's program asking for the two one number at a time.
        pub fn takeClicks(renderer_host: *RendererHost) u32 {
            const report: Renderer.ClickReport = renderer_host.renderer.takeClicks();
            renderer_host.largest_jump_taken = report.largest_jump;
            renderer_host.clipped_samples_taken = report.clipped_sample_count;
            return report.click_count;
        }

        /// The clipped samples of the clicks last taken (`takeClicks`).
        pub fn takenClippedSamples(renderer_host: *const RendererHost) u32 {
            return renderer_host.clipped_samples_taken;
        }

        /// The largest jump of the clicks last taken (`takeClicks`).
        pub fn takenLargestJump(renderer_host: *const RendererHost) f32 {
            return renderer_host.largest_jump_taken;
        }

        /// The loudest sample rendered since the last call, and the count starts again.
        pub fn takePeak(renderer_host: *RendererHost) f32 {
            const peak: f32 = renderer_host.peak_since_taken;
            renderer_host.peak_since_taken = 0;
            return peak;
        }

        /// Queues a key's event for the renderer's next block, where the instrument starts or releases its note. The
        /// queue - 256 events - fills as the commands' does (`acceptCommandBytes`), and then the events waiting are
        /// applied at once, the instrument starting and releasing their notes: none is dropped - a key's release lost
        /// would leave its note sounding. Always true: the event is queued.
        pub fn acceptNote(renderer_host: *RendererHost, note_event: NoteEvent) bool {
            if (renderer_host.renderer_queues.notes.push(note_event)) {
                return true;
            }
            renderer_host.renderer.applyNotes(&renderer_host.renderer_queues);
            const is_queued: bool = renderer_host.renderer_queues.notes.push(note_event);
            assertf(is_queued, @src(), "sound: the host's note queue full after applying its notes", .{});
            return true;
        }

        /// Takes the renderer's notices into `renderer_notices`, as many as fit, and says how many it took. A release
        /// among them frees this memory's copy of those samples: the renderer has applied it, so no voice reads the
        /// copy any more.
        pub fn takeNotices(renderer_host: *RendererHost, renderer_notices: []RendererNotice) usize {
            var taken_notice_count: usize = 0;
            while (taken_notice_count < renderer_notices.len) {
                const renderer_notice: RendererNotice = renderer_host.renderer_queues.notices.pop() orelse break;
                switch (renderer_notice) {
                    .samples_released => |samples_id| {
                        const uploaded_copy: []f32 = renderer_host.uploaded_samples[samples_id];
                        renderer_host.allocator.?.free(uploaded_copy);
                        renderer_host.uploaded_samples[samples_id] = &.{};
                    },
                    .voice_ended, .stream_read, .start_measured => {},
                }
                renderer_notices[taken_notice_count] = renderer_notice;
                taken_notice_count += 1;
            }
            // Then the renderer's measured starts, for the main side's readout - as many as there is room for, the
            // rest at the next taking.
            while (taken_notice_count < renderer_notices.len) {
                const latency_sample: LatencySample = renderer_host.renderer_queues.latency.pop() orelse break;
                renderer_notices[taken_notice_count] = .{ .start_measured = latency_sample };
                taken_notice_count += 1;
            }
            // Then each forwarded stream's ring whose voice has read more since its last report, once the reports are
            // due (`stream_report_interval_frames`), or has run dry: what it has read, and the frames it ran dry for. A
            // ring run dry reads nothing, so its count alone would not say so.
            const are_reports_due: bool = renderer_host.frames_since_stream_reports >= stream_report_interval_frames;
            if (are_reports_due) {
                renderer_host.frames_since_stream_reports = 0;
            }
            for (renderer_host.stream_rings, 0..) |stream_ring_slot, stream_index| {
                if (taken_notice_count == renderer_notices.len) {
                    break;
                }
                const host_stream_ring: *HostStreamRing = stream_ring_slot orelse continue;
                const read_frames: usize = host_stream_ring.ring.reading_side.read_frames.load(.acquire);
                const has_read_more: bool = read_frames != renderer_host.stream_read_frames_reported[stream_index];
                const has_run_dry: bool = host_stream_ring.ring.reading_side.dry_frames.load(.monotonic) != 0;
                if (!(has_read_more and are_reports_due) and !has_run_dry) {
                    continue;
                }
                renderer_host.stream_read_frames_reported[stream_index] = read_frames;
                const dry_frames: usize = host_stream_ring.ring.takeDryFrames();
                renderer_notices[taken_notice_count] = .{ .stream_read = .{
                    .id = @intCast(stream_index),
                    .generation = host_stream_ring.generation,
                    .dry_frames = @intCast(@min(dry_frames, zm.maxInt(u16))),
                    .read_frames = @truncate(read_frames),
                } };
                taken_notice_count += 1;
            }
            return taken_notice_count;
        }

        /// Runs every function a block calls, once the renderer has started and before the first sound needs it, so
        /// that none is compiled inside a block that must be heard.
        ///
        /// Why it is needed. A browser does not compile a WebAssembly function to fast machine code when the module
        /// loads. It compiles each function the first time it is called, with a quick compiler, and compiles it again
        /// with the optimising one once the function has been called often (V8 calls this tiering up). Either compile
        /// can take a millisecond or more, and the block that makes the first call waits for it: a block has 2.7 ms
        /// in all, so the first sound, or the first sound of a new kind, can arrive late - a gap heard as a click.
        ///
        /// What it does. It runs the renderer's paths in a scratch host of its own, made here and freed at the end,
        /// so that this host - its voices, its queues, its notices - is left exactly as it was: the functions are what
        /// is compiled, not the data, so the scratch host warms them for this one. Into the scratch host it plays, at
        /// volume 0, a voice of each kind the renderer knows by itself:
        ///
        ///     a generator                                  the generator path, gains, the mix
        ///     samples, mono, at 24 000 Hz, at pitch 1.5    reading between samples (resampling), looping
        ///     samples, stereo, at the mixer's rate         reading two channels
        ///
        /// renders `warm_up_block_count` blocks of 128 frames - enough calls for the browser to tier the hot functions
        /// up here rather than in a block that is heard - then releases the stereo samples while their voice plays
        /// (the copy of a released voice's tail, and its fade) and stops the other two (the fade of a stopped voice),
        /// renders until all three have ended, and takes the notices. The instrument's functions are the app's, and
        /// are warmed when the instrument is set (`Renderer.warmInstrument`).
        pub fn warmUp(renderer_host: *const RendererHost) Allocator.Error!void {
            const allocator: Allocator = renderer_host.allocator.?;
            const scratch_host: *RendererHost = try allocator.create(RendererHost);
            defer allocator.destroy(scratch_host);
            scratch_host.* = .{};
            try scratch_host.start(allocator);
            defer scratch_host.stop();
            // The samples: silent, so that nothing rendered here could be heard even if it were played.
            const mono_frame_count: usize = 1_024;
            const stereo_frame_count: usize = 1_024;
            const mono_samples_id: SamplesId = 0;
            const stereo_samples_id: SamplesId = 1;
            const mono_room: []f32 = try scratch_host.allocateUploadedSamples(mono_samples_id, mono_frame_count);
            @memset(mono_room, 0);
            scratch_host.registerUploadedSamples(mono_samples_id);
            const stereo_sample_count: usize = stereo_frame_count * channel_count;
            const stereo_room: []f32 = try scratch_host.allocateUploadedSamples(stereo_samples_id, stereo_sample_count);
            @memset(stereo_room, 0);
            scratch_host.registerUploadedSamples(stereo_samples_id);
            // The three voices, in the first three slots, at volume 0.
            const generator_voice: Voice = .ofSlot(0, 0);
            const mono_voice: Voice = .ofSlot(1, 0);
            const stereo_voice: Voice = .ofSlot(2, 0);
            const generator_play: VoiceToStart = .{
                .voice = generator_voice,
                .source = .{ .generator = .{ .generate = &generateWarmUpSilence, .channels = channel_count } },
                .options = .{ .volume = 0 },
            };
            const mono_play: VoiceToStart = .{
                .voice = mono_voice,
                .source = .{ .samples = .{
                    .samples_id = mono_samples_id,
                    .channels = 1,
                    .sample_rate = 24_000,
                    .is_looping = true,
                } },
                .options = .{ .volume = 0, .pitch = 1.5 },
            };
            const stereo_play: VoiceToStart = .{
                .voice = stereo_voice,
                .source = .{ .samples = .{
                    .samples_id = stereo_samples_id,
                    .channels = channel_count,
                    .sample_rate = sample_rate,
                    .is_looping = true,
                } },
                .options = .{ .volume = 0 },
            };
            const scratch_commands: *RendererCommandQueue = &scratch_host.renderer_queues.commands;
            const plays: [3]RendererCommand = .{
                .{ .play = generator_play },
                .{ .play = mono_play },
                .{ .play = stereo_play },
            };
            for (plays) |play_command| {
                const is_queued: bool = scratch_commands.push(play_command);
                assert(is_queued, @src());
            }
            const block_frame_count: usize = 128;
            for (0..warm_up_block_count) |_| {
                _ = scratch_host.render(block_frame_count);
            }
            // The ways a voice ends: its samples released under it, and a stop - each a fade of `fade_out_frames`.
            const endings: [3]RendererCommand = .{
                .{ .release_samples = stereo_samples_id },
                .{ .stop = generator_voice },
                .{ .stop = mono_voice },
            };
            for (endings) |ending_command| {
                const is_queued: bool = scratch_commands.push(ending_command);
                assert(is_queued, @src());
            }
            const fade_block_count: usize = fade_out_frames / block_frame_count + 2;
            for (0..fade_block_count) |_| {
                _ = scratch_host.render(block_frame_count);
            }
            var scratch_notices: [8]RendererNotice = undefined;
            _ = scratch_host.takeNotices(&scratch_notices);
            for (&scratch_host.renderer.voice_slots) |*voice_slot| {
                assert(!voice_slot.is_playing, @src());
            }
        }
    };

    /// The frames of each of the two blocks `Renderer.warmInstrument` generates: one browser block.
    const warm_instrument_frame_count: usize = 128;

    /// How many blocks `RendererHost.warmUp` renders: enough calls for V8 to tier the block's functions up to its
    /// optimising compiler, which it does after a function has run for a while - the count is a budget, not a
    /// measured threshold. 64 blocks of 128 frames are 171 ms of sound, rendered in a millisecond or two.
    const warm_up_block_count: usize = 64;

    /// The generator `RendererHost.warmUp` plays: silence, on every channel.
    fn generateWarmUpSilence(state: *anyopaque, frames: []f32, first_frame: u64) void {
        _ = state;
        _ = first_frame;
        @memset(frames, 0);
    }

    // ---- The worklet's entry points ----
    //
    // In the browser the audio worklet runs a second instance of the app's own module, and reaches the renderer host
    // in it through these functions, which the app's module exports (`exportWorkletEntryPoints`) under the names in
    // `worklet_abi`; the worklet's program calls them by the same names. Each takes and gives plain numbers - counts,
    // and addresses in the worklet instance's memory - since a JavaScript caller can pass nothing else: the program
    // writes a command's bytes at the command buffer's address, copies samples to the address it is given room at, and
    // reads a rendered block, and the notices, at the addresses returned.
    //
    //     the worklet's program                           the app's module, in the worklet's instance
    //       once:          start                  --->      the host's blocks allocated
    //       then, once:    warm_up                --->      every function a block calls, run once in a scratch host
    //       a command:     its bytes into the command buffer, then
    //                      accept_command         --->      queued for the next block
    //       samples:       allocate_samples(id, n) -->      room for n samples: its address
    //                      the samples copied in, then
    //                      register_samples(id)   --->      registered under the id
    //       stream frames: up to a buffer's worth into the stream buffer, then
    //                      accept_stream_frames(id, channels, rate, n)  --->  written into the stream's ring
    //       each quantum:  render(128)            --->      the block's address: 128 left samples, 128 right
    //       then:          take_notices           --->      how many notices are in the notices buffer

    /// The names the worklet's entry points are exported under, and the sizes of what crosses: read by the app's
    /// module, which exports the functions, and by the worklet's program, which calls them - one spelling of each.
    pub const worklet_abi = struct {
        pub const start = "zimr_audio_worklet_start";
        pub const command_buffer = "zimr_audio_worklet_command_buffer";
        pub const accept_command = "zimr_audio_worklet_accept_command";
        pub const allocate_samples = "zimr_audio_worklet_allocate_samples";
        pub const register_samples = "zimr_audio_worklet_register_samples";
        pub const render = "zimr_audio_worklet_render";
        pub const take_notices = "zimr_audio_worklet_take_notices";
        pub const notices_buffer = "zimr_audio_worklet_notices_buffer";
        pub const accept_note = "zimr_audio_worklet_accept_note";
        pub const stamp_note = "zimr_audio_worklet_stamp_note";
        pub const take_peak = "zimr_audio_worklet_take_peak";
        pub const take_clicks = "zimr_audio_worklet_take_clicks";
        pub const taken_largest_jump = "zimr_audio_worklet_taken_largest_jump";
        pub const taken_clipped_samples = "zimr_audio_worklet_taken_clipped_samples";
        pub const warm_up = "zimr_audio_worklet_warm_up";
        pub const stream_frames_buffer = "zimr_audio_worklet_stream_frames_buffer";
        pub const accept_stream_frames = "zimr_audio_worklet_accept_stream_frames";
        pub const copy_analysis = "zimr_audio_worklet_copy_analysis";
        pub const tie_clocks = "zimr_audio_worklet_tie_clocks";
        pub const time_block = "zimr_audio_worklet_time_block";
        /// The frames an analysis answer holds: the renderer's whole analysis ring (`Renderer.analysis_ring`).
        pub const analysis_frame_count: usize = analysis_ring_frames;
        /// The samples the stream buffer holds: a host's ring's worth of stereo frames. A message with more is
        /// copied in that many at a time.
        pub const stream_frames_buffer_samples: usize = RendererHost.host_stream_ring_frames * channel_count;
        /// The bytes of one command and of one notice, as both sides lay them out: the worklet's program copies whole
        /// ones.
        pub const command_byte_count: usize = @sizeOf(RendererCommand);
        pub const notice_byte_count: usize = @sizeOf(RendererNotice);
        /// The name the worklet's processor is registered under, and the option of its constructor that holds the
        /// app's compiled module (`processorOptions.module`).
        pub const processor_name = "zimr-renderer";
        pub const module_option = "module";
        /// The messages between the main thread and the worklet: JavaScript objects, told apart by their kind.
        ///
        ///     main thread -> worklet   { kind: "commands", bytes }          whole commands, one after another
        ///     main thread -> worklet   { kind: "samples", samplesId, samples }  samples to register under the id
        ///     main thread -> worklet   { kind: "note", key, isDown, velocity }   a key's event, for the instrument
        ///     main thread -> worklet   { kind: "stream", streamId, channels, sampleRate, frames }
        ///                                                                    a forwarded stream's frames, for its ring
        ///     a note's message also carries `requestedAt` and `pressedAt`, the times its start is measured from
        ///     main thread -> worklet   { kind: "clock", contextMs, pageMs }  the context's timeline tied to the page's
        ///                                                                    clock: the moment `contextMs` of the one
        ///                                                                    is rendered at `pageMs` of the other
        ///     main thread -> worklet   { kind: "analysis" }                  the renderer's last frames asked for
        ///     worklet -> main thread   { kind: "analysis", bytes }           its last `analysis_frame_count` frames
        ///                                                                    mixed, oldest first, as f32 bytes
        ///     worklet -> main thread   { kind: "ready" }                     the module linked, the renderer started
        ///                                                                    and warmed up (`RendererHost.warmUp`)
        ///     worklet -> main thread   { kind: "failed" }                    the renderer could not start (memory)
        ///     worklet -> main thread   { kind: "stats", blocks, peak }       each second: blocks rendered, loudest
        ///     worklet -> main thread   { kind: "notices", bytes }           whole notices, one after another
        ///
        /// They are taken in the order sent, so samples sent before a command that plays them are registered first.
        pub const message = struct {
            pub const kind_field = "kind";
            pub const commands_kind = "commands";
            pub const samples_kind = "samples";
            pub const notices_kind = "notices";
            pub const bytes_field = "bytes";
            pub const samples_id_field = "samplesId";
            pub const samples_field = "samples";
            pub const note_kind = "note";
            pub const ready_kind = "ready";
            pub const failed_kind = "failed";
            pub const stats_kind = "stats";
            pub const blocks_field = "blocks";
            pub const peak_field = "peak";
            pub const clicks_field = "clicks";
            pub const largest_jump_field = "largestJump";
            pub const clipped_field = "clipped";
            pub const key_field = "key";
            pub const is_down_field = "isDown";
            pub const velocity_field = "velocity";
            pub const requested_at_field = "requestedAt";
            pub const pressed_at_field = "pressedAt";
            pub const stream_kind = "stream";
            pub const analysis_kind = "analysis";
            pub const clock_kind = "clock";
            pub const context_ms_field = "contextMs";
            pub const page_ms_field = "pageMs";
            pub const stream_id_field = "streamId";
            pub const channels_field = "channels";
            pub const sample_rate_field = "sampleRate";
            pub const frames_field = "frames";
        };
    };

    /// What the worklet instance's host allocates with: the module's own heap, which grows the instance's memory as
    /// needed. A test sets another before `workletStart`.
    const default_worklet_allocator: Allocator = if (builtin.cpu.arch.isWasm())
        std.heap.wasm_allocator
    else
        std.heap.page_allocator;
    /// What the worklet's entry points share: the host they reach, what it allocates with, and the two buffers the
    /// worklet's program reads and writes through. A module's exported functions can share state only through a
    /// global - a JavaScript caller can hand them nothing else - and the worklet's instance has exactly one.
    const WorkletState = struct {
        allocator: Allocator = default_worklet_allocator,
        renderer_host: RendererHost = .{},
        /// Where the worklet's program writes a command's bytes, before `workletAcceptCommand`.
        command_bytes: [@sizeOf(RendererCommand)]u8 align(@alignOf(RendererCommand)) = undefined,
        /// Where `workletTakeNotices` writes the notices it took, for the worklet's program to send to the main
        /// thread.
        notices: [notice_queue_capacity]RendererNotice = undefined,
        /// Each block rendered, one channel after the other (`workletRender`).
        channel_samples: [render_block_most_frames * channel_count]f32 = undefined,
        /// Where the worklet's program copies a forwarded stream's frames, before `workletAcceptStreamFrames`.
        stream_frames: [worklet_abi.stream_frames_buffer_samples]f32 = undefined,
        /// Where `workletCopyAnalysis` copies the renderer's last frames mixed, for the worklet's program to send.
        analysis_frames: [worklet_abi.analysis_frame_count]f32 = undefined,
        /// The context's timeline tied to the page's clock (`workletTieClocks`): a moment of the one, and when the
        /// other renders it - null until the page has sent a first tie.
        clock_tie: ?ClockTie = null,
        /// The next block's timing on the page's clock (`workletTimeBlock`), handed to the renderer for that block.
        next_block_timing: ?contract.AudioRenderTiming = null,
        /// The times of the next note accepted (`workletStampNote`), none until stamped.
        next_note_stamp: NoteStamp = .{},
    };

    /// A note's times as a message carries them (`workletStampNote`): 0 for each unknown.
    const NoteStamp = struct {
        requested_at_ms: f64 = 0,
        pressed_at_ms: f64 = 0,
    };

    /// A moment of the audio context's timeline, in milliseconds, and the time on the page's clock when it is rendered
    /// (`WorkletState.clock_tie`).
    const ClockTie = struct {
        context_ms: f64,
        page_ms: f64,
    };
    // lint:off module-var: the worklet instance's one state - its exported functions can share nothing else
    var worklet_state: WorkletState = .{};

    /// Exports the worklet's entry points under their names (`worklet_abi`). Called by the app module's root, in a
    /// build for the browser.
    pub fn exportWorkletEntryPoints() void {
        @export(&workletStart, .{ .name = worklet_abi.start });
        @export(&workletCommandBuffer, .{ .name = worklet_abi.command_buffer });
        @export(&workletAcceptCommand, .{ .name = worklet_abi.accept_command });
        @export(&workletAllocateSamples, .{ .name = worklet_abi.allocate_samples });
        @export(&workletRegisterSamples, .{ .name = worklet_abi.register_samples });
        @export(&workletRender, .{ .name = worklet_abi.render });
        @export(&workletTakeNotices, .{ .name = worklet_abi.take_notices });
        @export(&workletNoticesBuffer, .{ .name = worklet_abi.notices_buffer });
        @export(&workletAcceptNote, .{ .name = worklet_abi.accept_note });
        @export(&workletTakePeak, .{ .name = worklet_abi.take_peak });
        @export(&workletTakeClicks, .{ .name = worklet_abi.take_clicks });
        @export(&workletTakenLargestJump, .{ .name = worklet_abi.taken_largest_jump });
        @export(&workletTakenClippedSamples, .{ .name = worklet_abi.taken_clipped_samples });
        @export(&workletWarmUp, .{ .name = worklet_abi.warm_up });
        @export(&workletStreamFramesBuffer, .{ .name = worklet_abi.stream_frames_buffer });
        @export(&workletAcceptStreamFrames, .{ .name = worklet_abi.accept_stream_frames });
        @export(&workletCopyAnalysis, .{ .name = worklet_abi.copy_analysis });
        @export(&workletTieClocks, .{ .name = worklet_abi.tie_clocks });
        @export(&workletStampNote, .{ .name = worklet_abi.stamp_note });
        @export(&workletTimeBlock, .{ .name = worklet_abi.time_block });
    }

    /// Ties the audio context's timeline to the page's clock (`{ kind: "clock" }`): the moment `context_ms` of the
    /// timeline is rendered at `page_ms` of the page's clock, `performance.now()`'s - the clock the main side stamps
    /// its requests on. The page sends a new tie four times a second, from what it reads of `getOutputTimestamp`
    /// (`page_audio.readOutputContinuity`), so that a drift between the two clocks never builds up.
    fn workletTieClocks(context_ms: f64, page_ms: f64) callconv(.c) void {
        worklet_state.clock_tie = .{ .context_ms = context_ms, .page_ms = page_ms };
    }

    /// Times the next block by the frame it begins at on the context's timeline, `context_frame` - the worklet's
    /// `currentFrame`: its time on the page's clock is the tie's, moved on by the frames since the tie's moment. That
    /// time is both when the block was asked for and when its first frame goes out: on this path a block goes to the
    /// browser as it is made, and the browser's own buffer and the device's are what the readout counts as `past`
    /// (`page_audio.outputLatencyMilliseconds`). Before the first tie the block is not timed, and its starts are not
    /// measured.
    fn workletTimeBlock(context_frame: f64) callconv(.c) void {
        const tie: ClockTie = worklet_state.clock_tie orelse {
            worklet_state.next_block_timing = null;
            return;
        };
        const context_ms: f64 = 1000 * context_frame / float64(sample_rate);
        const page_ms: f64 = tie.page_ms + (context_ms - tie.context_ms);
        worklet_state.next_block_timing = .{ .asked_at_ms = page_ms, .first_frame_out_ms = page_ms };
    }

    /// Copies the renderer's last frames mixed, oldest first, into the analysis buffer
    /// (`WorkletState.analysis_frames`), and returns its address: what the worklet's program sends back to an analyser
    /// on the main thread.
    fn workletCopyAnalysis() callconv(.c) usize {
        worklet_state.renderer_host.renderer.copyAnalysisFrames(&worklet_state.analysis_frames);
        return @intFromPtr(&worklet_state.analysis_frames);
    }

    /// Allocates the host's blocks: 1 when it could, 0 when memory ran out.
    fn workletStart() callconv(.c) u32 {
        worklet_state.renderer_host.start(worklet_state.allocator) catch return 0;
        return 1;
    }

    /// Runs every function a block calls once, before the first block is heard (`RendererHost.warmUp`): 1 when it
    /// could, 0 when memory ran out - the renderer still plays then, only without the warm-up.
    fn workletWarmUp() callconv(.c) u32 {
        worklet_state.renderer_host.warmUp() catch return 0;
        return 1;
    }

    /// The address of the command buffer, where the worklet's program writes each command's bytes.
    fn workletCommandBuffer() callconv(.c) [*]u8 {
        return &worklet_state.command_bytes;
    }

    /// Queues the command whose bytes are in the command buffer, for the renderer's next block.
    fn workletAcceptCommand() callconv(.c) void {
        worklet_state.renderer_host.acceptCommandBytes(&worklet_state.command_bytes);
    }

    /// The loudest sample rendered since the last call (`RendererHost.takePeak`).
    fn workletTakePeak() callconv(.c) f32 {
        return worklet_state.renderer_host.takePeak();
    }

    /// The clicks the renderer counted since the last call (`RendererHost.takeClicks`).
    fn workletTakeClicks() callconv(.c) f32 {
        return @floatFromInt(worklet_state.renderer_host.takeClicks());
    }

    /// The largest jump of the clicks last taken (`RendererHost.takenLargestJump`).
    fn workletTakenLargestJump() callconv(.c) f32 {
        return worklet_state.renderer_host.takenLargestJump();
    }

    /// The clipped samples of the clicks last taken (`RendererHost.takenClippedSamples`).
    fn workletTakenClippedSamples() callconv(.c) f32 {
        return @floatFromInt(worklet_state.renderer_host.takenClippedSamples());
    }

    /// A key's event, as plain numbers - its key (0 to 127), 1 for down or 0 for up, its velocity - queued for the
    /// instrument at the next block. A key past 127 is no MIDI key, and is dropped.
    /// Where the worklet's program copies a forwarded stream's frames (`WorkletState.stream_frames`).
    fn workletStreamFramesBuffer() callconv(.c) usize {
        return @intFromPtr(&worklet_state.stream_frames);
    }

    /// The `sample_count` samples the worklet's program copied into the stream buffer: frames of the forwarded stream
    /// `stream_id`, of `channels` channels made at `frames_per_second`, written into its ring
    /// (`RendererHost.acceptStreamFrames`). What could not be a stream's - a number past the table, other than one or
    /// two channels, no rate, more samples than the buffer, or a part of a frame - is not taken.
    fn workletAcceptStreamFrames(
        stream_id: u32,
        channels: u32,
        frames_per_second: u32,
        sample_count: u32,
    ) callconv(.c) void {
        const is_valid_id: bool = stream_id < forwarded_stream_capacity;
        const is_mono_or_stereo: bool = channels == 1 or channels == 2;
        const is_within_buffer: bool = sample_count <= worklet_abi.stream_frames_buffer_samples;
        if (!is_valid_id or !is_mono_or_stereo or !is_within_buffer or frames_per_second == 0) {
            return;
        }
        if (sample_count % channels != 0) {
            return;
        }
        const stream: ForwardedStream = .{
            .id = @intCast(stream_id),
            .channels = @intCast(channels),
            .sample_rate = frames_per_second,
        };
        worklet_state.renderer_host.acceptStreamFrames(stream, worklet_state.stream_frames[0..sample_count]);
    }

    fn workletAcceptNote(key: u32, is_down: u32, velocity: f32) callconv(.c) void {
        const stamp: NoteStamp = worklet_state.next_note_stamp;
        worklet_state.next_note_stamp = .{};
        if (key > 127) {
            return;
        }
        const note_event: NoteEvent = .{
            .key = @intCast(key),
            .is_down = is_down != 0,
            .velocity = velocity,
            .requested_at_ms = stamp.requested_at_ms,
            .pressed_at_ms = stamp.pressed_at_ms,
        };
        _ = worklet_state.renderer_host.acceptNote(note_event);
    }

    /// The times of the note the next `workletAcceptNote` takes (`NoteEvent.requested_at_ms`, `pressed_at_ms`), on
    /// the page's clock: a message's note carries them, and the worklet's program hands them over first, as the
    /// note's five numbers are more than one call of its passes.
    fn workletStampNote(requested_at_ms: f64, pressed_at_ms: f64) callconv(.c) void {
        worklet_state.next_note_stamp = .{ .requested_at_ms = requested_at_ms, .pressed_at_ms = pressed_at_ms };
    }

    /// Room for the `sample_count` samples the main side registered under `samples_id`, in this memory: its address,
    /// for the worklet's program to copy them to before `workletRegisterSamples`; 0 when memory ran out - the samples
    /// are then never registered here, and a voice of them ends at once, silent.
    fn workletAllocateSamples(samples_id: u32, sample_count: u32) callconv(.c) usize {
        const is_valid_id: bool = samples_id < samples_registry_capacity;
        assert(is_valid_id, @src());
        const renderer_host: *RendererHost = &worklet_state.renderer_host;
        const room: []f32 = renderer_host.allocateUploadedSamples(@intCast(samples_id), sample_count) catch return 0;
        return @intFromPtr(room.ptr);
    }

    /// Registers the samples copied to the room `workletAllocateSamples` gave for `samples_id`.
    fn workletRegisterSamples(samples_id: u32) callconv(.c) void {
        const is_valid_id: bool = samples_id < samples_registry_capacity;
        assert(is_valid_id, @src());
        worklet_state.renderer_host.registerUploadedSamples(@intCast(samples_id));
    }

    /// Renders the next `frame_count` frames, the commands waiting applied first, and returns the address of the
    /// samples one channel after the other - the left channel's `frame_count` samples, then the right channel's - as
    /// the browser hands a processor its output: one array for each channel. Valid until the next call.
    fn workletRender(frame_count: u32) callconv(.c) usize {
        // The block's timing, from the clocks' tie (`workletTimeBlock`): what the renderer measures its starts by.
        worklet_state.renderer_host.renderer.current_block_timing = worklet_state.next_block_timing;
        const interleaved_block: []const f32 = worklet_state.renderer_host.render(frame_count);
        worklet_state.renderer_host.renderer.current_block_timing = null;
        const left_channel: []f32 = worklet_state.channel_samples[0..frame_count];
        const right_channel: []f32 = worklet_state.channel_samples[frame_count .. 2 * frame_count];
        for (left_channel, right_channel, 0..) |*left_sample, *right_sample, frame_index| {
            const left_sample_index: usize = frame_index * channel_count;
            const right_sample_index: usize = left_sample_index + 1;
            left_sample.* = interleaved_block[left_sample_index];
            right_sample.* = interleaved_block[right_sample_index];
        }
        return @intFromPtr(&worklet_state.channel_samples);
    }

    /// Takes the renderer's notices into the notices buffer, and returns how many it took.
    fn workletTakeNotices() callconv(.c) u32 {
        const taken_notice_count: usize = worklet_state.renderer_host.takeNotices(&worklet_state.notices);
        return @intCast(taken_notice_count);
    }

    /// The address of the notices buffer: `workletTakeNotices`'s count of notices, `worklet_abi.notice_byte_count`
    /// bytes each.
    fn workletNoticesBuffer() callconv(.c) usize {
        return @intFromPtr(&worklet_state.notices);
    }

    /// Allocates a mixer's blocks, for tests that mix by hand (`Mixer.mixInto`) without an output.
    fn allocateTestBlocks(engine_mixer: *Mixer) Allocator.Error!void {
        const block_sample_count: usize = @as(usize, render_block_most_frames) * channel_count;
        engine_mixer.renderer.voice_scratch_samples = try testing_allocator.alloc(f32, block_sample_count);
    }

    fn freeTestBlocks(engine_mixer: *Mixer) void {
        testing_allocator.free(engine_mixer.renderer.voice_scratch_samples);
    }

    /// A test generator whose state is a count: each call adds one to it and writes it, over 64 - exact in binary, and
    /// within the -1..1 a mix is held to - into every sample it makes.
    fn generateTestCount(state: *anyopaque, frames: []f32, first_frame: u64) void {
        _ = first_frame;
        const count: *u32 = @ptrCast(@alignCast(state));
        count.* += 1;
        const count_float: f32 = @floatFromInt(count.*);
        @memset(frames, count_float / 64);
    }

    /// A test tone: a sine of amplitude 0.5 at the frequency its state holds (an `f32`), the same on both channels.
    fn generateTestSine(state: *anyopaque, frames: []f32, first_frame: u64) void {
        const frequency: *const f32 = @ptrCast(@alignCast(state));
        const rate: f32 = @floatFromInt(sample_rate);
        const frame_count: usize = frames.len / channel_count;
        for (0..frame_count) |frame_offset| {
            const frame_number: f32 = @floatFromInt(first_frame + frame_offset);
            const phase_turns: f32 = frequency.* * frame_number / rate;
            const value: f32 = 0.5 * sinTurns(phase_turns);
            frames[frame_offset * channel_count] = value;
            frames[frame_offset * channel_count + 1] = value;
        }
    }

    /// The name of a test's stand-in output.
    fn standInName() []const u8 {
        return "a test's stand-in";
    }

    /// How many times the left channel rises through zero - from below to at or above it. Over one second of a pure
    /// tone, that is its frequency.
    fn countRisingZeroCrossings(stereo_samples: []const f32) usize {
        const frame_count: usize = stereo_samples.len / channel_count;
        var crossing_count: usize = 0;
        var frame_index: usize = 1;
        while (frame_index < frame_count) : (frame_index += 1) {
            const left_before: f32 = stereo_samples[(frame_index - 1) * channel_count];
            const left_now: f32 = stereo_samples[frame_index * channel_count];
            if (left_before < 0 and left_now >= 0) {
                crossing_count += 1;
            }
        }
        return crossing_count;
    }

    test "a queue between two threads keeps its items in order, across the wrap of its counters" {
        const Queue = SingleProducerSingleConsumerQueue(u32, 8);
        var queue: Queue = .{};
        // Counters started just short of their largest value, so that they wrap within the test.
        const near_wrap: usize = zm.maxInt(usize) - 5;
        queue.pushing_side.pushed_count.raw = near_wrap;
        queue.pushing_side.popped_count_last_seen = near_wrap;
        queue.popping_side.popped_count.raw = near_wrap;
        queue.popping_side.pushed_count_last_seen = near_wrap;
        var item_number: u32 = 0;
        while (item_number < 8) : (item_number += 1) {
            try expect(queue.push(item_number));
        }
        try expect(!queue.push(99));
        item_number = 0;
        while (item_number < 8) : (item_number += 1) {
            try expectEqual(@as(?u32, item_number), queue.pop());
        }
        try expectEqual(@as(?u32, null), queue.pop());
        // And across threads: a hundred thousand items, each seen once, in order. A side that finds the queue full,
        // or empty, gives the processor up (`yield`): on a machine of one core, a side spinning instead would hold
        // it for the rest of its time slice before the other could run, a time slice per eight items, and the test
        // would take minutes. Where the system cannot yield, the side spins, as it did.
        const item_total: u32 = 100_000;
        const Pusher = struct {
            fn run(target: *Queue) void {
                var next_item: u32 = 0;
                while (next_item < item_total) {
                    if (target.push(next_item)) {
                        next_item += 1;
                    } else {
                        std.Thread.yield() catch std.atomic.spinLoopHint();
                    }
                }
            }
        };
        const pusher_thread: std.Thread = try .spawn(.{}, Pusher.run, .{&queue});
        var expected_item: u32 = 0;
        while (expected_item < item_total) {
            if (queue.pop()) |popped_item| {
                try expectEqual(expected_item, popped_item);
                expected_item += 1;
            } else {
                std.Thread.yield() catch std.atomic.spinLoopHint();
            }
        }
        pusher_thread.join();
    }

    test "a stream's ring: runs written and read in order, wrapping past its end, its room and its dry frames" {
        var ring_samples: [8 * 2]f32 = undefined;
        var ring: StreamRing = .initOver(&ring_samples, 2, sample_rate);
        try expectEqual(@as(usize, 8), ring.freeFrames());
        // Five frames in, three out: the next write of five wraps past the ring's end.
        const first_frames = [_]f32{ 1, -1, 2, -2, 3, -3, 4, -4, 5, -5 };
        try expectEqual(@as(usize, 5), ring.write(&first_frames));
        var read_out: [6]f32 = undefined;
        try expectEqual(@as(usize, 3), ring.read(&read_out));
        try expectEqualSlices(f32, &.{ 1, -1, 2, -2, 3, -3 }, &read_out);
        try expectEqual(@as(usize, 6), ring.freeFrames());
        const second_frames = [_]f32{ 6, -6, 7, -7, 8, -8, 9, -9, 10, -10, 11, -11, 12, -12 };
        // Room for six of the seven offered.
        try expectEqual(@as(usize, 6), ring.write(&second_frames));
        try expectEqual(@as(usize, 0), ring.freeFrames());
        var all_out: [16]f32 = undefined;
        try expectEqual(@as(usize, 8), ring.read(&all_out));
        try expectEqualSlices(f32, &.{ 4, -4, 5, -5, 6, -6, 7, -7, 8, -8, 9, -9, 10, -10, 11, -11 }, &all_out);
        // Empty: a read of two frames finds none, and counts both as dry; the count, taken, starts again.
        try expectEqual(@as(usize, 0), ring.read(read_out[0..4]));
        try expectEqual(@as(usize, 2), ring.takeDryFrames());
        try expectEqual(@as(usize, 0), ring.takeDryFrames());
    }

    test "a stream's ring between two threads keeps its frames in order, in runs of every length" {
        const frame_total: usize = 50_000;
        var ring_samples: [64]f32 = undefined;
        var ring: StreamRing = .initOver(&ring_samples, 1, sample_rate);
        const Writer = struct {
            fn writeAll(stream_ring: *StreamRing) void {
                var next_value: usize = 0;
                var run_length: usize = 1;
                var run: [37]f32 = undefined;
                while (next_value < frame_total) {
                    const run_frames: usize = @min(run_length, frame_total - next_value);
                    for (run[0..run_frames], 0..) |*sample, index| {
                        sample.* = float(next_value + index);
                    }
                    const written: usize = stream_ring.write(run[0..run_frames]);
                    next_value += written;
                    run_length = run_length % run.len + 1;
                }
            }
        };
        const writer_thread: std.Thread = try .spawn(.{}, Writer.writeAll, .{&ring});
        var expected_value: usize = 0;
        var run_length: usize = 1;
        var run: [29]f32 = undefined;
        while (expected_value < frame_total) {
            const read: usize = ring.read(run[0..run_length]);
            for (run[0..read]) |sample| {
                try expectEqual(float(expected_value), sample);
                expected_value += 1;
            }
            run_length = run_length % run.len + 1;
        }
        writer_thread.join();
    }

    test "a stream voice plays its ring's frames as written, then silence when the ring runs dry, counted" {
        var engine_mixer: Mixer = .{};
        try allocateTestBlocks(&engine_mixer);
        defer freeTestBlocks(&engine_mixer);
        // 300 frames of a mono 1000 Hz tone at the mixer's rate, in a ring of 512.
        var ring_samples: [512]f32 = undefined;
        var ring: StreamRing = .initOver(&ring_samples, 1, sample_rate);
        var tone_frames: [300]f32 = undefined;
        for (&tone_frames, 0..) |*tone_frame, frame_index| {
            tone_frame.* = 0.5 * sinTurns(1000 * float(frame_index) / float(sample_rate));
        }
        try expectEqual(@as(usize, 300), ring.write(&tone_frames));
        const stream_voice: Voice = engine_mixer.play(.{ .stream = .{ .ring = &ring } }, .{});
        try expect(stream_voice != .none);
        // Two blocks of 256 frames: the first the tone's first 256 frames, each times the centre's gain; the second its
        // last 44, then silence - the 212 frames the ring did not have.
        const centre_gain: f32 = gainsForPan(1, 0, .constant_power).left;
        const block_frames: usize = 256;
        var first_block: [block_frames * channel_count]f32 = undefined;
        engine_mixer.mixInto(&first_block);
        for (0..256) |frame_index| {
            const expected: f32 = tone_frames[frame_index] * centre_gain;
            try expectApproxEqAbs(expected, first_block[frame_index * channel_count], 1e-7);
            try expectApproxEqAbs(expected, first_block[frame_index * channel_count + 1], 1e-7);
        }
        var second_block: [block_frames * channel_count]f32 = undefined;
        engine_mixer.mixInto(&second_block);
        for (0..44) |frame_index| {
            const expected: f32 = tone_frames[256 + frame_index] * centre_gain;
            try expectApproxEqAbs(expected, second_block[frame_index * channel_count], 1e-7);
        }
        for (second_block[44 * channel_count ..]) |sample| {
            try expectEqual(@as(f32, 0), sample);
        }
        // Dry: the frames the second block's reads wanted and did not find - all the voice took past the 300th.
        try expect(ring.takeDryFrames() >= 212);
        try expect(engine_mixer.isPlaying(stream_voice));
    }

    test "a stream at half the mixer's rate: each of its frames spans two mixed frames, the line drawn between" {
        var engine_mixer: Mixer = .{};
        try allocateTestBlocks(&engine_mixer);
        defer freeTestBlocks(&engine_mixer);
        var ring_samples: [64]f32 = undefined;
        var ring: StreamRing = .initOver(&ring_samples, 1, sample_rate / 2);
        const ramp_frames = [_]f32{ 0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9 };
        _ = ring.write(&ramp_frames);
        // Panned hard left at constant power: the left channel carries the frames whole.
        _ = engine_mixer.play(.{ .stream = .{ .ring = &ring } }, .{ .pan = -1 });
        var block: [8 * channel_count]f32 = undefined;
        engine_mixer.mixInto(&block);
        // Mixed frame n is at source frame n / 2: on a frame, then halfway to the next.
        const expected_left = [_]f32{ 0, 0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.35 };
        for (expected_left, 0..) |expected, frame_index| {
            try expectApproxEqAbs(expected, block[frame_index * channel_count], 1e-6);
        }
    }

    test "the mixer: a centred tone at 0.707 a side, a stale voice_name naming nothing, samples at double pitch" {
        var engine_mixer: Mixer = .{};
        try allocateTestBlocks(&engine_mixer);
        defer freeTestBlocks(&engine_mixer);
        var tone_frequency: f32 = 1000;
        const tone_source: Source = .{ .generator = .{
            .generate = &generateTestSine,
            .initial_state = asBytes(&tone_frequency),
        } };
        const tone: Voice = engine_mixer.play(tone_source, .{});
        var tenth_of_a_second: [4800 * 2]f32 = undefined;
        engine_mixer.mixInto(&tenth_of_a_second);
        // 0.1 s of 1000 Hz: 100 rising zero crossings, give or take the one at the very start.
        const crossing_count: usize = countRisingZeroCrossings(&tenth_of_a_second);
        try expect(crossing_count >= 99 and crossing_count <= 100);
        var peak: f32 = 0;
        for (tenth_of_a_second) |mixed_sample| {
            peak = @max(peak, @abs(mixed_sample));
        }
        // Amplitude 0.5, at the centre 0.707 of it on each side.
        try expectApproxEqAbs(@as(f32, 0.5 * 0.70710678), peak, 0.001);
        engine_mixer.stopVoice(tone);
        try expect(!engine_mixer.isPlaying(tone));
        // The next voice reuses the slot under a new name; the old name, used again, changes nothing.
        const next_tone: Voice = engine_mixer.play(tone_source, .{});
        try expect(next_tone != tone);
        engine_mixer.setVolume(tone, 0);
        try expect(engine_mixer.isPlaying(next_tone));
        engine_mixer.stopVoice(next_tone);
        // The first tone, stopped once heard, fades out in the next mix and frees its slot.
        engine_mixer.mixInto(&tenth_of_a_second);
        try expectEqual(@as(u32, 0), engine_mixer.playingVoiceCount());
        // A ramp from 0 up by 0.01 per frame, played at double pitch: each mixed frame skips one source frame, so the
        // second mixed frame holds source frame 2 - the value 0.02. Panned hard left, the right channel is silent.
        var ramp_samples: [100]f32 = undefined;
        for (&ramp_samples, 0..) |*ramp_sample, ramp_index| {
            const ramp_index_float: f32 = @floatFromInt(ramp_index);
            ramp_sample.* = ramp_index_float / 100;
        }
        const ramp_source: Source = .{ .samples = .{
            .samples = &ramp_samples,
            .channels = 1,
            .sample_rate = sample_rate,
        } };
        const ramp: Voice = engine_mixer.play(ramp_source, .{ .pitch = 2, .pan = -1 });
        var short_block: [60 * 2]f32 = undefined;
        engine_mixer.mixInto(&short_block);
        try expectApproxEqAbs(@as(f32, 0.02), short_block[2], 0.0001);
        try expectApproxEqAbs(@as(f32, 0.0), short_block[3], 0.0001);
        // 100 source frames at double pitch last 50 mixed frames: the 60-frame block ran past the end, which ended
        // the voice.
        try expect(!engine_mixer.isPlaying(ramp));
    }

    test "a stereo source is balanced, unity at the centre; a mono one placed at constant power" {
        // Stereo at the centre: both sides as recorded. At pan 0.5: the left fades to cos(1/8 turn), the right stays.
        const stereo_centre: StereoGains = gainsForPan(1, 0, .balance);
        try expectApproxEqAbs(@as(f32, 1), stereo_centre.left, 0.0001);
        try expectApproxEqAbs(@as(f32, 1), stereo_centre.right, 0.0001);
        const stereo_half_right: StereoGains = gainsForPan(1, 0.5, .balance);
        try expectApproxEqAbs(@as(f32, 0.70710678), stereo_half_right.left, 0.0001);
        try expectApproxEqAbs(@as(f32, 1), stereo_half_right.right, 0.0001);
        const stereo_full_left: StereoGains = gainsForPan(1, -1, .balance);
        try expectApproxEqAbs(@as(f32, 0), stereo_full_left.right, 0.0001);
        // Mono at the centre: 0.707 each, the sum of their squares 1 at every pan.
        const mono_centre: StereoGains = gainsForPan(1, 0, .constant_power);
        try expectApproxEqAbs(@as(f32, 0.70710678), mono_centre.left, 0.0001);
        const mono_off_centre: StereoGains = gainsForPan(1, 0.3, .constant_power);
        const power: f32 = mono_off_centre.left * mono_off_centre.left + mono_off_centre.right * mono_off_centre.right;
        try expectApproxEqAbs(@as(f32, 1), power, 0.0001);
        // The law follows the source.
        const stereo_samples: [4]f32 = .{ 0, 0, 0, 0 };
        const stereo_source: Source = .{ .samples = .{
            .samples = &stereo_samples,
            .channels = 2,
            .sample_rate = 48_000,
        } };
        try expectEqual(PanLaw.balance, panLawOf(stereo_source));
        // So does a generator's: mono unless it says it is stereo.
        const mono_generator: Source = .{ .generator = .{ .generate = &generateTestSine } };
        try expectEqual(PanLaw.constant_power, panLawOf(mono_generator));
        const stereo_generator: Source = .{ .generator = .{
            .generate = &generateTestSine,
            .channels = 2,
        } };
        try expectEqual(PanLaw.balance, panLawOf(stereo_generator));
    }

    test "a looping source stepping past its whole length wraps by the remainder, reading only its own frames" {
        var engine_mixer: Mixer = .{};
        try allocateTestBlocks(&engine_mixer);
        defer freeTestBlocks(&engine_mixer);
        // Ten frames, frame i holding i / 16 - exact in binary, so interpolation adds no rounding.
        var ramp_samples: [10]f32 = undefined;
        for (&ramp_samples, 0..) |*ramp_sample, ramp_index| {
            const ramp_index_float: f32 = @floatFromInt(ramp_index);
            ramp_sample.* = ramp_index_float / 16;
        }
        // At the mixer's rate and pitch 25.25, each mixed frame steps 25.25 frames through a 10-frame loop - more than
        // twice its length. Wrapped by the remainder, the positions are 0, 5.25, 0.5 (30.5 less three lengths), 5.75;
        // wrapped by one subtraction of the length, the second would be 15.25 - past the end.
        const ramp_source: Source = .{ .samples = .{
            .samples = &ramp_samples,
            .channels = 1,
            .sample_rate = sample_rate,
            .is_looping = true,
        } };
        const ramp: Voice = engine_mixer.play(ramp_source, .{ .pitch = 25.25, .pan = -1 });
        var block: [4 * 2]f32 = undefined;
        engine_mixer.mixInto(&block);
        try expect(engine_mixer.isPlaying(ramp));
        try expectApproxEqAbs(@as(f32, 0), block[0], 0.001);
        try expectApproxEqAbs(@as(f32, 5.25 / 16.0), block[2], 0.001);
        try expectApproxEqAbs(@as(f32, 0.5 / 16.0), block[4], 0.001);
        try expectApproxEqAbs(@as(f32, 5.75 / 16.0), block[6], 0.001);
        // A source of no channels, or of no rate, is refused.
        const no_channels: Source = .{ .samples = .{
            .samples = &ramp_samples,
            .channels = 0,
            .sample_rate = sample_rate,
        } };
        try expectEqual(Voice.none, engine_mixer.play(no_channels, .{}));
        const no_rate: Source = .{ .samples = .{ .samples = &ramp_samples, .channels = 1, .sample_rate = 0 } };
        try expectEqual(Voice.none, engine_mixer.play(no_rate, .{}));
    }

    test "a generator's state is the voice's own: copied when it plays, changed by it alone" {
        var engine_mixer: Mixer = .{};
        try allocateTestBlocks(&engine_mixer);
        defer freeTestBlocks(&engine_mixer);
        var starting_count: u32 = 10;
        const count_source: Source = .{ .generator = .{
            .generate = &generateTestCount,
            .initial_state = asBytes(&starting_count),
        } };
        const first_voice: Voice = engine_mixer.play(count_source, .{ .pan = -1 });
        var block: [4 * 2]f32 = undefined;
        // One block: the first voice counts 11.
        engine_mixer.mixInto(&block);
        try expectApproxEqAbs(@as(f32, 11.0 / 64.0), block[0], 0.0001);
        // A second voice from the same source starts from its own copy, 10, while the first goes on: 12 and 11.
        _ = engine_mixer.play(count_source, .{ .pan = -1 });
        engine_mixer.mixInto(&block);
        try expectApproxEqAbs(@as(f32, (12.0 + 11.0) / 64.0), block[0], 0.0001);
        // The caller's state is untouched; and a state larger than a voice holds is refused.
        try expectEqual(@as(u32, 10), starting_count);
        try expect(engine_mixer.isPlaying(first_voice));
        const oversized_state: [generator_state_capacity + 1]u8 = @splat(0);
        const oversized_source: Source = .{ .generator = .{
            .generate = &generateTestCount,
            .initial_state = &oversized_state,
        } };
        const saved_log_level: std.log.Level = std.testing.log_level;
        std.testing.log_level = .err; // the refusal's warning IS the behaviour; keep a passing test silent
        defer std.testing.log_level = saved_log_level;
        try expectEqual(Voice.none, engine_mixer.play(oversized_source, .{}));
    }

    test "a paused voice fades out, is not mixed, keeps its slot, and resumes where it fell silent" {
        var engine_mixer: Mixer = .{};
        try allocateTestBlocks(&engine_mixer);
        defer freeTestBlocks(&engine_mixer);
        var tone_frequency: f32 = 1000;
        const tone_source: Source = .{ .generator = .{
            .generate = &generateTestSine,
            .initial_state = asBytes(&tone_frequency),
        } };
        const tone: Voice = engine_mixer.play(tone_source, .{});
        var block: [300 * 2]f32 = undefined;
        engine_mixer.mixInto(block[0 .. 100 * 2]);
        const voice_slot: *VoiceSlot = engine_mixer.renderer.playingSlotNamedBy(tone).?;
        try expectEqual(@as(u64, 100), voice_slot.generated_frame_count);
        // Paused: at once by name; in the next mix it fades over 240 frames, its source moving on by those only.
        engine_mixer.pauseVoice(tone);
        try expect(engine_mixer.isPaused(tone));
        engine_mixer.mixInto(&block);
        try expectEqual(@as(u64, 100 + fade_out_frames), voice_slot.generated_frame_count);
        for (block[fade_out_frames * channel_count ..]) |mixed_sample| {
            try expectEqual(@as(f32, 0), mixed_sample);
        }
        // Then silent, still named, its place kept.
        engine_mixer.mixInto(&block);
        for (block) |mixed_sample| {
            try expectEqual(@as(f32, 0), mixed_sample);
        }
        try expect(engine_mixer.isPlaying(tone) and engine_mixer.isPaused(tone));
        try expectEqual(@as(u64, 100 + fade_out_frames), voice_slot.generated_frame_count);
        // Resumed: it continues from where it fell silent, its gains ramping up from silence across the block.
        engine_mixer.resumeVoice(tone);
        engine_mixer.mixInto(&block);
        try expectEqual(@as(u64, 100 + fade_out_frames + 300), voice_slot.generated_frame_count);
        const rate: f32 = @floatFromInt(sample_rate);
        const last_frame_number: f32 = @floatFromInt(100 + fade_out_frames + 299);
        const expected_last: f32 = 0.5 * 0.70710678 * sinTurns(1000 * last_frame_number / rate);
        const last_sample_index: usize = 299 * @as(usize, channel_count);
        try expectApproxEqAbs(expected_last, block[last_sample_index], 0.0001);
    }

    test "the worklet's entry points render and let go as a renderer reached by its queues" {
        // The reference: a renderer reached by its queues, on this thread.
        var local_mixer: Mixer = .{};
        try allocateTestBlocks(&local_mixer);
        defer freeTestBlocks(&local_mixer);
        // The other: a main side whose commands reach the worklet's entry points, as the worklet's program hands
        // them on - bytes into the command buffer, samples into the room given for them.
        var main_side: Mixer = .{};
        try allocateTestBlocks(&main_side);
        defer freeTestBlocks(&main_side);
        main_side.is_renderer_on_another_thread = true;
        worklet_state.allocator = testing_allocator;
        try expectEqual(@as(u32, 1), workletStart());
        defer {
            worklet_state.renderer_host.stop();
            worklet_state = .{};
        }
        const EntryPointSink = struct {
            fn sendCommandBytes(context: *anyopaque, command_bytes: []const u8) void {
                _ = context;
                const command_buffer: [*]u8 = workletCommandBuffer();
                @memcpy(command_buffer[0..command_bytes.len], command_bytes);
                workletAcceptCommand();
            }

            fn sendSamples(
                context: *anyopaque,
                samples_id: SamplesId,
                samples: []const f32,
            ) void {
                _ = context;
                const sample_count: u32 = @intCast(samples.len);
                const room_address: usize = workletAllocateSamples(samples_id, sample_count);
                if (room_address == 0) {
                    zm.assertUnreachable(@src(), "the worklet had no room for samples {d}", .{samples_id});
                }
                const room: [*]f32 = @ptrFromInt(room_address);
                @memcpy(room[0..samples.len], samples);
                workletRegisterSamples(samples_id);
            }

            fn sendNote(context: *anyopaque, note_event: NoteEvent) void {
                _ = context;
                workletAcceptNote(note_event.key, @intFromBool(note_event.is_down), note_event.velocity);
            }
        };
        var unused_context: u8 = 0;
        const command_sink: CommandSink = .{
            .context = &unused_context,
            .send_command_bytes = &EntryPointSink.sendCommandBytes,
            .send_samples = &EntryPointSink.sendSamples,
            .send_note = &EntryPointSink.sendNote,
        };
        // The same sounds on both: a ramp of samples - the other side's own buffer, to be released - and a tone.
        var local_ramp: [960]f32 = undefined;
        for (&local_ramp, 0..) |*ramp_sample, ramp_index| {
            const ramp_index_float: f32 = @floatFromInt(ramp_index);
            ramp_sample.* = ramp_index_float / 2048;
        }
        const owned_ramp: []f32 = try testing_allocator.dupe(f32, &local_ramp);
        var tone_frequency: f32 = 440;
        const tone_source: Source = .{ .generator = .{
            .generate = &generateTestSine,
            .initial_state = asBytes(&tone_frequency),
        } };
        _ = local_mixer.play(.{ .samples = .{ .samples = &local_ramp, .channels = 1, .sample_rate = 24_000 } }, .{});
        _ = local_mixer.play(tone_source, .{ .pan = 0.5, .pitch = 1.5 });
        _ = main_side.play(.{ .samples = .{ .samples = owned_ramp, .channels = 1, .sample_rate = 24_000 } }, .{});
        _ = main_side.play(tone_source, .{ .pan = 0.5, .pitch = 1.5 });
        forwardCommands(&main_side, command_sink);
        // Three quanta of 128 frames, as the worklet renders them - one channel after the other: the same samples,
        // bit for bit.
        var local_block: [128 * 2]f32 = undefined;
        var block_number: usize = 0;
        while (block_number < 3) : (block_number += 1) {
            local_mixer.mixInto(&local_block);
            const rendered_address: usize = workletRender(128);
            const rendered_samples: [*]const f32 = @ptrFromInt(rendered_address);
            for (0..128) |frame_index| {
                const local_left: f32 = local_block[frame_index * 2];
                const local_right: f32 = local_block[frame_index * 2 + 1];
                try expectEqual(local_left, rendered_samples[frame_index]);
                try expectEqual(local_right, rendered_samples[128 + frame_index]);
            }
        }
        // Released on the main side: the worklet's copy goes when its renderer lets go, the main side's own buffer
        // when the notice comes back - the testing allocator would report either leaked, or freed twice.
        main_side.releaseSamples(testing_allocator, owned_ramp);
        forwardCommands(&main_side, command_sink);
        _ = workletRender(128);
        const notice_count: u32 = workletTakeNotices();
        try expect(notice_count >= 1);
        const notices: [*]const RendererNotice = @ptrFromInt(workletNoticesBuffer());
        acceptNotices(&main_side, notices[0..notice_count]);
        main_side.readRendererNotices();
        try expect(!main_side.samples_registry[0].is_registered);
    }

    test "a warmed-up host renders as one never warmed, with no voice playing and nothing queued" {
        // Two hosts, one warmed up: the warm-up plays in a scratch host of its own, so this one must not tell.
        var warmed_host: RendererHost = .{};
        try warmed_host.start(testing_allocator);
        defer warmed_host.stop();
        var plain_host: RendererHost = .{};
        try plain_host.start(testing_allocator);
        defer plain_host.stop();
        // The testing allocator reports anything the scratch host leaves allocated.
        try warmed_host.warmUp();
        for (&warmed_host.renderer.voice_slots) |*voice_slot| {
            try expect(!voice_slot.is_playing);
            try expectEqual(@as(u24, 0), voice_slot.generation);
        }
        try expect(warmed_host.renderer_queues.commands.pop() == null);
        try expect(warmed_host.renderer_queues.notices.pop() == null);
        try expect(warmed_host.renderer_queues.latency.pop() == null);
        try expectEqual(@as(f32, 0), warmed_host.takePeak());
        // The same sound on both, a tone in slot 0: bit for bit the same blocks.
        var tone_frequency: f32 = 440;
        var tone_play: VoiceToStart = .{
            .voice = .ofSlot(0, 0),
            .source = .{ .generator = .{ .generate = &generateTestSine, .channels = channel_count } },
            .options = .{ .pan = 0.5 },
        };
        @memcpy(tone_play.generator_state[0..@sizeOf(f32)], asBytes(&tone_frequency));
        try expect(warmed_host.renderer_queues.commands.push(.{ .play = tone_play }));
        try expect(plain_host.renderer_queues.commands.push(.{ .play = tone_play }));
        for (0..4) |_| {
            const warmed_block: []const f32 = warmed_host.render(128);
            const plain_block: []const f32 = plain_host.render(128);
            try expectEqualSlices(f32, plain_block, warmed_block);
        }
        try expect(warmed_host.takePeak() > 0.1);
    }

    /// A host playing ramps released under their voices, for the tail-copy test below: for each voice, a mono ramp
    /// registered under the id of the voice's own slot - its samples counting up from `first_value` by 1/4096, read
    /// at 24 000 Hz and pitch 1.5, so that the copy is read between samples - panned hard to the side `pans` gives
    /// it. Renders one block, releases every ramp in the same block, then renders `released_block_count` blocks
    /// into `rendered`, one after another.
    fn renderReleasedRamps(
        first_values: []const f32,
        pans: []const f32,
        rendered: []f32,
        released_block_count: usize,
    ) !void {
        var renderer_host: RendererHost = .{};
        try renderer_host.start(testing_allocator);
        defer renderer_host.stop();
        const ramp_frame_count: usize = 2_048;
        for (first_values, pans, 0..) |first_value, pan, slot_index| {
            const samples_id: SamplesId = @intCast(slot_index);
            const ramp: []f32 = try renderer_host.allocateUploadedSamples(samples_id, ramp_frame_count);
            for (ramp, 0..) |*ramp_sample, ramp_index| {
                ramp_sample.* = first_value + float(ramp_index) / 4096;
            }
            renderer_host.registerUploadedSamples(samples_id);
            const ramp_play: VoiceToStart = .{
                .voice = .ofSlot(slot_index, 0),
                .source = .{ .samples = .{
                    .samples_id = samples_id,
                    .channels = 1,
                    .sample_rate = 24_000,
                    .is_looping = false,
                } },
                .options = .{ .pan = pan, .pitch = 1.5 },
            };
            try expect(renderer_host.renderer_queues.commands.push(.{ .play = ramp_play }));
        }
        const block_frame_count: usize = 128;
        _ = renderer_host.render(block_frame_count);
        for (0..first_values.len) |slot_index| {
            const samples_id: SamplesId = @intCast(slot_index);
            try expect(renderer_host.renderer_queues.commands.push(.{ .release_samples = samples_id }));
        }
        const block_sample_count: usize = block_frame_count * channel_count;
        for (0..released_block_count) |block_index| {
            const rendered_block: []const f32 = renderer_host.render(block_frame_count);
            @memcpy(rendered[block_index * block_sample_count ..][0..block_sample_count], rendered_block);
        }
        var renderer_notices: [16]RendererNotice = undefined;
        _ = renderer_host.takeNotices(&renderer_notices);
    }

    test "a renderer's own side finding a queue full applies it at once: nothing dropped, nothing trapped" {
        var renderer_host: RendererHost = .{};
        try renderer_host.start(testing_allocator);
        defer renderer_host.stop();
        // Three queues' worth of commands and of notes, with no block asked for between them - as while the audio
        // context is suspended and the worklet still takes its messages.
        const command_count: usize = 3 * 1024;
        for (0..command_count) |command_index| {
            const volume: f32 = float(command_index) / float(command_count);
            var command: RendererCommand = .{ .set_master_volume = volume };
            renderer_host.acceptCommandBytes(asBytes(&command));
        }
        const note_count: usize = 3 * 256;
        for (0..note_count) |note_index| {
            const is_down: bool = note_index % 2 == 0;
            try expect(renderer_host.acceptNote(.{ .key = 60, .is_down = is_down, .velocity = 0.5 }));
        }
        _ = renderer_host.render(128);
        // Applied in order: the last volume sent is the one in force.
        const last_volume: f32 = float(command_count - 1) / float(command_count);
        try expectEqual(last_volume, renderer_host.renderer.master_volume);
    }

    test "a host in another memory plays a forwarded stream from its own ring, and reports what was read" {
        var renderer_host: RendererHost = .{};
        try renderer_host.start(testing_allocator);
        defer renderer_host.stop();
        // A sine of 750 Hz at 48 000 Hz - 64 frames to a period - mono, at 0.5: sent in two messages, as two frames'
        // forwarding would send it.
        const stream: ForwardedStream = .{ .id = 3, .channels = 1, .sample_rate = 48_000 };
        var sine_frames: [1024]f32 = undefined;
        for (&sine_frames, 0..) |*frame, frame_index| {
            const phase: f32 = float(frame_index % 64) / 64;
            frame.* = 0.5 * sinTurns(phase);
        }
        renderer_host.acceptStreamFrames(stream, sine_frames[0..512]);
        renderer_host.acceptStreamFrames(stream, sine_frames[512..]);
        // The voice's start, as it is forwarded: the stream by its number.
        var play_command: RendererCommand = .{ .play = .{
            .voice = .ofSlot(1, 1),
            .source = .{ .forwarded_stream = stream },
            .options = .{},
        } };
        renderer_host.acceptCommandBytes(asBytes(&play_command));
        // Four blocks of 128 frames: 512 of the ring's frames, the sine panned to the middle - 0.5 times the
        // constant-power gain of 0.707 on each side.
        var peak: f32 = 0;
        for (0..4) |_| {
            const rendered_block: []const f32 = renderer_host.render(128);
            for (rendered_block) |rendered_sample| {
                peak = @max(peak, @abs(rendered_sample));
            }
        }
        try expect(peak > 0.3 and peak < 0.4);
        // Its report: 514 frames read - the 512 played and the two its interpolation's window takes when the voice
        // begins (`StreamPuller`) - none wanted and missing.
        var renderer_notices: [8]RendererNotice = undefined;
        const notice_count: usize = renderer_host.takeNotices(&renderer_notices);
        var stream_read: ?StreamRead = null;
        for (renderer_notices[0..notice_count]) |renderer_notice| {
            switch (renderer_notice) {
                .stream_read => |reported| stream_read = reported,
                .voice_ended, .samples_released, .start_measured => {},
            }
        }
        try expect(stream_read != null);
        try expectEqual(@as(ForwardedStreamId, 3), stream_read.?.id);
        try expectEqual(@as(u32, 512 + 2), stream_read.?.read_frames);
        try expectEqual(@as(u16, 0), stream_read.?.dry_frames);
        // Read once, reported once: nothing more to say until its voice reads again.
        try expectEqual(@as(usize, 0), renderer_host.takeNotices(&renderer_notices));
        // Given up, its voice stopped first as the main side does: the ring is freed.
        var stop_command: RendererCommand = .{ .stop = .ofSlot(1, 1) };
        renderer_host.acceptCommandBytes(asBytes(&stop_command));
        for (0..4) |_| {
            _ = renderer_host.render(128);
        }
        var release_command: RendererCommand = .{ .release_stream = 3 };
        renderer_host.acceptCommandBytes(asBytes(&release_command));
        try expect(renderer_host.stream_rings[3] == null);
    }

    test "a host's forwarded stream run dry is reported, though its voice reads nothing" {
        var renderer_host: RendererHost = .{};
        try renderer_host.start(testing_allocator);
        defer renderer_host.stop();
        // Started with no frames sent yet: its voice reads nothing, and every frame it wants is missing.
        const stream: ForwardedStream = .{ .id = 5, .generation = 7, .channels = 2, .sample_rate = 48_000 };
        var play_command: RendererCommand = .{ .play = .{
            .voice = .ofSlot(2, 1),
            .source = .{ .forwarded_stream = stream },
            .options = .{},
        } };
        renderer_host.acceptCommandBytes(asBytes(&play_command));
        _ = renderer_host.render(128);
        var renderer_notices: [8]RendererNotice = undefined;
        const notice_count: usize = renderer_host.takeNotices(&renderer_notices);
        var stream_read: ?StreamRead = null;
        for (renderer_notices[0..notice_count]) |renderer_notice| {
            switch (renderer_notice) {
                .stream_read => |reported| stream_read = reported,
                .voice_ended, .samples_released, .start_measured => {},
            }
        }
        try expect(stream_read != null);
        try expectEqual(@as(ForwardedStreamId, 5), stream_read.?.id);
        try expectEqual(@as(u8, 7), stream_read.?.generation);
        try expectEqual(@as(u32, 0), stream_read.?.read_frames);
        try expect(stream_read.?.dry_frames >= 128);
    }

    test "a main side handed more notices than its queue holds reads the waiting ones, and traps on none" {
        var engine_mixer: Mixer = .{};
        // Twice the queue's worth of reports, as a hidden page's worklet sends them while its frames have stopped: no
        // stream is forwarded, so each is read as late, and dropped - but each is taken.
        const late_read: StreamRead = .{ .id = 0, .generation = 1, .dry_frames = 0, .read_frames = 0 };
        const report: RendererNotice = .{ .stream_read = late_read };
        var reports: [64]RendererNotice = @splat(report);
        for (0..2 * notice_queue_capacity / reports.len) |_| {
            acceptNotices(&engine_mixer, &reports);
        }
        engine_mixer.readRendererNotices();
        try expect(engine_mixer.renderer_queues.notices.pop() == null);
    }

    test "a mixer on its own thread sends notes past a full queue: each is applied, none refused" {
        var engine_mixer: Mixer = .{};
        try allocateTestBlocks(&engine_mixer);
        defer freeTestBlocks(&engine_mixer);
        for (0..3 * 256) |note_index| {
            const is_down: bool = note_index % 2 == 0;
            try expect(engine_mixer.sendNote(.{ .key = 64, .is_down = is_down, .velocity = 0.5 }));
        }
    }

    test "two voices fading over their copies at once, in neighbouring slots, are each heard as its own" {
        // Hard left and hard right: under the constant-power law a mono voice panned to one side has a gain of
        // exactly 0 on the other, so each channel below is one voice alone.
        const released_block_count: usize = 3;
        const rendered_sample_count: usize = released_block_count * 128 * channel_count;
        var together: [rendered_sample_count]f32 = undefined;
        try renderReleasedRamps(&.{ 0.25, -0.5 }, &.{ -1, 1 }, &together, released_block_count);
        var left_alone: [rendered_sample_count]f32 = undefined;
        try renderReleasedRamps(&.{0.25}, &.{-1}, &left_alone, released_block_count);
        var right_alone: [rendered_sample_count]f32 = undefined;
        // The right voice in slot 1, as it is together; slot 0 holds another ramp, panned hard left, which the right
        // channel does not hear.
        try renderReleasedRamps(&.{ 0, -0.5 }, &.{ -1, 1 }, &right_alone, released_block_count);
        var heard_fade: bool = false;
        for (0..rendered_sample_count / channel_count) |frame_index| {
            const left_index: usize = frame_index * channel_count;
            const right_index: usize = left_index + 1;
            // Bit for bit: each voice's copy is its own, whichever slot sits beside it.
            try expectEqual(left_alone[left_index], together[left_index]);
            try expectEqual(right_alone[right_index], together[right_index]);
            heard_fade = heard_fade or together[left_index] != 0;
        }
        // The fade is heard, and ends: each voice is over within its 240 frames.
        try expect(heard_fade);
        const last_frame_left: f32 = together[rendered_sample_count - channel_count];
        const last_frame_right: f32 = together[rendered_sample_count - 1];
        try expectEqual(@as(f32, 0), last_frame_left);
        try expectEqual(@as(f32, 0), last_frame_right);
    }

    /// The amplitude of the sine at `frequency_hz` in `mono_samples`, measured as a Fourier coefficient under the
    /// window `hann_window` - one weight per sample, tapering both ends - so that a partial an octave away, 12.5 Hz
    /// or more from it over a second, leaks into it by under 2e-4 of its own amplitude. A sine of amplitude `a` at
    /// exactly that frequency measures `a`. The rotation by the frequency is a phasor turned one step per sample, put
    /// back on its exact angle every 4 096 samples, so that its rounding cannot pile up.
    fn measureSineAmplitude(
        mono_samples: []const f32,
        hann_window: []const f64,
        frequency_hz: f64,
    ) f64 {
        const step_turns: f64 = frequency_hz / float64(sample_rate);
        const step_cosine: f64 = cosTurns(step_turns);
        const step_sine: f64 = sinTurns(step_turns);
        var phasor_cosine: f64 = 1;
        var phasor_sine: f64 = 0;
        var real_sum: f64 = 0;
        var imaginary_sum: f64 = 0;
        var window_sum: f64 = 0;
        for (mono_samples, hann_window, 0..) |sample, window_weight, sample_index| {
            const resync_interval: usize = 4_096;
            if (sample_index % resync_interval == 0) {
                const angle_unwrapped_turns: f64 = step_turns * float64(sample_index);
                const angle_turns: f64 = angle_unwrapped_turns - @floor(angle_unwrapped_turns);
                phasor_cosine = cosTurns(angle_turns);
                phasor_sine = sinTurns(angle_turns);
            }
            const sample_wide: f64 = sample;
            const weighted_sample: f64 = window_weight * sample_wide;
            real_sum += weighted_sample * phasor_cosine;
            imaginary_sum += weighted_sample * phasor_sine;
            window_sum += window_weight;
            const next_cosine: f64 = phasor_cosine * step_cosine - phasor_sine * step_sine;
            const next_sine: f64 = phasor_cosine * step_sine + phasor_sine * step_cosine;
            phasor_cosine = next_cosine;
            phasor_sine = next_sine;
        }
        const magnitude: f64 = sqrt(real_sum * real_sum + imaginary_sum * imaginary_sum);
        return 2 * magnitude / window_sum;
    }

    /// A Hann window over `weights.len` samples: `0.5 - 0.5 cos(2 pi n / N)`, zero at the start, one in the middle.
    fn fillHannWindow(weights: []f64) void {
        const weight_count: f64 = float64(weights.len);
        for (weights, 0..) |*weight, weight_index| {
            weight.* = 0.5 - 0.5 * cosTurns(float64(weight_index) / weight_count);
        }
    }

    /// The frequencies of a Shepard note's ten partials, worked out apart from the instrument: the key's frequency
    /// (A at 440 Hz, a semitone a key), halved until it is under 25 Hz - the lowest partial, between 12.5 and 25 Hz,
    /// five octaves below the bell's centre - then doubled nine times.
    fn shepardPartialFrequencies(key: u8) [shepard_partial_count]f64 {
        var frequency: f64 = 440 * exp2((float64(key) - 69) / 12);
        while (frequency >= 25) {
            frequency /= 2;
        }
        var partial_frequencies: [shepard_partial_count]f64 = undefined;
        for (&partial_frequencies) |*partial_frequency| {
            partial_frequency.* = frequency;
            frequency *= 2;
        }
        return partial_frequencies;
    }

    test "the twelve Shepard notes: the centroid at the bell's centre within a cent, the same loudness, peaks under 1" {
        const frame_count: usize = sample_rate;
        const stereo_frames: []f32 = try testing_allocator.alloc(f32, frame_count * channel_count);
        defer testing_allocator.free(stereo_frames);
        const mono_samples: []f32 = try testing_allocator.alloc(f32, frame_count);
        defer testing_allocator.free(mono_samples);
        const hann_window: []f64 = try testing_allocator.alloc(f64, frame_count);
        defer testing_allocator.free(hann_window);
        fillHannWindow(hann_window);
        // The loudness a note should have at velocity 1, from the bell alone: its partials' powers, `a^2 / 2` each,
        // summed - the squared bell sampled at unit spacing has the area `sigma sqrt(pi)` - over the scale squared.
        const bell_area: f64 = shepard_bell_width_octaves * sqrt(@as(f64, 2 * pi));
        const squared_bell_area: f64 = shepard_bell_width_octaves * sqrt(@as(f64, pi));
        const expected_rms: f64 = sqrt(squared_bell_area / 2) / bell_area;
        var quietest_rms: f64 = 1;
        var loudest_rms: f64 = 0;
        for (60..72) |key_index| {
            const key: u8 = @intCast(key_index);
            var note_state: [generator_state_capacity]u8 align(16) = undefined;
            shepard_instrument.start_note(&note_state, key, 1);
            shepard_instrument.generate(&note_state, stereo_frames, 0);
            var peak: f32 = 0;
            var squared_sum: f64 = 0;
            for (mono_samples, 0..) |*mono_sample, frame_index| {
                const left_sample: f32 = stereo_frames[frame_index * channel_count];
                try expectEqual(left_sample, stereo_frames[frame_index * channel_count + 1]);
                mono_sample.* = left_sample;
                peak = @max(peak, @abs(left_sample));
                if (frame_index >= shepard_attack_frames) {
                    const left_sample_wide: f64 = left_sample;
                    squared_sum += left_sample_wide * left_sample_wide;
                }
            }
            try expect(peak <= 1);
            // The centroid, weighted by each partial's measured amplitude, in octaves from the bell's centre.
            var weighted_octaves_sum: f64 = 0;
            var amplitude_sum: f64 = 0;
            for (shepardPartialFrequencies(key)) |partial_frequency| {
                const amplitude: f64 = measureSineAmplitude(mono_samples, hann_window, partial_frequency);
                weighted_octaves_sum += amplitude * log2(partial_frequency / shepard_bell_centre_hz);
                amplitude_sum += amplitude;
            }
            const centroid_octaves: f64 = weighted_octaves_sum / amplitude_sum;
            const one_cent_octaves: f64 = 1.0 / 1200.0;
            try expect(@abs(centroid_octaves) < one_cent_octaves);
            const measured_frame_count: f64 = float64(frame_count - shepard_attack_frames);
            const rms: f64 = sqrt(squared_sum / measured_frame_count);
            try expectApproxEqAbs(expected_rms, rms, expected_rms * 0.01);
            quietest_rms = @min(quietest_rms, rms);
            loudest_rms = @max(loudest_rms, rms);
        }
        // 0.1 dB is a ratio of amplitudes of 10^(0.1 / 20).
        const ratio_of_a_tenth_of_a_decibel: f64 = 1.011579;
        try expect(loudest_rms / quietest_rms < ratio_of_a_tenth_of_a_decibel);
    }

    test "a Shepard note rises from silence over its attack: frame n is at most n / 96 of the velocity" {
        const velocity: f32 = 0.8;
        var note_state: [generator_state_capacity]u8 align(16) = undefined;
        shepard_instrument.start_note(&note_state, 67, velocity);
        var stereo_frames: [@as(usize, 128) * channel_count]f32 = undefined;
        shepard_instrument.generate(&note_state, &stereo_frames, 0);
        try expectEqual(@as(f32, 0), stereo_frames[0]);
        var loudest_during_attack: f32 = 0;
        for (1..shepard_attack_frames + 1) |frame_index| {
            const attack_fraction: f32 = float(frame_index) / float(shepard_attack_frames);
            const ceiling: f32 = velocity * attack_fraction * 1.0001 + 1.0e-6;
            const sample: f32 = stereo_frames[frame_index * channel_count];
            try expect(@abs(sample) <= ceiling);
            loudest_during_attack = @max(loudest_during_attack, @abs(sample));
        }
        // And it does sound: the ceiling is reached, not merely respected.
        try expect(loudest_during_attack > 0.1);
        // A held note is never silent, though it starts at level 0; released, it falls silent.
        try expect(!shepard_instrument.has_fallen_silent(&note_state));
        shepard_instrument.release_note(&note_state);
        const one_second_frames: []f32 = try testing_allocator.alloc(f32, sample_rate * channel_count);
        defer testing_allocator.free(one_second_frames);
        shepard_instrument.generate(&note_state, one_second_frames, 128);
        try expect(shepard_instrument.has_fallen_silent(&note_state));
    }

    test "a chord of three Shepard notes sounds at once, each at its own partials, and ends after its release" {
        var renderer_host: RendererHost = .{};
        try renderer_host.start(testing_allocator);
        defer renderer_host.stop();
        try expect(renderer_host.renderer_queues.commands.push(.{ .set_instrument = shepard_instrument }));
        const chord_keys: [3]u8 = .{ 60, 64, 67 };
        const velocity: f32 = 0.5;
        for (chord_keys) |key| {
            try expect(renderer_host.acceptNote(.{ .key = key, .is_down = true, .velocity = velocity }));
        }
        // A second of the chord, block by block, its left channel kept.
        const block_frame_count: usize = 128;
        const block_count: usize = sample_rate / block_frame_count;
        const mono_samples: []f32 = try testing_allocator.alloc(f32, block_count * block_frame_count);
        defer testing_allocator.free(mono_samples);
        for (0..block_count) |block_index| {
            const rendered_block: []const f32 = renderer_host.render(block_frame_count);
            const block_mono_samples: []f32 = mono_samples[block_index * block_frame_count ..][0..block_frame_count];
            for (block_mono_samples, 0..) |*mono_sample, frame_offset| {
                mono_sample.* = rendered_block[frame_offset * channel_count];
            }
        }
        var sounding_slot_count: usize = 0;
        for (first_instrument_slot..voice_capacity) |slot_index| {
            if (renderer_host.renderer.voice_slots[slot_index].is_playing) {
                sounding_slot_count += 1;
            }
        }
        try expectEqual(@as(usize, 3), sounding_slot_count);
        // Each note's partial nearest the bell's centre, at the amplitude the bell gives it, times the velocity and
        // the centre's gain: all three heard at once.
        const hann_window: []f64 = try testing_allocator.alloc(f64, mono_samples.len);
        defer testing_allocator.free(hann_window);
        fillHannWindow(hann_window);
        const bell_area: f64 = shepard_bell_width_octaves * sqrt(@as(f64, 2 * pi));
        const centre_gain: f64 = sinTurns(@as(f64, 0.125));
        for (chord_keys) |key| {
            var nearest_frequency: f64 = 0;
            var nearest_octaves: f64 = shepard_reach_octaves;
            for (shepardPartialFrequencies(key)) |partial_frequency| {
                const octaves_from_centre: f64 = log2(partial_frequency / shepard_bell_centre_hz);
                if (@abs(octaves_from_centre) < @abs(nearest_octaves)) {
                    nearest_octaves = octaves_from_centre;
                    nearest_frequency = partial_frequency;
                }
            }
            const bell_height: f64 = exp(-0.5 * nearest_octaves * nearest_octaves);
            const expected_amplitude: f64 = velocity * centre_gain * bell_height / bell_area;
            const measured_amplitude: f64 = measureSineAmplitude(mono_samples, hann_window, nearest_frequency);
            try expectApproxEqAbs(expected_amplitude, measured_amplitude, expected_amplitude * 0.01);
        }
        // Released: within a second every note has fallen silent and given its slot back.
        for (chord_keys) |key| {
            try expect(renderer_host.acceptNote(.{ .key = key, .is_down = false }));
        }
        for (0..block_count) |_| {
            _ = renderer_host.render(block_frame_count);
        }
        for (first_instrument_slot..voice_capacity) |slot_index| {
            try expect(!renderer_host.renderer.voice_slots[slot_index].is_playing);
        }
    }

    /// A test generator multiplying the two numbers in its state - read at run time, so that the compiler cannot
    /// work the product out itself - and writing the product into its first frame, zeros after it.
    fn generateTestProduct(state: *anyopaque, frames: []f32, first_frame: u64) void {
        _ = first_frame;
        const factors: *const [2]f32 = @ptrCast(@alignCast(state));
        @memset(frames, 0);
        const product: f32 = factors[0] * factors[1];
        frames[0] = product;
        frames[1] = product;
    }

    test "the click watch counts a step, and not the smoothest tone at a chord's loudness, across blocks" {
        var renderer: Renderer = .{};
        // A 400 Hz tone at 0.4 - louder than three Shepard notes' partials at that frequency - in three blocks of 128
        // frames, both channels: its second difference is 0.4 (2 pi 400 / 48000)^2 = 0.0011 at most, far under the
        // threshold. Its start is a click - from silence its slope leaps to 0.021 a sample at once, as a sound begun
        // with no attack does - so the first block's count is set aside; the next two, and the join between them, count
        // none.
        const block_frames: usize = 128;
        var smooth_block: [block_frames * channel_count]f32 = undefined;
        for (0..3) |block_index| {
            for (0..block_frames) |frame_index| {
                const frame_number: f32 = float(block_index * block_frames + frame_index);
                const sample: f32 = 0.4 * sinTurns(400 * frame_number / float(sample_rate));
                smooth_block[frame_index * channel_count] = sample;
                smooth_block[frame_index * channel_count + 1] = sample;
            }
            renderer.watchForClicks(&smooth_block);
            if (block_index == 0) {
                const start_report: Renderer.ClickReport = renderer.takeClicks();
                try expectEqual(@as(u32, 2), start_report.click_count);
            }
        }
        const smooth_report: Renderer.ClickReport = renderer.takeClicks();
        try expectEqual(@as(u32, 0), smooth_report.click_count);
        try expect(smooth_report.largest_jump < 0.002);
        // A step: silence, then 0.1 at once, held - one click a channel, at the step, and a jump of 0.1 there; the
        // sample after it, where the slope settles back to 0, jumps by 0.1 the other way, a second click a channel.
        var step_block: [block_frames * channel_count]f32 = @splat(0);
        for (64..128) |frame_index| {
            step_block[frame_index * channel_count] = 0.1;
            step_block[frame_index * channel_count + 1] = 0.1;
        }
        var silent_renderer: Renderer = .{};
        silent_renderer.watchForClicks(&step_block);
        const step_report: Renderer.ClickReport = silent_renderer.takeClicks();
        try expectEqual(@as(u32, 4), step_report.click_count);
        try expectApproxEqAbs(@as(f32, 0.1), step_report.largest_jump, 1e-6);
        // Taken, the count starts again.
        try expectEqual(@as(u32, 0), silent_renderer.takeClicks().click_count);
    }

    test "notes past the sixteen slots and one key struck again and again make no click; a mix past full scale clips" {
        var renderer_host: RendererHost = .{};
        try renderer_host.start(testing_allocator);
        defer renderer_host.stop();
        try expect(renderer_host.renderer_queues.commands.push(.{ .set_instrument = shepard_instrument }));
        const block_frame_count: usize = 128;
        // Twenty keys held, struck a block apart: the last four take the slots of the longest-sounding notes.
        for (0..20) |note_index| {
            const key: u8 = @intCast(48 + note_index);
            try expect(renderer_host.acceptNote(.{ .key = key, .is_down = true, .velocity = 0.1 }));
            _ = renderer_host.render(block_frame_count);
        }
        for (0..40) |_| {
            _ = renderer_host.render(block_frame_count);
        }
        const steal_report: Renderer.ClickReport = renderer_host.renderer.takeClicks();
        // One key struck again and again, faster than its releases die away: its earlier notes ring on as it is.
        for (0..40) |_| {
            try expect(renderer_host.acceptNote(.{ .key = 62, .is_down = true, .velocity = 0.1 }));
            _ = renderer_host.render(block_frame_count);
            _ = renderer_host.render(block_frame_count);
        }
        const restrike_report: Renderer.ClickReport = renderer_host.renderer.takeClicks();
        try expectEqual(@as(u32, 0), steal_report.click_count);
        try expectEqual(@as(u32, 0), steal_report.clipped_sample_count);
        try expectEqual(@as(u32, 0), restrike_report.click_count);
        try expectEqual(@as(u32, 0), restrike_report.clipped_sample_count);
        // Sixteen notes at velocity 0.5 sum past full scale at their peaks: the mix clips, and says so.
        var loud_host: RendererHost = .{};
        try loud_host.start(testing_allocator);
        defer loud_host.stop();
        try expect(loud_host.renderer_queues.commands.push(.{ .set_instrument = shepard_instrument }));
        for (0..16) |note_index| {
            const key: u8 = @intCast(48 + note_index);
            try expect(loud_host.acceptNote(.{ .key = key, .is_down = true, .velocity = 0.5 }));
        }
        for (0..400) |_| {
            _ = loud_host.render(block_frame_count);
        }
        const loud_report: Renderer.ClickReport = loud_host.renderer.takeClicks();
        try expect(loud_report.clipped_sample_count > 0);
        // Limited, then bent under full scale, the loud mix makes no click, though it passes full scale.
        try expectEqual(@as(u32, 0), loud_report.click_count);
    }

    /// The minutes of play the soak test renders (`a long two-hand session`): ten - past 2^24 frames, some six minutes,
    /// where a frame count kept in an `f32` would start to round.
    const soak_minutes: u64 = 10;

    test "a long two-hand session: no NaN, nothing past full scale, no denormal, no click" {
        // Notes and voices as the two-hand scale star makes them, at its pace - some twelve events a second - through
        // the real renderer and the real Shepard instrument, every sample checked. The left thumb's chord changes
        // every one to two seconds, its three notes at 0.15, a low Shepard note held under each chord as the pedals
        // hold theirs - stopped, and a new one started, at each change; the right hand strikes and lets go notes of
        // the scale at 0.5 between, some of them notes the chord already sounds, struck again.
        var engine_mixer: Mixer = .{};
        try allocateTestBlocks(&engine_mixer);
        defer freeTestBlocks(&engine_mixer);
        engine_mixer.setInstrument(shepard_instrument);
        var prng: Random.DefaultPrng = .init(0x5eed_50a4);
        const random: Random = prng.random();
        const scale_keys = [7]u8{ 60, 62, 64, 65, 67, 69, 71 };
        const block_frame_count: usize = 128;
        const total_frames: u64 = soak_minutes * 60 * sample_rate;
        const block_count: u64 = total_frames / block_frame_count;
        var block: [block_frame_count * channel_count]f32 = undefined;
        var thumb_keys: [3]u8 = .{ 60, 64, 67 };
        var right_hand_keys: [4]?u8 = @splat(null);
        var pedal: Voice = .none;
        var frames_until_chord_change: u64 = 0;
        var frames_until_right_hand_event: u64 = 0;
        var not_finite_count: u64 = 0;
        var past_full_scale_count: u64 = 0;
        var subnormal_count: u64 = 0;
        var first_bad_frame: ?u64 = null;
        for (0..block_count) |block_index| {
            // The left hand: a new chord - its root a scale degree, its notes the root, third and fifth above.
            if (frames_until_chord_change < block_frame_count) {
                for (thumb_keys) |key| {
                    _ = engine_mixer.sendNote(.{ .key = key, .is_down = false });
                }
                const root_index: usize = random.uintLessThan(usize, 7);
                for (&thumb_keys, 0..) |*key, chord_note_index| {
                    const scale_index: usize = root_index + 2 * chord_note_index;
                    const octave_up: u8 = if (scale_index >= 7) 12 else 0;
                    key.* = scale_keys[scale_index % 7] + octave_up;
                    _ = engine_mixer.sendNote(.{ .key = key.*, .is_down = true, .velocity = 0.15 });
                }
                // The pedal under it: the old one stopped - faded over 240 frames - a new one started.
                if (pedal != .none) {
                    engine_mixer.stopVoice(pedal);
                }
                var pedal_state: ShepardNoteState = undefined;
                shepard_instrument.start_note(&pedal_state, scale_keys[root_index] - 24, 0.4);
                const pedal_source: Source = .{ .generator = .{
                    .generate = shepard_instrument.generate,
                    .initial_state = asBytes(&pedal_state),
                } };
                pedal = engine_mixer.play(pedal_source, .{ .volume = 0.5 + 0.5 * random.float(f32) });
                frames_until_chord_change = sample_rate / 2 + random.uintLessThan(u64, 3 * sample_rate / 2);
            } else {
                frames_until_chord_change -= block_frame_count;
            }
            // The right hand: an event every tenth of a second or so - a strike, or a finger lifted.
            if (frames_until_right_hand_event < block_frame_count) {
                const finger: usize = random.uintLessThan(usize, right_hand_keys.len);
                if (right_hand_keys[finger]) |held_key| {
                    _ = engine_mixer.sendNote(.{ .key = held_key, .is_down = false });
                    right_hand_keys[finger] = null;
                } else {
                    // Half the time a note of the chord, struck again over the thumb's; else any note of the scale.
                    const is_chord_note: bool = random.boolean();
                    const key: u8 = if (is_chord_note)
                        thumb_keys[random.uintLessThan(usize, 3)]
                    else
                        scale_keys[random.uintLessThan(usize, 7)] + 12 * random.uintLessThan(u8, 2);
                    _ = engine_mixer.sendNote(.{ .key = key, .is_down = true, .velocity = 0.5 });
                    right_hand_keys[finger] = key;
                }
                frames_until_right_hand_event = random.uintLessThan(u64, sample_rate / 5);
            } else {
                frames_until_right_hand_event -= block_frame_count;
            }
            engine_mixer.mixInto(&block);
            for (block, 0..) |sample, sample_index| {
                const is_finite: bool = zm.isFinite(sample);
                const is_past_full_scale: bool = @abs(sample) > 1;
                const is_subnormal: bool = sample != 0 and @abs(sample) < zm.floatMin(f32);
                if (!is_finite) {
                    not_finite_count += 1;
                }
                if (is_past_full_scale) {
                    past_full_scale_count += 1;
                }
                if (is_subnormal) {
                    subnormal_count += 1;
                }
                const is_bad: bool = !is_finite or is_past_full_scale;
                if (is_bad and first_bad_frame == null) {
                    first_bad_frame = block_index * block_frame_count + sample_index / channel_count;
                }
            }
        }
        const click_report: Renderer.ClickReport = engine_mixer.renderer.takeClicks();
        // Logged only if a check below fails, with all the counts: the failing check says only its own.
        const soak_log: type = std.log.scoped(.sound_soak);
        errdefer soak_log.err("soak, {d} min: not finite {d}, past full scale {d}, subnormal {d}, clicks {d} " ++
            "(largest jump {d:.4}), clipped {d}, first bad frame {?d}\n", .{
            soak_minutes,
            not_finite_count,
            past_full_scale_count,
            subnormal_count,
            click_report.click_count,
            click_report.largest_jump,
            click_report.clipped_sample_count,
            first_bad_frame,
        });
        try expectEqual(@as(u64, 0), not_finite_count);
        try expectEqual(@as(u64, 0), past_full_scale_count);
        try expectEqual(@as(u32, 0), click_report.click_count);
    }

    test "a sine a third past full scale: cut flat it has corners, bent softly it has none" {
        // 1.3 at 400 Hz: the overshoot a loud chord's peaks make. Its largest second difference, cut at full scale
        // and bent under it (`softClip`): a corner is a jump in the slope; the soft knee keeps the slope continuous.
        var largest_jump_cut: f32 = 0;
        var largest_jump_bent: f32 = 0;
        var cut_history: [2]f32 = .{ 0, 0 };
        var bent_history: [2]f32 = .{ 0, 0 };
        for (0..4800) |frame_index| {
            const sample: f32 = 1.3 * sinTurns(400 * float(frame_index) / float(sample_rate));
            const cut: f32 = clamp(sample, -1, 1);
            const bent: f32 = Renderer.softClip(sample);
            if (frame_index >= 2) {
                largest_jump_cut = @max(largest_jump_cut, @abs(cut - 2 * cut_history[1] + cut_history[0]));
                largest_jump_bent = @max(largest_jump_bent, @abs(bent - 2 * bent_history[1] + bent_history[0]));
            }
            cut_history = .{ cut_history[1], cut };
            bent_history = .{ bent_history[1], bent };
            // Under full scale always, and untouched below the knee.
            try expect(@abs(bent) < 1);
            if (@abs(sample) <= Renderer.soft_clip_knee) {
                try expectEqual(sample, bent);
            }
        }
        // Measured: the cut wave's corners jump by 0.034, past the click watch's threshold - each counted as a click;
        // the bent wave curves by 0.010 at most, smoothly - the overshoot folded into the knee's 0.2 of headroom - and
        // stays under it.
        try expect(largest_jump_cut > Renderer.click_jump_threshold);
        try expect(largest_jump_bent < Renderer.click_jump_threshold);
    }

    test "a block is computed with subnormal numbers flushed to zero, and the thread's mode is put back after it" {
        const is_mode_settable: bool = switch (builtin.cpu.arch) {
            .x86_64, .aarch64 => true,
            else => false,
        };
        if (!is_mode_settable) {
            return error.SkipZigTest;
        }
        // 1e-38 times 0.01 is 1e-40, below the smallest normal f32 (1.2e-38): a subnormal number.
        var factors: [2]f32 = .{ 1.0e-38, 0.01 };
        const volatile_factors: *volatile [2]f32 = &factors;
        const product_before: f32 = volatile_factors[0] * volatile_factors[1];
        try expect(product_before != 0);
        var renderer_host: RendererHost = .{};
        try renderer_host.start(testing_allocator);
        defer renderer_host.stop();
        var product_play: VoiceToStart = .{
            .voice = .ofSlot(0, 0),
            .source = .{ .generator = .{ .generate = &generateTestProduct, .channels = channel_count } },
            .options = .{},
        };
        @memcpy(product_play.generator_state[0..@sizeOf([2]f32)], asBytes(&factors));
        try expect(renderer_host.renderer_queues.commands.push(.{ .play = product_play }));
        const rendered_block: []const f32 = renderer_host.render(128);
        // Inside the block, the generator's product - and everything made of it - is zero.
        try expectEqual(@as(f32, 0), rendered_block[0]);
        try expectEqual(@as(f32, 0), rendered_block[1]);
        // After it, the thread computes subnormal numbers again.
        const product_after: f32 = volatile_factors[0] * volatile_factors[1];
        try expectEqual(product_before, product_after);
    }

    test "setting an instrument warms it on no slot: its slots stay free and nothing is queued" {
        var renderer_host: RendererHost = .{};
        try renderer_host.start(testing_allocator);
        defer renderer_host.stop();
        try expect(renderer_host.renderer_queues.commands.push(.{ .set_instrument = sine_instrument }));
        const rendered_block: []const f32 = renderer_host.render(128);
        for (rendered_block) |rendered_sample| {
            try expectEqual(@as(f32, 0), rendered_sample);
        }
        for (first_instrument_slot..voice_capacity) |slot_index| {
            try expect(!renderer_host.renderer.voice_slots[slot_index].is_playing);
        }
        try expect(renderer_host.renderer_queues.notices.pop() == null);
    }

    test "a renderer in another memory, reached by bytes, renders and lets go as one reached by its queues" {
        // The reference: a renderer reached by its queues, on this thread.
        var local_mixer: Mixer = .{};
        try allocateTestBlocks(&local_mixer);
        defer freeTestBlocks(&local_mixer);
        // The other: a main side whose commands go as bytes to a host with a memory of its own.
        var main_side: Mixer = .{};
        try allocateTestBlocks(&main_side);
        defer freeTestBlocks(&main_side);
        main_side.is_renderer_on_another_thread = true;
        var renderer_host: RendererHost = .{};
        try renderer_host.start(testing_allocator);
        defer renderer_host.stop();
        const HostSink = struct {
            fn sendCommandBytes(context: *anyopaque, command_bytes: []const u8) void {
                const host: *RendererHost = @ptrCast(@alignCast(context));
                host.acceptCommandBytes(command_bytes);
            }

            fn sendSamples(
                context: *anyopaque,
                samples_id: SamplesId,
                samples: []const f32,
            ) void {
                const host: *RendererHost = @ptrCast(@alignCast(context));
                host.acceptSamples(samples_id, samples) catch {
                    zm.assertUnreachable(@src(), "the host had no room for samples {d}", .{samples_id});
                };
            }

            fn sendNote(context: *anyopaque, note_event: NoteEvent) void {
                const host: *RendererHost = @ptrCast(@alignCast(context));
                const is_queued: bool = host.acceptNote(note_event);
                assert(is_queued, @src());
            }
        };
        const command_sink: CommandSink = .{
            .context = &renderer_host,
            .send_command_bytes = &HostSink.sendCommandBytes,
            .send_samples = &HostSink.sendSamples,
            .send_note = &HostSink.sendNote,
        };
        // The same sounds on both: a ramp of samples - the other side's own buffer, to be released - and a tone.
        var local_ramp: [960]f32 = undefined;
        for (&local_ramp, 0..) |*ramp_sample, ramp_index| {
            const ramp_index_float: f32 = @floatFromInt(ramp_index);
            ramp_sample.* = ramp_index_float / 2048;
        }
        const owned_ramp: []f32 = try testing_allocator.dupe(f32, &local_ramp);
        var tone_frequency: f32 = 440;
        const tone_source: Source = .{ .generator = .{
            .generate = &generateTestSine,
            .initial_state = asBytes(&tone_frequency),
        } };
        _ = local_mixer.play(.{ .samples = .{ .samples = &local_ramp, .channels = 1, .sample_rate = 24_000 } }, .{});
        _ = local_mixer.play(tone_source, .{ .pan = 0.5, .pitch = 1.5 });
        _ = main_side.play(.{ .samples = .{ .samples = owned_ramp, .channels = 1, .sample_rate = 24_000 } }, .{});
        _ = main_side.play(tone_source, .{ .pan = 0.5, .pitch = 1.5 });
        forwardCommands(&main_side, command_sink);
        // Three blocks of 128 frames, as a worklet asks: the same samples, bit for bit.
        var local_block: [128 * 2]f32 = undefined;
        var block_number: usize = 0;
        while (block_number < 3) : (block_number += 1) {
            local_mixer.mixInto(&local_block);
            const host_block: []const f32 = renderer_host.render(128);
            try expectEqualSlices(f32, &local_block, host_block);
        }
        // Released on the main side: the host's copy goes when its renderer lets go, the main side's own buffer when
        // the notice comes back - the testing allocator would report either leaked, or freed twice.
        main_side.releaseSamples(testing_allocator, owned_ramp);
        forwardCommands(&main_side, command_sink);
        _ = renderer_host.render(128);
        var renderer_notices: [16]RendererNotice = undefined;
        const notice_count: usize = renderer_host.takeNotices(&renderer_notices);
        try expect(notice_count >= 1);
        try expectEqual(@as(usize, 0), renderer_host.uploaded_samples[0].len);
        acceptNotices(&main_side, renderer_notices[0..notice_count]);
        main_side.readRendererNotices();
        try expect(!main_side.samples_registry[0].is_registered);
    }

    test "a key's note starts at the next block, sounds at its key's frequency, and ends quietly after its release" {
        var engine_mixer: Mixer = .{};
        try allocateTestBlocks(&engine_mixer);
        defer freeTestBlocks(&engine_mixer);
        engine_mixer.setInstrument(sine_instrument);
        try expect(engine_mixer.sendNote(.{ .key = 69, .is_down = true }));
        // One second, in the blocks of 128 frames a worklet asks for: 375 of them.
        const quantum_sample_count: usize = @as(usize, 128) * channel_count;
        const one_second: []f32 = try testing_allocator.alloc(f32, @as(usize, sample_rate) * channel_count);
        defer testing_allocator.free(one_second);
        var first_sample: usize = 0;
        while (first_sample < one_second.len) : (first_sample += quantum_sample_count) {
            engine_mixer.mixInto(one_second[first_sample..][0..quantum_sample_count]);
        }
        // The note sounds in the first block: its frame 0 is the sine's zero, its frame 1 is not.
        try expectEqual(@as(f32, 0), one_second[0]);
        try expect(one_second[1 * channel_count] != 0);
        // Key 69 is the A at 440 Hz: 440 rising crossings in the second, less the first, at frame 0, which no sample
        // below zero comes before. The peak is the centre's gain, 0.707, at velocity 1.
        try expectEqual(@as(usize, 439), countRisingZeroCrossings(one_second));
        var peak: f32 = 0;
        for (one_second) |mixed_sample| {
            peak = @max(peak, @abs(mixed_sample));
        }
        try expectApproxEqAbs(@as(f32, 0.7071), peak, 0.001);
        // Released, it halves every 50 ms and is silent below -80 dB, some 665 ms later: after a second, its slot
        // is free, and the main side was never told of a slot it never named.
        try expect(engine_mixer.sendNote(.{ .key = 69, .is_down = false }));
        first_sample = 0;
        while (first_sample < one_second.len) : (first_sample += quantum_sample_count) {
            engine_mixer.mixInto(one_second[first_sample..][0..quantum_sample_count]);
        }
        for (first_instrument_slot..voice_capacity) |slot_index| {
            try expect(!engine_mixer.renderer.voice_slots[slot_index].is_playing);
        }
        try expectEqual(@as(u32, 0), engine_mixer.playingVoiceCount());
        const last_quantum: []const f32 = one_second[one_second.len - quantum_sample_count ..];
        for (last_quantum) |mixed_sample| {
            try expectEqual(@as(f32, 0), mixed_sample);
        }
    }

    test "a sine note held for twenty seconds is still the exact sine, to a millionth" {
        // The A at 440 Hz, struck at full level and held: 20 seconds generated in blocks of 128 frames, then the 21st
        // second compared, frame by frame, with the sine computed in 64-bit floats from the frame's number.
        var note_state: [generator_state_capacity]u8 align(16) = undefined;
        startSineNote(&note_state, 69, 1);
        var block: [@as(usize, 128) * channel_count]f32 = undefined;
        const block_frame_count: u64 = 128;
        const held_frame_count: u64 = 20 * @as(u64, sample_rate);
        var first_frame: u64 = 0;
        while (first_frame < held_frame_count) : (first_frame += block_frame_count) {
            generateSineNote(&note_state, &block, first_frame);
        }
        const compared_frame_count: u64 = sample_rate;
        var worst_error: f64 = 0;
        while (first_frame < held_frame_count + compared_frame_count) : (first_frame += block_frame_count) {
            generateSineNote(&note_state, &block, first_frame);
            for (0..block_frame_count) |frame_offset| {
                const frame_number: f64 = float64(first_frame + frame_offset);
                const exact_phase_turns: f64 = 440 * frame_number / float64(sample_rate);
                const exact_sample: f64 = sinTurns(exact_phase_turns - @floor(exact_phase_turns));
                const generated_sample: f64 = block[frame_offset * channel_count];
                worst_error = @max(worst_error, @abs(generated_sample - exact_sample));
            }
        }
        try expectApproxEqAbs(@as(f64, 0), worst_error, 1.0e-6);
    }

    test "notes from the main thread and from an input thread both reach the instrument, each in its own queue" {
        var engine_mixer: Mixer = .{};
        try allocateTestBlocks(&engine_mixer);
        defer freeTestBlocks(&engine_mixer);
        engine_mixer.setInstrument(sine_instrument);
        // An input thread presses and releases keys 60 to 67 while the main thread presses key 72 and holds it: two
        // producers at once, one queue each.
        const InputThread = struct {
            fn pressAndRelease(mixer_of_test: *Mixer) void {
                for (60..68) |key| {
                    const note_key: u8 = @intCast(key);
                    _ = mixer_of_test.sendNoteFromInputThread(.{ .key = note_key, .is_down = true });
                    _ = mixer_of_test.sendNoteFromInputThread(.{ .key = note_key, .is_down = false });
                }
                _ = mixer_of_test.sendNoteFromInputThread(.{ .key = 64, .is_down = true });
            }
        };
        const input_thread: std.Thread = try .spawn(.{}, InputThread.pressAndRelease, .{&engine_mixer});
        try expect(engine_mixer.sendNote(.{ .key = 72, .is_down = true }));
        input_thread.join();
        var block: [@as(usize, 128) * channel_count]f32 = undefined;
        engine_mixer.mixInto(&block);
        // Sounding now: key 72, held; key 64, pressed last; and the eight released notes in their release.
        var held_keys: [2]u8 = undefined;
        var held_count: usize = 0;
        var sounding_count: usize = 0;
        for (first_instrument_slot..voice_capacity) |slot_index| {
            const voice_slot: *const VoiceSlot = &engine_mixer.renderer.voice_slots[slot_index];
            if (!voice_slot.is_playing) {
                continue;
            }
            sounding_count += 1;
            if (voice_slot.is_note_held) {
                held_keys[held_count] = voice_slot.note_key;
                held_count += 1;
            }
        }
        try expectEqual(@as(usize, 10), sounding_count);
        try expectEqual(@as(usize, 2), held_count);
        try expectEqual(@as(u8, 72), held_keys[0]);
        try expectEqual(@as(u8, 64), held_keys[1]);
    }

    test "a note giving up its slot to a new one fades out, with no jump" {
        var engine_mixer: Mixer = .{};
        try allocateTestBlocks(&engine_mixer);
        defer freeTestBlocks(&engine_mixer);
        engine_mixer.setInstrument(sine_instrument);
        var block: [@as(usize, 128) * channel_count]f32 = undefined;
        // The note to be stolen: the oldest, loud, and low - 32.7 Hz, whose own steps between frames are small.
        try expect(engine_mixer.sendNote(.{ .key = 24, .is_down = true, .velocity = 1 }));
        engine_mixer.mixInto(&block);
        // Fifteen quiet notes fill the other slots: key 12 below it and keys 61 to 74 above, so that the lowest and
        // the highest held notes - which stealing protects (`noteSlotToSteal`) - are quiet ones, and the loud note is
        // the oldest of the rest.
        try expect(engine_mixer.sendNote(.{ .key = 12, .is_down = true, .velocity = 0.001 }));
        for (61..75) |key| {
            try expect(engine_mixer.sendNote(.{ .key = @intCast(key), .is_down = true, .velocity = 0.001 }));
        }
        // Blocks until the loud note is far from zero at a block's end, where a cut would jump the most.
        var last_left_sample: f32 = 0;
        var block_count: usize = 0;
        while (@abs(last_left_sample) < 0.4) : (block_count += 1) {
            try expect(block_count < 100);
            engine_mixer.mixInto(&block);
            last_left_sample = block[block.len - channel_count];
        }
        // A seventeenth key: the loud note gives up its slot.
        try expect(engine_mixer.sendNote(.{ .key = 80, .is_down = true, .velocity = 0.001 }));
        const quantum_sample_count: usize = @as(usize, 128) * channel_count;
        var after_steal: [2 * quantum_sample_count]f32 = undefined;
        engine_mixer.mixInto(after_steal[0..quantum_sample_count]);
        engine_mixer.mixInto(after_steal[quantum_sample_count..]);
        var largest_step: f32 = @abs(after_steal[0] - last_left_sample);
        for (1..fade_out_frames + 8) |frame_index| {
            const step: f32 = after_steal[frame_index * channel_count] - after_steal[(frame_index - 1) * channel_count];
            largest_step = @max(largest_step, @abs(step));
        }
        try expect(largest_step < 0.01);
        // And the fade ends: past it, only the quiet notes sound.
        const after_fade_sample: f32 = after_steal[(fade_out_frames + 8) * channel_count];
        try expect(@abs(after_fade_sample) < 0.02);
    }

    test "a start is measured: asked for, applied at the start of its block, and heard after what was queued ahead" {
        // A stand-in output that pulls, on a clock that reads 100 ms: a play and a note are stamped with that time.
        const StandInOutput = struct {
            fn startPulling(
                wanted: contract.AudioFormat,
                render_callback: contract.AudioRenderCallback,
            ) contract.AudioFormat {
                _ = render_callback;
                return wanted;
            }

            fn clockMilliseconds() f64 {
                return 100;
            }

            fn stop() void {}
        };
        const stand_in_output: Output = .{
            .start_pulling = &StandInOutput.startPulling,
            .clock_ms = &StandInOutput.clockMilliseconds,
            .latency_ms = &StandInOutput.clockMilliseconds,
            .name = &standInName,
            .stop = &StandInOutput.stop,
            .calls_renderer_from_another_thread = true,
        };
        var engine_mixer: Mixer = .{};
        try engine_mixer.start(testing_allocator, stand_in_output);
        defer engine_mixer.stop();
        engine_mixer.setInstrument(sine_instrument);
        var tone_frequency: f32 = 440;
        const tone_source: Source = .{ .generator = .{
            .generate = &generateTestSine,
            .initial_state = asBytes(&tone_frequency),
        } };
        // The play, rendered by a block asked for at 105 ms and heard at 115 - 10 ms of sound queued ahead of it - its
        // press at 92 ms.
        _ = engine_mixer.play(tone_source, .{ .pressed_at_ms = 92 });
        var block: [@as(usize, 128) * channel_count]f32 = undefined;
        Mixer.renderForPullingOutput(&engine_mixer, &block, .{ .asked_at_ms = 105, .first_frame_out_ms = 115 });
        // The note, by a block asked for at 205 ms and heard at 207.5 - its key pressed at 91.5 ms.
        try expect(engine_mixer.sendNote(.{ .key = 69, .is_down = true, .pressed_at_ms = 91.5 }));
        Mixer.renderForPullingOutput(&engine_mixer, &block, .{ .asked_at_ms = 205, .first_frame_out_ms = 207.5 });
        // The frame reads them, newest first.
        engine_mixer.mixFrame();
        var recent: [recent_start_capacity]LatencySample = undefined;
        const measured: []LatencySample = engine_mixer.recentStarts(&recent);
        try expectEqual(@as(usize, 2), measured.len);
        try expectEqual(.note, measured[0].kind);
        try expectEqual(@as(f64, 100), measured[0].requested_at_ms);
        try expectEqual(@as(f64, 205), measured[0].applied_at_ms);
        try expectEqual(@as(f64, 207.5), measured[0].first_frame_out_ms);
        try expectEqual(@as(f64, 91.5), measured[0].pressed_at_ms);
        try expectEqual(.play, measured[1].kind);
        try expectEqual(@as(f64, 100), measured[1].requested_at_ms);
        try expectEqual(@as(f64, 105), measured[1].applied_at_ms);
        try expectEqual(@as(f64, 115), measured[1].first_frame_out_ms);
        try expectEqual(@as(f64, 92), measured[1].pressed_at_ms);
    }

    /// The first frame a note sounds at in its block: a block asked for at 100 ms, empty, then the note requested at
    /// `requested_at_ms` and a block of 128 frames asked for 2.7 ms later, its instrument the sine, placing its notes
    /// by their time or not. Null if the note never sounds in it.
    fn firstSoundingFrameOfNote(requested_at_ms: f64, places_notes_by_time: bool) !?usize {
        const StandInOutput = struct {
            fn startPulling(
                wanted: contract.AudioFormat,
                render_callback: contract.AudioRenderCallback,
            ) contract.AudioFormat {
                _ = render_callback;
                return wanted;
            }

            fn clockMilliseconds() f64 {
                return 100;
            }

            fn stop() void {}
        };
        const stand_in_output: Output = .{
            .start_pulling = &StandInOutput.startPulling,
            .clock_ms = &StandInOutput.clockMilliseconds,
            .latency_ms = &StandInOutput.clockMilliseconds,
            .name = &standInName,
            .stop = &StandInOutput.stop,
            .calls_renderer_from_another_thread = true,
        };
        var engine_mixer: Mixer = .{};
        try engine_mixer.start(testing_allocator, stand_in_output);
        defer engine_mixer.stop();
        var instrument: Instrument = sine_instrument;
        instrument.places_notes_by_time = places_notes_by_time;
        engine_mixer.setInstrument(instrument);
        var block: [@as(usize, 128) * channel_count]f32 = undefined;
        Mixer.renderForPullingOutput(&engine_mixer, &block, .{ .asked_at_ms = 100, .first_frame_out_ms = 110 });
        try expect(engine_mixer.sendNote(.{ .key = 69, .is_down = true, .requested_at_ms = requested_at_ms }));
        Mixer.renderForPullingOutput(&engine_mixer, &block, .{ .asked_at_ms = 102.7, .first_frame_out_ms = 112.7 });
        for (0..128) |frame_index| {
            if (block[frame_index * channel_count] != 0) {
                return frame_index;
            }
        }
        return null;
    }

    test "a note placed by its time starts as far into its block as it was asked for after the block before" {
        // The same note, not placed: at the block's first frame - its first sample sin 0, so it sounds one later.
        const unplaced_frame: usize = (try firstSoundingFrameOfNote(100.5, false)).?;
        // Placed: 0.5 ms after the block before, 24 frames in; 1.5 ms after, 72 - two notes 1 ms apart, 48 apart.
        const half_frame: usize = (try firstSoundingFrameOfNote(100.5, true)).?;
        const one_and_half_frame: usize = (try firstSoundingFrameOfNote(101.5, true)).?;
        try expectEqual(@as(usize, 24), half_frame - unplaced_frame);
        try expectEqual(@as(usize, 72), one_and_half_frame - unplaced_frame);
        try expectEqual(@as(usize, 48), one_and_half_frame - half_frame);
        // Requested before the block before was asked for - late, however placed - it starts at the first frame.
        try expectEqual(unplaced_frame, (try firstSoundingFrameOfNote(99, true)).?);
    }

    test "the latency readout's line: the frame's wait from the press when known, a dash when not" {
        var line_buffer: [96]u8 = undefined;
        // Pressed at 91.5 ms, requested at 100, applied at 205, its first frame out at 207.5, 3 ms past the output.
        const pressed: LatencySample = .{
            .kind = .note,
            .requested_at_ms = 100,
            .applied_at_ms = 205,
            .first_frame_out_ms = 207.5,
            .pressed_at_ms = 91.5,
        };
        const pressed_line: []const u8 = Mixer.formatLatencyLine(pressed, 3, &line_buffer);
        try expectEqualStrings("note     8.5   105.0     2.5     3.0   119.0", pressed_line);
        var unpressed: LatencySample = pressed;
        unpressed.pressed_at_ms = 0;
        const unpressed_line: []const u8 = Mixer.formatLatencyLine(unpressed, 3, &line_buffer);
        try expectEqualStrings("note       -   105.0     2.5     3.0   110.5", unpressed_line);
        // The header's columns stand over the line's.
        try expectEqual(Mixer.latency_readout_header.len - "  (ms)".len, pressed_line.len);
    }

    test "forwarding a stream: its frames reach the other memory as written, its room returns as they are read" {
        // A stand-in for the browser's worklet, as in the test below, which also carries a stream's frames.
        const StreamStandIn = struct {
            // lint:off module-var: a stand-in platform's state - a platform's functions take no context
            var host: RendererHost = .{};
            // lint:off module-var: the stand-in's count of what reached it, as a platform's state
            var stream_frame_message_count: usize = 0;

            fn startForwarding(wanted: contract.AudioFormat) ?contract.AudioFormat {
                host.start(testing_allocator) catch return null;
                return wanted;
            }

            fn sendCommandBytes(command_bytes: []const u8) void {
                const command_byte_count: usize = @sizeOf(RendererCommand);
                assert(command_bytes.len % command_byte_count == 0, @src());
                var command_start: usize = 0;
                while (command_start < command_bytes.len) : (command_start += command_byte_count) {
                    host.acceptCommandBytes(command_bytes[command_start..][0..command_byte_count]);
                }
            }

            fn sendSamples(samples_id: SamplesId, samples: []const f32) void {
                host.acceptSamples(samples_id, samples) catch {
                    zm.assertUnreachable(@src(), "the stand-in had no room for samples {d}", .{samples_id});
                };
            }

            fn sendNote(
                key: u8,
                is_down: bool,
                velocity: f32,
                requested_at_ms: f64,
                pressed_at_ms: f64,
            ) void {
                _ = host.acceptNote(.{
                    .key = key,
                    .is_down = is_down,
                    .velocity = velocity,
                    .requested_at_ms = requested_at_ms,
                    .pressed_at_ms = pressed_at_ms,
                });
            }

            fn sendStreamFrames(
                stream_id: u8,
                channels: u8,
                frames_per_second: u32,
                frames: []const f32,
            ) void {
                stream_frame_message_count += 1;
                const stream: ForwardedStream = .{
                    .id = stream_id,
                    .channels = channels,
                    .sample_rate = frames_per_second,
                };
                host.acceptStreamFrames(stream, frames);
            }

            fn takeNoticeBytes(notice_bytes: []u8, notice_byte_count: usize) usize {
                assert(notice_byte_count == @sizeOf(RendererNotice), @src());
                const notice_room: usize = notice_bytes.len / @sizeOf(RendererNotice);
                var notices: [64]RendererNotice = undefined;
                const taken_count: usize = host.takeNotices(notices[0..@min(notice_room, notices.len)]);
                const taken_bytes: []const u8 = sliceAsBytes(notices[0..taken_count]);
                @memcpy(notice_bytes[0..taken_bytes.len], taken_bytes);
                return taken_bytes.len;
            }

            /// Never called: the forwarding starts, and a mixer that forwards does not pull.
            fn startPulling(
                wanted: contract.AudioFormat,
                render_callback: contract.AudioRenderCallback,
            ) contract.AudioFormat {
                _ = render_callback;
                zm.assertUnreachable(@src(), "the stand-in's forwarding started, so its output is not pulled", .{});
                return wanted;
            }

            fn zeroMilliseconds() f64 {
                return 0;
            }

            fn stop() void {
                host.stop();
            }

            /// The loudest sample of `block_count` blocks of 128 frames rendered there.
            fn loudestOfBlocks(block_count: usize) f32 {
                var loudest: f32 = 0;
                for (0..block_count) |_| {
                    for (host.render(128)) |rendered_sample| {
                        loudest = @max(loudest, @abs(rendered_sample));
                    }
                }
                return loudest;
            }
        };
        const forwarding_output: Output = .{
            .start_pulling = &StreamStandIn.startPulling,
            .clock_ms = &StreamStandIn.zeroMilliseconds,
            .latency_ms = &StreamStandIn.zeroMilliseconds,
            .name = &standInName,
            .stop = &StreamStandIn.stop,
            .forwarding = .{
                .start = &StreamStandIn.startForwarding,
                .send_command_bytes = &StreamStandIn.sendCommandBytes,
                .send_samples = &StreamStandIn.sendSamples,
                .send_note = &StreamStandIn.sendNote,
                .take_notice_bytes = &StreamStandIn.takeNoticeBytes,
                .send_stream_frames = &StreamStandIn.sendStreamFrames,
            },
        };
        var engine_mixer: Mixer = .{};
        try engine_mixer.start(testing_allocator, forwarding_output);
        defer engine_mixer.stop();
        // The game's ring: 2 048 frames of mono at 48 000 Hz, 1 024 of them a sine of 750 Hz at 0.5 - 64 frames to a
        // period, so that any run of whole periods continues it.
        var ring_samples: [2048]f32 = undefined;
        var ring: StreamRing = .initOver(&ring_samples, 1, 48_000);
        var sine_frames: [1536]f32 = undefined;
        for (&sine_frames, 0..) |*frame, frame_index| {
            const phase: f32 = float(frame_index % 64) / 64;
            frame.* = 0.5 * sinTurns(phase);
        }
        try expectEqual(@as(usize, 1024), ring.write(sine_frames[0..1024]));
        const stream_voice: Voice = engine_mixer.play(.{ .stream = .{ .ring = &ring } }, .{});
        try expect(stream_voice != .none);
        // A frame: the voice's start and its 1 024 frames cross. The game's ring still holds them all, unread.
        engine_mixer.mixFrame();
        try expectEqual(@as(usize, 1), StreamStandIn.stream_frame_message_count);
        try expectEqual(@as(usize, 1024), ring.freeFrames());
        // Played there - the sine, panned to the middle - and reported with the next frame: the 514 frames read there
        // (512 played, two taken by the interpolation's window as it began) free their room here.
        const first_loudest: f32 = StreamStandIn.loudestOfBlocks(4);
        try expect(first_loudest > 0.3 and first_loudest < 0.4);
        engine_mixer.mixFrame();
        try expectEqual(@as(usize, 2048 - (1024 - 514)), ring.freeFrames());
        // 1 536 frames more - whole periods, so the sine runs on - which pass the ring's end: sent with the next frame
        // in two pieces, and played on with no frame missing.
        try expectEqual(@as(usize, 1536), ring.write(&sine_frames));
        engine_mixer.mixFrame();
        try expectEqual(@as(usize, 3), StreamStandIn.stream_frame_message_count);
        const second_loudest: f32 = StreamStandIn.loudestOfBlocks(8);
        try expect(second_loudest > 0.3 and second_loudest < 0.4);
        engine_mixer.mixFrame();
        try expectEqual(@as(usize, 0), ring.takeDryFrames());
        try expectEqual(@as(usize, 2048 - (2560 - (514 + 1024))), ring.freeFrames());
        // Stopped: the voice fades and ends there, its end comes back, the number is given up, and the other side is
        // told to free its ring - which it has done by the frame after.
        engine_mixer.stopVoice(stream_voice);
        engine_mixer.mixFrame();
        _ = StreamStandIn.loudestOfBlocks(8);
        engine_mixer.mixFrame();
        try expect(engine_mixer.forwarded_streams[0].ring == null);
        engine_mixer.mixFrame();
        try expect(StreamStandIn.host.stream_rings[0] == null);
        // Played again, the same ring - its counts long past its first frame: it goes on from where it was read, as it
        // does natively. Only its unread frames cross - none sent twice, no run past the ring's end - under the
        // number's next generation.
        const replay_first_frame: usize = ring.reading_side.read_frames.load(.monotonic);
        const unread_frames: usize = 2560 - replay_first_frame;
        const replay_voice: Voice = engine_mixer.play(.{ .stream = .{ .ring = &ring } }, .{});
        try expect(replay_voice != .none);
        engine_mixer.mixFrame();
        const replay_host_ring: *RendererHost.HostStreamRing = StreamStandIn.host.stream_rings[0].?;
        try expectEqual(unread_frames, replay_host_ring.ring.writing_side.written_frames.load(.monotonic));
        try expectEqual(engine_mixer.forwarded_streams[0].generation, replay_host_ring.generation);
        // A report from the stream before - its generation - still on its way back: it moves nothing.
        const late_read: StreamRead = .{
            .id = 0,
            .generation = engine_mixer.forwarded_streams[0].generation -% 1,
            .dry_frames = 0,
            .read_frames = 5000,
        };
        engine_mixer.acceptStreamRead(late_read);
        try expectEqual(replay_first_frame, ring.reading_side.read_frames.load(.monotonic));
        // The replayed stream's own reports - every 512 frames - move the ring on from where it began again.
        _ = StreamStandIn.loudestOfBlocks(4);
        engine_mixer.mixFrame();
        try expect(ring.reading_side.read_frames.load(.monotonic) > replay_first_frame);
        // The same ring a second time, while it plays: refused - a ring has one reader.
        try expectEqual(Voice.none, engine_mixer.play(.{ .stream = .{ .ring = &ring } }, .{}));
    }

    test "forwarding: commands reach the renderer in the other memory, its notices return, the local one rests" {
        // A stand-in for the browser's worklet: a renderer host in this process, reached only through the output's
        // functions, which - as a platform's - take no context.
        const StandInWorklet = struct {
            // lint:off module-var: a stand-in platform's state - a platform's functions take no context
            var host: RendererHost = .{};

            fn startForwarding(wanted: contract.AudioFormat) ?contract.AudioFormat {
                host.start(testing_allocator) catch return null;
                return wanted;
            }

            // lint:off module-var: the stand-in's count of what reached it, as a platform's state
            var command_message_count: usize = 0;
            // lint:off module-var: the stand-in's count of what reached it, as a platform's state
            var last_message_command_count: usize = 0;

            /// A message of commands, split into its commands as the worklet's program splits it.
            fn sendCommandBytes(command_bytes: []const u8) void {
                const command_byte_count: usize = @sizeOf(RendererCommand);
                assert(command_bytes.len % command_byte_count == 0, @src());
                command_message_count += 1;
                last_message_command_count = command_bytes.len / command_byte_count;
                var command_start: usize = 0;
                while (command_start < command_bytes.len) : (command_start += command_byte_count) {
                    host.acceptCommandBytes(command_bytes[command_start..][0..command_byte_count]);
                }
            }

            fn sendSamples(samples_id: SamplesId, samples: []const f32) void {
                host.acceptSamples(samples_id, samples) catch {
                    zm.assertUnreachable(@src(), "the stand-in had no room for samples {d}", .{samples_id});
                };
            }

            fn sendNote(
                key: u8,
                is_down: bool,
                velocity: f32,
                requested_at_ms: f64,
                pressed_at_ms: f64,
            ) void {
                _ = host.acceptNote(.{
                    .key = key,
                    .is_down = is_down,
                    .velocity = velocity,
                    .requested_at_ms = requested_at_ms,
                    .pressed_at_ms = pressed_at_ms,
                });
            }

            fn takeNoticeBytes(notice_bytes: []u8, notice_byte_count: usize) usize {
                assert(notice_byte_count == @sizeOf(RendererNotice), @src());
                const notice_room: usize = notice_bytes.len / @sizeOf(RendererNotice);
                var notices: [64]RendererNotice = undefined;
                const taken_count: usize = host.takeNotices(notices[0..@min(notice_room, notices.len)]);
                const taken_bytes: []const u8 = sliceAsBytes(notices[0..taken_count]);
                @memcpy(notice_bytes[0..taken_bytes.len], taken_bytes);
                return taken_bytes.len;
            }

            /// Never called: the forwarding starts, and a mixer that forwards does not pull.
            fn startPulling(
                wanted: contract.AudioFormat,
                render_callback: contract.AudioRenderCallback,
            ) contract.AudioFormat {
                _ = render_callback;
                zm.assertUnreachable(@src(), "the stand-in's forwarding started, so its output is not pulled", .{});
                return wanted;
            }

            fn zeroMilliseconds() f64 {
                return 0;
            }

            fn stop() void {
                host.stop();
            }
        };
        const forwarding_output: Output = .{
            .start_pulling = &StandInWorklet.startPulling,
            .clock_ms = &StandInWorklet.zeroMilliseconds,
            .latency_ms = &StandInWorklet.zeroMilliseconds,
            .name = &standInName,
            .stop = &StandInWorklet.stop,
            .forwarding = .{
                .start = &StandInWorklet.startForwarding,
                .send_command_bytes = &StandInWorklet.sendCommandBytes,
                .send_samples = &StandInWorklet.sendSamples,
                .send_note = &StandInWorklet.sendNote,
                .take_notice_bytes = &StandInWorklet.takeNoticeBytes,
            },
        };
        var engine_mixer: Mixer = .{};
        try engine_mixer.start(testing_allocator, forwarding_output);
        defer engine_mixer.stop();
        try expect(engine_mixer.forwarding != null);
        // A buffer of the main side's, played, then released while it plays.
        const owned_ramp: []f32 = try testing_allocator.alloc(f32, 960);
        for (owned_ramp, 0..) |*ramp_sample, ramp_index| {
            ramp_sample.* = float(ramp_index) / 2048;
        }
        const ramp_voice: Voice = engine_mixer.play(.{ .samples = .{
            .samples = owned_ramp,
            .channels = 1,
            .sample_rate = 24_000,
        } }, .{});
        try expect(ramp_voice != .none);
        // A second command in the same frame: the frame's commands travel as one message.
        engine_mixer.setVolume(ramp_voice, 0.5);
        engine_mixer.mixFrame();
        try expectEqual(@as(usize, 1), StandInWorklet.command_message_count);
        try expectEqual(@as(usize, 2), StandInWorklet.last_message_command_count);
        // The renderer over there plays it; the one here never heard of it.
        const rendered: []const f32 = StandInWorklet.host.render(128);
        var loudest: f32 = 0;
        for (rendered) |rendered_sample| {
            loudest = @max(loudest, @abs(rendered_sample));
        }
        try expect(loudest > 0);
        for (engine_mixer.renderer.voice_slots) |voice_slot| {
            try expect(!voice_slot.is_playing);
        }
        // Released: the main side's buffer is freed only once the other side's notice is read.
        engine_mixer.releaseSamples(testing_allocator, owned_ramp);
        engine_mixer.mixFrame();
        try expect(engine_mixer.samples_registry[0].is_registered);
        _ = StandInWorklet.host.render(128);
        engine_mixer.mixFrame();
        try expect(!engine_mixer.samples_registry[0].is_registered);
        // The voice fades over its copy of the last 5 ms - 240 frames - and its end is noticed after.
        try expect(engine_mixer.isPlaying(ramp_voice));
        _ = StandInWorklet.host.render(128);
        _ = StandInWorklet.host.render(128);
        engine_mixer.mixFrame();
        try expect(!engine_mixer.isPlaying(ramp_voice));
    }

    /// The keys of the instrument's notes sounding now, and of those held, for the stealing tests below.
    const SoundingNotes = struct {
        sounding: [instrument_voice_count]u8 = undefined,
        sounding_count: usize = 0,
        held: [instrument_voice_count]u8 = undefined,
        held_count: usize = 0,

        fn of(renderer: *const Renderer) SoundingNotes {
            var notes: SoundingNotes = .{};
            for (first_instrument_slot..voice_capacity) |slot_index| {
                const voice_slot: *const VoiceSlot = &renderer.voice_slots[slot_index];
                if (!voice_slot.is_playing) {
                    continue;
                }
                notes.sounding[notes.sounding_count] = voice_slot.note_key;
                notes.sounding_count += 1;
                if (voice_slot.is_note_held) {
                    notes.held[notes.held_count] = voice_slot.note_key;
                    notes.held_count += 1;
                }
            }
            return notes;
        }

        fn isSounding(notes: *const SoundingNotes, key: u8) bool {
            return indexOfScalar(u8, notes.sounding[0..notes.sounding_count], key) != null;
        }

        fn isHeld(notes: *const SoundingNotes, key: u8) bool {
            return indexOfScalar(u8, notes.held[0..notes.held_count], key) != null;
        }
    };

    test "a key struck again releases its held note, which rings on beside the new one" {
        var engine_mixer: Mixer = .{};
        try allocateTestBlocks(&engine_mixer);
        defer freeTestBlocks(&engine_mixer);
        engine_mixer.setInstrument(sine_instrument);
        var block: [@as(usize, 128) * channel_count]f32 = undefined;
        try expect(engine_mixer.sendNote(.{ .key = 60, .is_down = true }));
        engine_mixer.mixInto(&block);
        try expect(engine_mixer.sendNote(.{ .key = 60, .is_down = true }));
        engine_mixer.mixInto(&block);
        const notes: SoundingNotes = .of(&engine_mixer.renderer);
        try expectEqual(@as(usize, 2), notes.sounding_count);
        try expectEqual(@as(usize, 1), notes.held_count);
    }

    test "with every slot sounding, a released note gives up its slot before a held one" {
        var engine_mixer: Mixer = .{};
        try allocateTestBlocks(&engine_mixer);
        defer freeTestBlocks(&engine_mixer);
        engine_mixer.setInstrument(sine_instrument);
        var block: [@as(usize, 128) * channel_count]f32 = undefined;
        // Fifteen held notes, the oldest first, then a sixteenth struck and released: the youngest, but no finger
        // holds it.
        for (40..55) |key| {
            try expect(engine_mixer.sendNote(.{ .key = @intCast(key), .is_down = true }));
            engine_mixer.mixInto(&block);
        }
        try expect(engine_mixer.sendNote(.{ .key = 70, .is_down = true }));
        engine_mixer.mixInto(&block);
        try expect(engine_mixer.sendNote(.{ .key = 70, .is_down = false }));
        engine_mixer.mixInto(&block);
        try expect(engine_mixer.sendNote(.{ .key = 80, .is_down = true }));
        engine_mixer.mixInto(&block);
        const notes: SoundingNotes = .of(&engine_mixer.renderer);
        try expect(!notes.isSounding(70));
        try expect(notes.isHeld(80));
        for (40..55) |key| {
            try expect(notes.isHeld(@intCast(key)));
        }
    }

    test "with every note held, the oldest gives up its slot, but not the lowest or the highest" {
        var engine_mixer: Mixer = .{};
        try allocateTestBlocks(&engine_mixer);
        defer freeTestBlocks(&engine_mixer);
        engine_mixer.setInstrument(sine_instrument);
        var block: [@as(usize, 128) * channel_count]f32 = undefined;
        // Sixteen held notes, key 40 the oldest and the lowest, key 55 the highest.
        for (40..56) |key| {
            try expect(engine_mixer.sendNote(.{ .key = @intCast(key), .is_down = true }));
            engine_mixer.mixInto(&block);
        }
        try expect(engine_mixer.sendNote(.{ .key = 60, .is_down = true }));
        engine_mixer.mixInto(&block);
        const notes: SoundingNotes = .of(&engine_mixer.renderer);
        // Key 41 - the oldest that is neither the lowest nor the highest - gave its slot up.
        try expect(!notes.isSounding(41));
        try expect(notes.isHeld(40));
        try expect(notes.isHeld(55));
        try expect(notes.isHeld(60));
        try expectEqual(@as(usize, 16), notes.held_count);
    }

    test "the main side plays only in the slots below the instrument's" {
        var engine_mixer: Mixer = .{};
        try allocateTestBlocks(&engine_mixer);
        defer freeTestBlocks(&engine_mixer);
        var tone_frequency: f32 = 440;
        const tone_source: Source = .{ .generator = .{
            .generate = &generateTestSine,
            .initial_state = asBytes(&tone_frequency),
        } };
        for (0..first_instrument_slot) |_| {
            try expect(engine_mixer.play(tone_source, .{}) != .none);
        }
        try expectEqual(Voice.none, engine_mixer.play(tone_source, .{}));
    }

    test "a sample buffer is registered the first time it plays, and named by that id after" {
        var engine_mixer: Mixer = .{};
        try allocateTestBlocks(&engine_mixer);
        defer freeTestBlocks(&engine_mixer);
        const owned_samples: []f32 = try testing_allocator.alloc(f32, 480);
        @memset(owned_samples, 0.25);
        const owned_source: Source = .{ .samples = .{
            .samples = owned_samples,
            .channels = 1,
            .sample_rate = sample_rate,
        } };
        try expectEqual(@as(?SamplesId, null), engine_mixer.samplesIdOf(owned_samples));
        // Played twice: registered once, under one id.
        _ = engine_mixer.play(owned_source, .{});
        const samples_id: SamplesId = engine_mixer.samplesIdOf(owned_samples).?;
        _ = engine_mixer.play(owned_source, .{});
        try expectEqual(samples_id, engine_mixer.samplesIdOf(owned_samples).?);
        var registered_count: usize = 0;
        for (engine_mixer.samples_registry) |record| {
            if (record.is_registered) {
                registered_count += 1;
            }
        }
        try expectEqual(@as(usize, 1), registered_count);
        // The renderer found the samples by their id, in its own registry - here, the same buffer.
        var block: [64 * 2]f32 = undefined;
        engine_mixer.mixInto(&block);
        try expectEqual(owned_samples.ptr, engine_mixer.renderer.registered_samples[samples_id].ptr);
        // Released - the renderer on this thread - the buffer is freed and its id free again.
        engine_mixer.releaseSamples(testing_allocator, owned_samples);
        try expect(!engine_mixer.samples_registry[samples_id].is_registered);
        // A buffer never played was never registered: released, it is freed at once.
        const never_played_samples: []f32 = try testing_allocator.alloc(f32, 16);
        engine_mixer.releaseSamples(testing_allocator, never_played_samples);
    }

    test "samples released while the renderer runs on another thread are freed only once it lets them go" {
        var engine_mixer: Mixer = .{};
        try allocateTestBlocks(&engine_mixer);
        defer freeTestBlocks(&engine_mixer);
        // The renderer stands in for an audio thread's: the main side must not run it, and the test runs it by hand.
        engine_mixer.is_renderer_on_another_thread = true;
        const owned_samples: []f32 = try testing_allocator.alloc(f32, 4_800);
        @memset(owned_samples, 0.5);
        const owned_source: Source = .{ .samples = .{
            .samples = owned_samples,
            .channels = 1,
            .sample_rate = sample_rate,
        } };
        const voice: Voice = engine_mixer.play(owned_source, .{});
        var block: [100 * 2]f32 = undefined;
        engine_mixer.renderer.render(&engine_mixer.renderer_queues, &block);
        // Played, the samples were registered. Released: nothing is freed yet - the renderer has not seen the command.
        const samples_id: SamplesId = engine_mixer.samplesIdOf(owned_samples).?;
        engine_mixer.releaseSamples(testing_allocator, owned_samples);
        try expect(engine_mixer.samples_registry[samples_id].release_allocator != null);
        // Its next block: the voice copies its tail and fades over it, and the renderer says it let go.
        engine_mixer.renderer.render(&engine_mixer.renderer_queues, &block);
        // The main side reads the notice and frees the samples - the testing allocator would report them leaked, or
        // freed twice, otherwise.
        engine_mixer.readRendererNotices();
        try expect(!engine_mixer.samples_registry[samples_id].is_registered);
        engine_mixer.renderer.render(&engine_mixer.renderer_queues, &block);
        engine_mixer.renderer.render(&engine_mixer.renderer_queues, &block);
        engine_mixer.renderer.render(&engine_mixer.renderer_queues, &block);
        engine_mixer.readRendererNotices();
        try expect(!engine_mixer.isPlaying(voice));
        try expectEqual(@as(u32, 0), engine_mixer.playingVoiceCount());
    }

    test "a voice whose samples are about to be freed fades out over its own copy of them" {
        var engine_mixer: Mixer = .{};
        try allocateTestBlocks(&engine_mixer);
        defer freeTestBlocks(&engine_mixer);
        var constant_samples: [1000]f32 = @splat(0.5);
        const constant_source: Source = .{ .samples = .{
            .samples = &constant_samples,
            .channels = 1,
            .sample_rate = sample_rate,
        } };
        const voice: Voice = engine_mixer.play(constant_source, .{ .pan = -1 });
        var block: [300 * 2]f32 = undefined;
        engine_mixer.mixInto(block[0 .. 10 * 2]);
        const samples_id: SamplesId = engine_mixer.samplesIdOf(&constant_samples).?;
        engine_mixer.renderer.fadeVoicesReading(&engine_mixer.renderer_queues, samples_id);
        // The samples change - as freed memory would - and the voice, reading its own copy, does not notice.
        @memset(&constant_samples, 9.0);
        engine_mixer.mixInto(&block);
        try expect(!engine_mixer.isPlaying(voice));
        try expect(block[0] < 0.5 and block[0] > 0.49);
        try expectApproxEqAbs(@as(f32, 0.25), block[119 * 2], 0.003);
        try expectEqual(@as(f32, 0), block[fade_out_frames * 2]);
        try expectEqual(@as(u32, 0), engine_mixer.playingVoiceCount());
    }

    test "a fade lasts its 5 ms whatever the blocks it falls across, one straight line to silence" {
        var engine_mixer: Mixer = .{};
        try allocateTestBlocks(&engine_mixer);
        defer freeTestBlocks(&engine_mixer);
        var constant_samples: [2000]f32 = @splat(0.5);
        const constant_source: Source = .{ .samples = .{
            .samples = &constant_samples,
            .channels = 1,
            .sample_rate = sample_rate,
        } };
        const voice: Voice = engine_mixer.play(constant_source, .{ .pan = -1 });
        var block: [100 * 2]f32 = undefined;
        engine_mixer.mixInto(block[0 .. 10 * 2]);
        engine_mixer.stopVoice(voice);
        // Three blocks of 100 frames: the fade's 240 frames fall across them, 100, 100 and 40.
        var fade_frame_number: usize = 0;
        var block_number: usize = 0;
        while (block_number < 3) : (block_number += 1) {
            engine_mixer.mixInto(&block);
            var frame_index: usize = 0;
            while (frame_index < 100) : (frame_index += 1) {
                const frames_into_fade: f32 = @floatFromInt(fade_frame_number + 1);
                const fade_frames: f32 = @floatFromInt(fade_out_frames);
                const expected: f32 = @max(0.5 * (1 - frames_into_fade / fade_frames), 0);
                try expectApproxEqAbs(expected, block[frame_index * 2], 0.0001);
                fade_frame_number += 1;
            }
        }
        try expectEqual(@as(u32, 0), engine_mixer.playingVoiceCount());
    }

    test "a stopped voice fades to silence over 5 ms, rather than stopping mid-waveform" {
        var engine_mixer: Mixer = .{};
        try allocateTestBlocks(&engine_mixer);
        defer freeTestBlocks(&engine_mixer);
        // A constant: half on both sides, so the fade's shape is the samples themselves.
        var constant_samples: [1000]f32 = @splat(0.5);
        const constant_source: Source = .{ .samples = .{
            .samples = &constant_samples,
            .channels = 1,
            .sample_rate = sample_rate,
        } };
        const voice: Voice = engine_mixer.play(constant_source, .{ .pan = -1 });
        var block: [300 * 2]f32 = undefined;
        engine_mixer.mixInto(block[0 .. 10 * 2]);
        try expectApproxEqAbs(@as(f32, 0.5), block[9 * 2], 0.0001);
        engine_mixer.stopVoice(voice);
        try expect(!engine_mixer.isPlaying(voice));
        engine_mixer.mixInto(&block);
        // Falling every frame, by 0.5 / 240, to zero at the fade's last frame; silent after it; the slot freed.
        try expect(block[0] < 0.5 and block[0] > 0.49);
        try expectApproxEqAbs(@as(f32, 0.25), block[119 * 2], 0.003);
        try expectApproxEqAbs(@as(f32, 0), block[(fade_out_frames - 1) * 2], 0.0001);
        try expectEqual(@as(f32, 0), block[fade_out_frames * 2]);
        try expectEqual(@as(u32, 0), engine_mixer.playingVoiceCount());
    }

    test "pulled by the headless output, a sound starts at its frame's own time, with no lead" {
        var engine_mixer: Mixer = .{};
        try engine_mixer.start(testing_allocator, outputOf(platform.headless));
        defer engine_mixer.stop();
        try expect(engine_mixer.forwarding == null);
        // Thirty frames at 60 Hz, a constant sound played during frame 10's update.
        var constant_samples: [48_000]f32 = @splat(0.5);
        const constant_source: Source = .{ .samples = .{
            .samples = &constant_samples,
            .channels = 1,
            .sample_rate = sample_rate,
        } };
        var frame_number: usize = 0;
        while (frame_number <= 30) : (frame_number += 1) {
            const frame_number_float: f64 = @floatFromInt(frame_number);
            platform.headless.playAudioUntil(frame_number_float * 1000.0 / 60.0);
            if (frame_number == 10) {
                _ = engine_mixer.play(constant_source, .{ .pan = -1 });
            }
            engine_mixer.mixFrame();
        }
        // Frame 10 is 166.67 ms after the output started, at frame 0: 8 000 frames. Silence before, the sound after.
        const played_samples: []const f32 = platform.headless.playedAudio();
        const first_sound_frame: usize = 8_000;
        try expectEqual(@as(f32, 0), played_samples[(first_sound_frame - 1) * 2]);
        try expectApproxEqAbs(@as(f32, 0.5), played_samples[first_sound_frame * 2], 0.0001);
    }

    test "the mixer through the headless output: a second of a tone, a frame at a time" {
        var engine_mixer: Mixer = .{};
        try engine_mixer.start(testing_allocator, outputOf(platform.headless));
        defer engine_mixer.stop();
        var tone_frequency: f32 = 440;
        const tone_source: Source = .{ .generator = .{
            .generate = &generateTestSine,
            .initial_state = asBytes(&tone_frequency),
        } };
        _ = engine_mixer.play(tone_source, .{});
        // Sixty frames at 60 Hz, as a run draws them: at each frame's time the output asks the renderer for the
        // frames that came due, then the frame reads the renderer's notices.
        var frame_number: usize = 0;
        while (frame_number <= 60) : (frame_number += 1) {
            const frame_number_float: f64 = @floatFromInt(frame_number);
            const frame_time_ms: f64 = frame_number_float * 1000.0 / 60.0;
            platform.headless.playAudioUntil(frame_time_ms);
            engine_mixer.mixFrame();
        }
        const played_samples: []const f32 = platform.headless.playedAudio();
        try expectEqual(@as(usize, 48_000 * 2), played_samples.len);
        const crossing_count: usize = countRisingZeroCrossings(played_samples);
        try expect(crossing_count >= 439 and crossing_count <= 440);
    }
};

// ============================================================================
// SECTION - audio_device (raylib's InitAudioDevice / CloseAudioDevice family)
// ============================================================================
// The audio device: what raylib's InitAudioDevice and CloseAudioDevice open and close, and its master volume. Here
// it starts and stops the engine's mixer on the platform's output - natively an audio thread, headless the run's
// clock, on a page the renderer in the audio worklet, or the script processor where a page has none - the same on
// every platform: a page holds one audio context, its output's.

pub const audio_device = struct {
    const is_wasm: bool = builtin.target.cpu.arch.isWasm();

    /// The device's state, made by `init` and cleared by `close`.
    pub const AudioDeviceState = struct {
        ready: bool = false,
        /// The audio start screen's progress (`z.showAudioStartScreen`): whether its button was pressed, and whether
        /// the screen is done - pressed, and the output settled.
        is_start_pressed: bool = false,
        is_start_screen_done: bool = false,
        /// Whether a press began on the start screen's button and has not yet ended: only a press begun and ended on
        /// it counts, as a UI button's does.
        is_start_armed: bool = false,
        /// Whether the app shows the start screen at all - it has drawn it once - so that its `on_input` waits for it
        /// to be done (`wgpu_app.dispatchInput`).
        is_start_screen_shown: bool = false,
        /// The rate everything plays at: the mixer's.
        sample_rate: u32 = 0,
        /// The engine's mixer, and the allocator for its blocks: set by the engine as it makes each frame
        /// (`App.makeFrame`), so that `init` starts the mixer and `close` stops it. Null for a state used outside the
        /// engine.
        engine_mixer: ?*mixer.Mixer = null,
        mixer_allocator: ?Allocator = null,
        /// Whether the sound's diagnostics are shown (`showDiagnostics`), so that the engine reports the mixer's state
        /// to them each frame.
        is_showing_diagnostics: bool = false,
    };

    /// Opens the device: starts the engine's mixer on the platform's output, when the engine gave the state one. A
    /// second call while open does nothing. A page's browser starts its audio context suspended until the person's
    /// first gesture, which page audio waits for itself; until then the mixer runs, and nothing is heard.
    pub fn init(state: *AudioDeviceState) void {
        if (state.ready) {
            return;
        }
        startEngineMixer(state);
        // The state set whole, carrying the engine's fields forward.
        state.* = .{
            .ready = true,
            .sample_rate = mixer.sample_rate,
            .engine_mixer = state.engine_mixer,
            .mixer_allocator = state.mixer_allocator,
            .is_showing_diagnostics = state.is_showing_diagnostics,
        };
    }

    /// Shows the sound's state where it can be read on the device - for finding glitches: in the browser, a panel at
    /// the top of the page with the path to the speaker, the context and its latencies, what waits, how often the sink
    /// ran dry, the mixer's margin, underruns and voices, and the newest warnings. Natively the console has the
    /// warnings, and this does nothing.
    pub fn showDiagnostics(state: *AudioDeviceState) void {
        state.is_showing_diagnostics = true;
        if (comptime is_wasm) {
            web.dom.audio_output_show_diagnostics();
        }
    }

    /// Turns the debugging of JavaScript handles on or off, in the page and in its audio worklet: where each handle is
    /// made, recorded; a handle used after it was freed, named with where it was made and freed; a leak alarm that
    /// counts the live handles by the code that made them (the c2js runtime's `js_set_handle_debugging`,
    /// `js_handle_census`). It costs a stack capture for every handle made and freed: a tool for finding a fault,
    /// not for playing. Natively there are no handles, and this does nothing.
    pub fn setHandleDebugging(state: *AudioDeviceState, is_on: bool) void {
        _ = state;
        if (comptime is_wasm) {
            web.dom.audio_output_set_handle_debugging(@intFromBool(is_on));
        }
    }

    /// Reports the mixer's state to the diagnostics, when shown: the engine's, once a frame after the mix.
    pub fn reportToDiagnostics(state: *const AudioDeviceState) void {
        if (!state.is_showing_diagnostics) {
            return;
        }
        const engine_mixer: *mixer.Mixer = state.engine_mixer orelse return;
        if (comptime is_wasm) {
            const voice_count: u32 = engine_mixer.playingVoiceCount();
            web.dom.audio_output_note_mixer(voice_count);
        }
    }

    /// Starts the engine's mixer on the platform's output, when the engine gave the state one (`engine_mixer`).
    fn startEngineMixer(state: *AudioDeviceState) void {
        const engine_mixer: *mixer.Mixer = state.engine_mixer orelse return;
        const allocator: Allocator = state.mixer_allocator orelse return;
        engine_mixer.start(allocator, mixer.platformOutput()) catch {
            std.log.scoped(.sound).err("the mixer could not start: out of memory for its blocks", .{});
        };
    }

    /// Closes the device: stops the mixer, every voice with it. A second call does nothing; after it, `init` opens
    /// the device again.
    pub fn close(state: *AudioDeviceState) void {
        if (!state.ready) {
            return;
        }
        if (state.engine_mixer) |engine_mixer| {
            engine_mixer.stop();
        }
        state.ready = false;
        state.sample_rate = 0;
    }

    /// Whether the device is open, and the sound functions take effect.
    pub fn isReady(state: *const AudioDeviceState) bool {
        return state.ready;
    }

    /// The master volume, 1 for full: the mixer's. 1 while the device is closed, or has no mixer.
    pub fn getMasterVolume(state: *const AudioDeviceState) f32 {
        if (!state.ready) {
            return 1.0;
        }
        const engine_mixer: *mixer.Mixer = state.engine_mixer orelse return 1.0;
        return engine_mixer.master_volume;
    }

    /// Sets the master volume, held within 0 to 10: every sample mixed is multiplied by it. Nothing while the device
    /// is closed.
    pub fn setMasterVolume(
        state: *const AudioDeviceState,
        volume: f32,
    ) void {
        if (!state.ready) {
            return;
        }
        if (state.engine_mixer) |engine_mixer| {
            engine_mixer.setMasterVolume(clamp(volume, 0, 10));
        }
    }

    /// The rate everything plays at, the mixer's: 0 while the device is closed.
    pub fn getSampleRate(state: *const AudioDeviceState) u32 {
        return state.sample_rate;
    }

    // ---- Tests
    test "init / close / isReady on host" {
        var ad: AudioDeviceState = .{};
        try expect(!isReady(&ad));
        init(&ad);
        try expect(isReady(&ad));
        // Idempotent: second init is a no-op.
        init(&ad);
        try expect(isReady(&ad));
        close(&ad);
        try expect(!isReady(&ad));
        // Idempotent: second close is a no-op.
        close(&ad);
        try expect(!isReady(&ad));
    }

    test "getSampleRate returns 48000 on host after init" {
        var ad: AudioDeviceState = .{};
        init(&ad);
        defer close(&ad);
        try expectEqual(@as(u32, 48000), getSampleRate(&ad));
    }

    test "getMasterVolume returns 1.0 on host" {
        var ad: AudioDeviceState = .{};
        try expectEqual(@as(f32, 1.0), getMasterVolume(&ad));
        init(&ad);
        defer close(&ad);
        try expectEqual(@as(f32, 1.0), getMasterVolume(&ad));
    }

    test "setMasterVolume on host is silent" {
        var ad: AudioDeviceState = .{};
        // Must not panic regardless of device state or input.
        setMasterVolume(&ad, 0.5);
        init(&ad);
        defer close(&ad);
        setMasterVolume(&ad, 0.5);
        setMasterVolume(&ad, -1.0);
        setMasterVolume(&ad, 100.0);
    }
};

pub const waves = struct {
    /// Allocator used to free wave data.  Stashed at load time;
    /// `unload` consults it.  We keep this in a side-table because
    /// raylib's `Wave` extern struct has no allocator field - we
    /// can't smuggle a per-Wave allocator pointer in the FFI shape.
    /// Storage relocated to user `State` in Phase C4
    /// apps using audio reserve `audio: z.AudioState` in their
    /// State and pass `&state.audio.waves` through the explicit
    /// fn signatures.  Tests construct a stack-local
    /// `var ws: AllocTable = .{};` and pass `&ws`.
    /// Side-table mapping `data` pointers to the allocator used to
    /// allocate them.  Sized to match typical SFX-pool capacity (a
    /// few dozen waves resident at peak).  Falls back to scanning
    /// linearly - fine for this scale; can swap to AutoHashMap if
    /// it becomes a hot path.
    pub const AllocTable = struct {
        const Capacity = 64;
        const Entry = struct {
            ptr: ?*anyopaque = null,
            gpa: ?Allocator = null,
        };
        entries: [Capacity]Entry = @splat(.{}),

        fn put(
            self: *AllocTable,
            ptr: *anyopaque,
            gpa: Allocator,
        ) void {
            for (&self.entries) |*e| {
                if (e.ptr == null) {
                    e.* = .{ .ptr = ptr, .gpa = gpa };
                    return;
                }
            }
            // Out of slots.  Drop the registration silently - the
            // wave data leaks on unload.  Bumping `Capacity` is the
            // fix; for now we log at the highest-volume call site
            // so it surfaces if it ever happens.
        }

        fn take(self: *AllocTable, ptr: *anyopaque) ?Allocator {
            for (&self.entries) |*e| {
                if (e.ptr == ptr) {
                    const gpa: ?Allocator = e.gpa;
                    e.* = .{};
                    return gpa;
                }
            }
            return null;
        }
    };

    /// Decode `bytes` into a `Wave`.  `file_type` is a hint string
    /// like ".wav" or ".ogg" - used to pick a codec when magic-byte
    /// sniffing is ambiguous.  Currently the magic-byte sniff
    /// (`Format.detect`) wins; `file_type` is informational.
    /// For sync-decodable formats (WAV) the decoded Wave is
    /// returned immediately.  For OGG (browser-only path) this
    /// errors with `error.OggRequiresAsyncDecode` - callers should
    /// use `sounds.loadFromMemory` instead, which has the
    /// async-friendly Sound type.
    /// Returns an empty Wave on decode failure (frameCount = 0,
    /// data = null) - matches raylib's contract that
    /// `IsWaveValid` distinguishes good from bad waves.
    pub fn loadFromMemory(
        state: *AllocTable,
        gpa: Allocator,
        file_type: []const u8,
        bytes: []const u8,
    ) !Wave {
        _ = file_type;
        const fmt: codecs.audio.Format = codecs.audio.Format.detect(bytes) orelse return error.UnknownAudioFormat;
        if (!fmt.syncDecodable()) {
            return error.OggRequiresAsyncDecode;
        }
        var reader: Io.Reader = .fixed(bytes);
        const cw: codecs.audio.CanonicalWave = try fmt.decode(gpa, &reader);
        defer cw.deinit();
        const w: Wave = try codecs.audio.waveFromCanonical(gpa, cw);
        if (w.data) |p| {
            state.put(p, gpa);
        }
        return w;
    }

    /// Free a Wave's sample data.  Idempotent on null/zero waves.
    pub fn unload(
        state: *AllocTable,
        wave: Wave,
    ) void {
        const data: *anyopaque = wave.data orelse return;
        const gpa: Allocator = state.take(data) orelse return;
        const byte_len: usize = @as(usize, wave.frameCount) *
            @as(usize, wave.channels) *
            (@as(usize, wave.sampleSize) / 8);
        if (byte_len == 0) {
            return;
        }
        const data_ptr: [*]u8 = @ptrCast(data);
        gpa.free(data_ptr[0..byte_len]);
    }

    /// Whether the Wave's parameters describe loaded, well-formed
    /// audio.
    pub fn isValid(wave: Wave) bool {
        if (wave.data == null) {
            return false;
        }
        if (wave.frameCount == 0) {
            return false;
        }
        if (wave.sampleRate == 0) {
            return false;
        }
        if (wave.channels == 0) {
            return false;
        }
        // sampleSize: only the bit depths we support.
        return wave.sampleSize == 8 or wave.sampleSize == 16 or wave.sampleSize == 32;
    }

    /// Deep-copy a Wave (allocates fresh sample data).  The new
    /// wave is owned by `gpa`; caller `unload`s it.
    pub fn copy(
        state: *AllocTable,
        gpa: Allocator,
        wave: Wave,
    ) !Wave {
        const byte_len: usize = @as(usize, wave.frameCount) *
            @as(usize, wave.channels) *
            (@as(usize, wave.sampleSize) / 8);
        const new_bytes = try gpa.alloc(u8, byte_len);
        errdefer gpa.free(new_bytes);
        if (wave.data) |src| {
            const src_ptr: [*]const u8 = @ptrCast(src);
            @memcpy(new_bytes, src_ptr[0..byte_len]);
        }
        const new_wave: Wave = .{
            .frameCount = wave.frameCount,
            .sampleRate = wave.sampleRate,
            .sampleSize = wave.sampleSize,
            .channels = wave.channels,
            .data = @as(?*anyopaque, @ptrCast(new_bytes.ptr)),
        };
        state.put(@ptrCast(new_bytes.ptr), gpa);
        return new_wave;
    }

    /// Crop the wave in-place to the frame range `[init_frame, final_frame)`.
    /// Frees the original sample data and replaces it with a
    /// freshly-allocated subrange.  Out-of-range frames are clamped
    /// to the wave's bounds; if the resulting range is empty the
    /// wave becomes empty (frameCount = 0, data = null).
    pub fn crop(
        state: *AllocTable,
        gpa: Allocator,
        wave: *Wave,
        init_frame: u32,
        final_frame: u32,
    ) !void {
        if (!isValid(wave.*)) {
            return;
        }
        const start: u32 = @min(init_frame, wave.frameCount);
        const end: u32 = @min(final_frame, wave.frameCount);
        if (start >= end) {
            unload(state, wave.*);
            wave.* = .{
                .frameCount = 0,
                .sampleRate = wave.sampleRate,
                .sampleSize = wave.sampleSize,
                .channels = wave.channels,
                .data = null,
            };
            return;
        }
        const bytes_per_frame: u32 = wave.channels * (wave.sampleSize / 8);
        const new_byte_len: usize = (end - start) * bytes_per_frame;
        const new_bytes = try gpa.alloc(u8, new_byte_len);
        errdefer gpa.free(new_bytes);
        if (wave.data) |src| {
            const src_ptr: [*]const u8 = @ptrCast(src);
            const start_byte: usize = start * bytes_per_frame;
            @memcpy(new_bytes, src_ptr[start_byte .. start_byte + new_byte_len]);
        }
        unload(state, wave.*);
        wave.* = .{
            .frameCount = end - start,
            .sampleRate = wave.sampleRate,
            .sampleSize = wave.sampleSize,
            .channels = wave.channels,
            .data = @as(?*anyopaque, @ptrCast(new_bytes.ptr)),
        };
        state.put(@ptrCast(new_bytes.ptr), gpa);
    }

    /// Convert the wave to a desired sample rate / bit depth /
    /// channel count, in place.  Goes through the canonical f32
    /// stereo intermediate via `toFloat32Stereo` + `resampleLinear`,
    /// then quantizes back to the requested bit depth.
    /// Supported `sample_size` values: 8, 16, 32.  Channel counts:
    /// 1 (mono), 2 (stereo).  Other values are unchanged.
    /// Note: 8-bit conversion is lossy; use 16-bit or 32-bit for
    /// quality.
    pub fn format(
        state: *AllocTable,
        gpa: Allocator,
        wave: *Wave,
        sample_rate: u32,
        sample_size: u32,
        channels: u32,
    ) !void {
        if (!isValid(wave.*)) {
            return;
        }
        if (sample_size != 8 and sample_size != 16 and sample_size != 32) {
            return error.UnsupportedSampleSize;
        }
        if (channels != 1 and channels != 2) {
            return error.UnsupportedChannelCount;
        }

        const cw: codecs.audio.CanonicalWave = codecs.audio.canonicalFromWave(wave.*);
        // Step 1: canonical f32 stereo at source rate.
        const stereo_f32: []f32 = try codecs.audio.wav.toFloat32Stereo(gpa, cw);
        defer gpa.free(stereo_f32);

        // Step 2: resample to target rate if needed.
        const resampled: []f32 = if (sample_rate == wave.sampleRate)
            try gpa.dupe(f32, stereo_f32)
        else
            try codecs.audio.wav.resampleLinear(gpa, stereo_f32, 2, wave.sampleRate, sample_rate);
        defer gpa.free(resampled);

        // Step 3: quantize back to requested bit depth, downmixing
        // to mono if requested.
        const out_frames: usize = resampled.len / 2;
        const bytes_per_sample: usize = sample_size / 8;
        const out_byte_len: usize = out_frames * channels * bytes_per_sample;
        const out_bytes = try gpa.alloc(u8, out_byte_len);
        errdefer gpa.free(out_bytes);

        for (0..out_frames) |f| {
            const l: f32 = resampled[f * 2 + 0];
            const r: f32 = resampled[f * 2 + 1];
            const mono: f32 = (l + r) * 0.5;
            for (0..channels) |c| {
                const sample: f32 = switch (channels) {
                    1 => mono,
                    2 => if (c == 0) l else r,
                    else => 0.0,
                };
                writeSampleAt(out_bytes, f, c, channels, sample_size, sample);
            }
        }

        unload(state, wave.*);
        wave.* = .{
            .frameCount = @intCast(out_frames),
            .sampleRate = sample_rate,
            .sampleSize = sample_size,
            .channels = channels,
            .data = @as(?*anyopaque, @ptrCast(out_bytes.ptr)),
        };
        state.put(@ptrCast(out_bytes.ptr), gpa);
    }

    /// Write one f32 sample (in `[-1, 1]` range) into `out` at the
    /// given frame/channel slot, quantized to `sample_size` bits.
    fn writeSampleAt(
        out: []u8,
        frame: usize,
        channel: usize,
        channels: u32,
        sample_size: u32,
        value: f32,
    ) void {
        const bytes_per_sample: usize = sample_size / 8;
        const offset: usize = (frame * channels + channel) * bytes_per_sample;
        const clamped: f32 = clamp(value, -1.0, 1.0);
        switch (sample_size) {
            8 => {
                // Unsigned with bias 128.
                const v_i: i32 = @round(clamped * 127.0 + 128.0);
                out[offset] = @intCast(clamp(v_i, 0, 255));
            },
            16 => {
                const v_i: i32 = @round(clamped * 32767.0);
                const clipped: i16 = @intCast(clamp(v_i, -32768, 32767));
                writeInt(i16, out[offset..][0..2], clipped, .little);
            },
            32 => {
                // 32-bit IEEE float passthrough (no clipping needed).
                writeInt(u32, out[offset..][0..4], @bitCast(clamped), .little);
            },
            else => {},
        }
    }

    /// Decode a Wave to a fresh `[]f32` interleaved (per-channel
    /// layout matches the wave's channel count).  Mirror of
    /// raylib's `LoadWaveSamples`; caller frees via
    /// `unloadSamples`.
    /// For raylib parity the output channel count matches the
    /// input wave's.  For canonical-stereo output, callers should
    /// use `codecs.audio.wav.toFloat32Stereo` directly.
    pub fn loadSamples(
        gpa: Allocator,
        wave: Wave,
    ) ![]f32 {
        if (!isValid(wave)) {
            return try gpa.alloc(f32, 0);
        }
        // toFloat32Stereo always emits 2 channels - for raylib
        // parity we need to either passthrough (already stereo) or
        // duplicate (mono -> stereo would change the channel count
        // semantically).  Easier path: walk the bytes ourselves
        // using the same per-bit-depth normalization.
        const cw: codecs.audio.CanonicalWave = codecs.audio.canonicalFromWave(wave);
        const ch: usize = wave.channels;
        const fc: usize = wave.frameCount;
        const out = try gpa.alloc(f32, fc * ch);
        errdefer gpa.free(out);
        const bytes_per_sample: usize = wave.sampleSize / 8;
        for (0..fc) |f| {
            for (0..ch) |c| {
                const byte_off: usize = (f * ch + c) * bytes_per_sample;
                out[f * ch + c] = readSampleAt(cw, byte_off);
            }
        }
        return out;
    }

    /// Free a buffer returned by `loadSamples`.
    pub fn unloadSamples(
        gpa: Allocator,
        samples: []f32,
    ) void {
        gpa.free(samples);
    }

    /// Encode a Wave to RIFF/WAVE bytes.  Returns owned bytes; caller
    /// frees via `gpa.free`.  Output format mirrors the wave's input
    /// format - `wave.sampleSize` and the implicit format tag (PCM
    /// int for 8/16-bit, IEEE float for 32-bit) are written as-is.
    /// raylib's `ExportWave(wave, fileName)` writes to disk; on the
    /// web we have no filesystem, so this returns bytes the caller
    /// can hand to `dom.downloadBlob` or fetch upload.  Same name
    /// space, different I/O.
    pub fn exportToMemory(
        gpa: Allocator,
        wave: Wave,
    ) ![]u8 {
        if (!isValid(wave)) {
            return error.InvalidWave;
        }
        const cw: codecs.audio.CanonicalWave = codecs.audio.canonicalFromWave(wave);
        const fmt_code: codecs.audio.wav.ExportOptions = .{
            .bits = @intCast(wave.sampleSize),
            .format_code = if (wave.sampleSize == 32) .ieee_float else .pcm,
        };
        var aw: Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        try codecs.audio.wav.encode(cw, &aw.writer, fmt_code);
        return aw.toOwnedSlice();
    }

    /// How many channels `mixerSamplesOf` gives for `wave`: 1 for a mono wave, so that a pan places it at constant
    /// power, and 2 for any wider one, balanced (`mixer.panLawOf`).
    pub fn mixerChannelsOf(wave: Wave) u8 {
        return if (wave.channels >= 2) 2 else 1;
    }

    /// Read one sample from a CanonicalWave, normalized to f32.
    /// Same conversion as `wav.readSample` but exposed at this
    /// layer so we don't reach into a private fn.
    fn readSampleAt(cw: codecs.audio.CanonicalWave, byte_offset: usize) f32 {
        const bytes_per_sample: usize = cw.sample_size / 8;
        const slice: []const u8 = cw.samples[byte_offset .. byte_offset + bytes_per_sample];
        return switch (cw.sample_size) {
            8 => blk: {
                const raw: u8 = slice[0];
                const centered: f32 = float(@as(i16, raw) - 128);
                break :blk centered / 128.0;
            },
            16 => blk: {
                const raw: i16 = readInt(i16, slice[0..2], .little);
                break :blk float(raw) / 32768.0;
            },
            32 => blk: {
                if (cw.format_tag == .ieee_float) {
                    const raw_u: u32 = readInt(u32, slice[0..4], .little);
                    break :blk @as(f32, @bitCast(raw_u));
                }
                const raw: i32 = readInt(i32, slice[0..4], .little);
                break :blk float(raw) / 2147483648.0;
            },
            else => 0.0,
        };
    }

    /// The wave's samples as the mixer reads them (`mixer.Samples`): interleaved 32-bit floats from -1 to 1, at the
    /// wave's own rate, with `mixerChannelsOf(wave)` channels - a mono wave's one, a wider wave's first two. Each
    /// sample is converted from the wave's own format (`readSampleAt`: 8-bit unsigned, 16- or 32-bit signed, or 32-bit
    /// float). The caller owns the samples.
    pub fn mixerSamplesOf(gpa: Allocator, wave: Wave) ![]f32 {
        if (!isValid(wave)) {
            return error.InvalidWave;
        }
        const canonical: codecs.audio.CanonicalWave = codecs.audio.canonicalFromWave(wave);
        const channel_count: usize = mixerChannelsOf(wave);
        const frame_count: usize = wave.frameCount;
        const bytes_per_sample: usize = wave.sampleSize / 8;
        const bytes_per_frame: usize = bytes_per_sample * wave.channels;
        const mixer_samples: []f32 = try gpa.alloc(f32, frame_count * channel_count);
        for (0..frame_count) |frame_index| {
            for (0..channel_count) |channel| {
                const byte_offset: usize = frame_index * bytes_per_frame + channel * bytes_per_sample;
                mixer_samples[frame_index * channel_count + channel] = readSampleAt(canonical, byte_offset);
            }
        }
        return mixer_samples;
    }

    test "a wave's samples become the mixer's floats: mono kept mono, a wider wave's first two channels" {
        // 16-bit mono: 0, half, minus half, full.
        var mono_data: [4]i16 = .{ 0, 16_384, -16_384, 32_767 };
        const mono_wave: Wave = .{
            .frameCount = 4,
            .sampleRate = 22_050,
            .sampleSize = 16,
            .channels = 1,
            .data = &mono_data,
        };
        const mono_samples: []f32 = try mixerSamplesOf(testing_allocator, mono_wave);
        defer testing_allocator.free(mono_samples);
        try expectEqual(@as(u8, 1), mixerChannelsOf(mono_wave));
        try expectEqual(@as(usize, 4), mono_samples.len);
        try expectApproxEqAbs(@as(f32, 0.5), mono_samples[1], 0.0001);
        try expectApproxEqAbs(@as(f32, -0.5), mono_samples[2], 0.0001);
        // 8-bit, three channels - unsigned, 128 the middle: two frames, each keeping its first two channels.
        var wide_data: [6]u8 = .{ 128, 192, 0, 64, 128, 255 };
        const wide_wave: Wave = .{
            .frameCount = 2,
            .sampleRate = 8_000,
            .sampleSize = 8,
            .channels = 3,
            .data = &wide_data,
        };
        const wide_samples: []f32 = try mixerSamplesOf(testing_allocator, wide_wave);
        defer testing_allocator.free(wide_samples);
        try expectEqual(@as(usize, 4), wide_samples.len);
        try expectApproxEqAbs(@as(f32, 0), wide_samples[0], 0.0001);
        try expectApproxEqAbs(@as(f32, 0.5), wide_samples[1], 0.0001);
        try expectApproxEqAbs(@as(f32, -0.5), wide_samples[2], 0.0001);
        try expectApproxEqAbs(@as(f32, 0), wide_samples[3], 0.0001);
    }

    /// Apply a filter function in-place, freeing the original
    /// sample data once the filter has produced its replacement.
    /// Inspired by lightmix's `filter_with` pattern: filters
    /// take a Wave value, return a fresh Wave; the chain mutator
    /// handles ownership transfer + cleanup.
    /// The filter receives the current Wave and the args tuple;
    /// returns a fresh Wave (must be heap-allocated by the
    /// filter via `gpa`).  After this call, `wave.*` holds the
    /// new wave; the old one is freed.
    /// Composition example:
    ///     try waves.filter(gpa, &w, fadeIn, .{ .ms = 50 });
    ///     try waves.filter(gpa, &w, normalize, .{});
    ///     try waves.filter(gpa, &w, lowpass, .{ .cutoff = 1500.0 });
    pub fn filter(
        state: *AllocTable,
        gpa: Allocator,
        wave: *Wave,
        comptime filter_fn: anytype,
        args: anytype,
    ) !void {
        const new_wave: Wave = try filter_fn(gpa, wave.*, args);
        unload(state, wave.*);
        wave.* = new_wave;
        // Register the new wave's allocation so a later `unload`
        // can free it.  filter_fn allocates with `gpa` but
        // doesn't (and shouldn't) know about the AllocTable.
        if (new_wave.data) |p| {
            state.put(p, gpa);
        }
    }

    // ---- Tests
    test "loadFromMemory + isValid + unload: WAV round trip" {
        const ta: Allocator = testing_allocator;
        var ws: AllocTable = .{};
        const w: Wave = try loadFromMemory(&ws, ta, ".wav", codecs.audio.wav.test_sine_wav);
        defer unload(&ws, w);
        try expect(isValid(w));
        try expectEqual(@as(u32, 11025), w.frameCount);
        try expectEqual(@as(u32, 22050), w.sampleRate);
        try expectEqual(@as(u32, 1), w.channels);
        try expectEqual(@as(u32, 16), w.sampleSize);
    }

    test "loadFromMemory rejects unknown format" {
        const ta: Allocator = testing_allocator;
        var ws: AllocTable = .{};
        try expectError(
            error.UnknownAudioFormat,
            loadFromMemory(&ws, ta, ".png", "\x89PNG\r\n\x1a\n"),
        );
    }

    test "loadFromMemory rejects OGG (must use sounds.loadFromMemory)" {
        const ta: Allocator = testing_allocator;
        var ws: AllocTable = .{};
        try expectError(
            error.OggRequiresAsyncDecode,
            loadFromMemory(&ws, ta, ".ogg", "OggS\x00\x02\x00\x00\x00\x00"),
        );
    }

    test "isValid: rejects empty / null / zero-rate" {
        try expect(!isValid(.{}));
        try expect(
            !isValid(.{ .frameCount = 100, .sampleRate = 44100, .sampleSize = 16, .channels = 1, .data = null }),
        );
        // Non-null data but invalid bit depth.
        var dummy: u8 = 0;
        const data: ?*anyopaque = @ptrCast(&dummy);
        try expect(
            !isValid(.{ .frameCount = 100, .sampleRate = 44100, .sampleSize = 24, .channels = 1, .data = data }),
        );
    }

    test "copy: deep copy with independent ownership" {
        const ta: Allocator = testing_allocator;
        var ws: AllocTable = .{};
        const orig: Wave = try loadFromMemory(&ws, ta, ".wav", codecs.audio.wav.test_sine_wav);
        defer unload(&ws, orig);
        const dup: Wave = try copy(&ws, ta, orig);
        defer unload(&ws, dup);
        try expect(orig.data != dup.data);
        try expectEqual(orig.frameCount, dup.frameCount);
        // Data bytes equal.
        const orig_ptr: [*]const u8 = @ptrCast(orig.data.?);
        const dup_ptr: [*]const u8 = @ptrCast(dup.data.?);
        const byte_len: usize = orig.frameCount * orig.channels * (orig.sampleSize / 8);
        try expectEqualSlices(u8, orig_ptr[0..byte_len], dup_ptr[0..byte_len]);
    }

    test "crop: shrinks frame range" {
        const ta: Allocator = testing_allocator;
        var ws: AllocTable = .{};
        var w: Wave = try loadFromMemory(&ws, ta, ".wav", codecs.audio.wav.test_sine_wav);
        defer unload(&ws, w);
        try crop(&ws, ta, &w, 1000, 5000);
        try expectEqual(@as(u32, 4000), w.frameCount);
        try expect(isValid(w));
    }

    test "crop: out-of-range bounds clamp to empty" {
        const ta: Allocator = testing_allocator;
        var ws: AllocTable = .{};
        var w: Wave = try loadFromMemory(&ws, ta, ".wav", codecs.audio.wav.test_sine_wav);
        defer unload(&ws, w);
        try crop(&ws, ta, &w, 100000, 200000);
        try expectEqual(@as(u32, 0), w.frameCount);
        try expectEqual(@as(?*anyopaque, null), w.data);
        // Now invalid (no data) - unload is a no-op.
        try expect(!isValid(w));
    }

    test "format: 22050 mono 16-bit -> 44100 stereo 16-bit" {
        const ta: Allocator = testing_allocator;
        var ws: AllocTable = .{};
        var w: Wave = try loadFromMemory(&ws, ta, ".wav", codecs.audio.wav.test_sine_wav);
        defer unload(&ws, w);
        try format(&ws, ta, &w, 44100, 16, 2);
        try expectEqual(@as(u32, 44100), w.sampleRate);
        try expectEqual(@as(u32, 2), w.channels);
        try expectEqual(@as(u32, 16), w.sampleSize);
        // 11025 source frames at 22050 Hz, doubled -> 22050 frames at 44100 Hz.
        try expectEqual(@as(u32, 22050), w.frameCount);
    }

    test "loadSamples / unloadSamples: f32 roundtrip" {
        const ta: Allocator = testing_allocator;
        var ws: AllocTable = .{};
        const w: Wave = try loadFromMemory(&ws, ta, ".wav", codecs.audio.wav.test_sine_wav);
        defer unload(&ws, w);
        const samples: []f32 = try loadSamples(ta, w);
        defer unloadSamples(ta, samples);
        try expectEqual(@as(usize, 11025), samples.len);
        // Samples are normalized to [-1, 1].
        for (samples) |s| {
            try expect(s >= -1.0 and s <= 1.0);
        }
    }

    test "filter chain: scale + normalize" {
        const ta: Allocator = testing_allocator;
        var ws: waves.AllocTable = .{};
        var w: Wave = try loadFromMemory(&ws, ta, ".wav", codecs.audio.wav.test_sine_wav);
        defer unload(&ws, w);

        // A simple in-place "halve" filter: build a new wave with
        // each 16-bit sample divided by 2.
        const halve = struct {
            fn run(gpa: Allocator, src: Wave, _: anytype) !Wave {
                const byte_len: usize = src.frameCount * src.channels * (src.sampleSize / 8);
                const new_bytes = try gpa.alloc(u8, byte_len);
                errdefer gpa.free(new_bytes);
                const src_ptr: [*]const u8 = @ptrCast(src.data.?);
                const sample_count: usize = byte_len / 2;
                for (0..sample_count) |i| {
                    const off: usize = i * 2;
                    const v: i16 = readInt(i16, src_ptr[off..][0..2], .little);
                    writeInt(i16, new_bytes[off..][0..2], @divTrunc(v, 2), .little);
                }
                const new_wave: Wave = .{
                    .frameCount = src.frameCount,
                    .sampleRate = src.sampleRate,
                    .sampleSize = src.sampleSize,
                    .channels = src.channels,
                    .data = @as(?*anyopaque, @ptrCast(new_bytes.ptr)),
                };
                // filter() registers the alloc; we don't need to.
                return new_wave;
            }
        }.run;

        const orig_first: i16 = blk: {
            const ptr: [*]const u8 = @ptrCast(w.data.?);
            break :blk readInt(i16, ptr[0..2], .little);
        };
        try filter(&ws, ta, &w, halve, .{});
        const new_first: i16 = blk: {
            const ptr: [*]const u8 = @ptrCast(w.data.?);
            break :blk readInt(i16, ptr[0..2], .little);
        };
        try expectEqual(@divTrunc(orig_first, 2), new_first);
        // frameCount/etc preserved across filter.
        try expectEqual(@as(u32, 11025), w.frameCount);
    }

    test "exportToMemory: round-trip via decode" {
        const ta: Allocator = testing_allocator;
        var ws: AllocTable = .{};
        const orig: Wave = try loadFromMemory(&ws, ta, ".wav", codecs.audio.wav.test_sine_wav);
        defer unload(&ws, orig);

        const wav_bytes: []u8 = try exportToMemory(ta, orig);
        defer ta.free(wav_bytes);
        // Encoded bytes start with RIFF/WAVE.
        try expect(wav_bytes.len >= 44);
        try expectEqualSlices(u8, "RIFF", wav_bytes[0..4]);
        try expectEqualSlices(u8, "WAVE", wav_bytes[8..12]);

        // Decode the encoded bytes - should be byte-identical to source.
        const decoded: Wave = try loadFromMemory(&ws, ta, ".wav", wav_bytes);
        defer unload(&ws, decoded);
        try expectEqual(orig.frameCount, decoded.frameCount);
        try expectEqual(orig.sampleRate, decoded.sampleRate);
        try expectEqual(orig.channels, decoded.channels);
        try expectEqual(orig.sampleSize, decoded.sampleSize);
    }

    test "exportToMemory: rejects invalid wave" {
        const ta: Allocator = testing_allocator;
        try expectError(error.InvalidWave, exportToMemory(ta, .{}));
    }
};

pub const composer = struct {
    /// Default output format for composer-generated waves.  Picked
    /// to match the most common SFX target.
    pub const default_sample_rate: u32 = 44100;
    pub const default_sample_size: u32 = 16;
    pub const default_channels: u32 = 1;

    /// Available waveform shapes.  Each is a closed-form function
    /// of phase in [0, 1).
    pub const Shape = enum {
        sine,
        square,
        triangle,
        sawtooth,

        /// Sample value at `phase_turns`, a turn count on [0, 1). Result on [-1, 1].
        pub fn sample(self: Shape, phase_turns: f32) f32 {
            return switch (self) {
                // TURNS, BECAUSE `phase_turns` WAS ALREADY ONE
                //
                // `phase_turns` is kept on [0, 1) and wrapped by the caller, so multiplying by tau here
                // existed only to satisfy `@sin` - which divides it straight back out. Measured
                // over one cycle at 48 kHz against the f64 answer, the radian route is off by up
                // to 4.11e-7 and this by 1.04e-7, and the half-cycle zero crossing goes from
                // 8.74e-8 to 1.22e-16.
                .sine => sinTurns(phase_turns),
                .square => if (phase_turns < 0.5) 1.0 else -1.0,
                .triangle => blk: {
                    if (phase_turns < 0.5) {
                        break :blk -1.0 + 4.0 * phase_turns;
                    }
                    break :blk 3.0 - 4.0 * phase_turns;
                },
                .sawtooth => 2.0 * phase_turns - 1.0,
            };
        }
    };

    /// ADSR envelope parameters.  Times in milliseconds; sustain in
    /// `[0, 1]` (relative to peak).  All-zero defaults yield a
    /// rectangular envelope (no shaping).
    pub const Envelope = struct {
        attack_ms: f32 = 0.0,
        decay_ms: f32 = 0.0,
        sustain_level: f32 = 1.0,
        release_ms: f32 = 0.0,

        /// Compute the envelope's gain at the given offset (in
        /// frames).  `total_frames` is the full tone duration.
        fn gainAt(
            self: Envelope,
            frame: u32,
            total_frames: u32,
            sample_rate: u32,
        ) f32 {
            if (total_frames == 0) {
                return 0.0;
            }
            const t_ms: f32 = float(frame) * 1000.0 /
                float(sample_rate);
            const total_ms: f32 = float(total_frames) * 1000.0 /
                float(sample_rate);
            const release_start: f32 = total_ms - self.release_ms;

            // Attack: 0 -> 1 over attack_ms.
            if (t_ms < self.attack_ms) {
                if (self.attack_ms == 0.0) {
                    return 1.0;
                }
                return t_ms / self.attack_ms;
            }
            // Decay: 1 -> sustain_level over decay_ms after attack.
            if (t_ms < self.attack_ms + self.decay_ms) {
                if (self.decay_ms == 0.0) {
                    return self.sustain_level;
                }
                const phase: f32 = (t_ms - self.attack_ms) / self.decay_ms;
                return 1.0 + phase * (self.sustain_level - 1.0);
            }
            // Release: sustain_level -> 0 over release_ms before end.
            if (t_ms >= release_start) {
                if (self.release_ms == 0.0) {
                    return 0.0;
                }
                const phase: f32 = (t_ms - release_start) / self.release_ms;
                return self.sustain_level * (1.0 - phase);
            }
            // Sustain.
            return self.sustain_level;
        }
    };

    /// Tone-generation options.  Picked so the common case (a
    /// 100-ms beep) is `.{ .frequency_hz = 880.0, .duration_ms =
    /// 100 }` with zero further config.
    pub const ToneOptions = struct {
        frequency_hz: f32,
        duration_ms: u32,
        shape: Shape = .sine,
        amplitude: f32 = 0.5,
        sample_rate: u32 = default_sample_rate,
        envelope: Envelope = .{},
    };

    /// Generate a tone Wave according to `opts`.  Output is 16-bit
    /// signed PCM mono at the requested sample rate; caller `unload`s.
    /// The envelope shapes amplitude over the whole duration; with
    /// `.attack_ms = 0` and `.release_ms = 0` the output is a hard-
    /// gated tone (audible click at start/end at higher amplitudes).
    /// Sub-millisecond attack/release is fine - even 2 ms is enough
    /// to suppress the click.
    /// Synthesize a single tone Wave at the given frequency / shape /
    /// duration.  The result is 16-bit signed PCM at `opts.sample_rate`,
    /// `default_channels` (1) channels.  Caller owns the Wave and must
    /// `waves.unload(waves_state, w)` to free it.
    /// Reads `opts` (frequency, shape, duration, envelope, amplitude,
    /// sample_rate).  Mutates `gpa.*` (allocates the PCM buffer +
    /// registers it into `waves_state`).  Mutates `waves_state.entries`
    /// (registers the new buffer for tracking, so a later
    /// `waves.unload` can find + free it).
    pub fn tone(
        waves_state: *waves.AllocTable,
        gpa: Allocator,
        opts: ToneOptions,
    ) !Wave {
        const sr: u32 = opts.sample_rate;
        const total_frames: u32 = (sr * opts.duration_ms + 500) / 1000;
        const byte_len: usize = @as(usize, total_frames) * 2;
        const out: []u8 = try gpa.alloc(u8, byte_len);
        errdefer gpa.free(out);

        const phase_step: f32 = opts.frequency_hz / float(sr);
        var phase: f32 = 0.0;
        for (0..total_frames) |f| {
            const env: f32 = opts.envelope.gainAt(@intCast(f), total_frames, sr);
            const raw: f32 = opts.shape.sample(phase) * opts.amplitude * env;
            const v_i: i32 = @round(raw * 32767.0);
            const clipped: i16 = @intCast(clamp(v_i, -32768, 32767));
            writeInt(i16, out[f * 2 ..][0..2], clipped, .little);
            phase += phase_step;
            if (phase >= 1.0) {
                phase -= 1.0;
            }
        }

        const w: Wave = .{
            .frameCount = total_frames,
            .sampleRate = sr,
            .sampleSize = default_sample_size,
            .channels = default_channels,
            .data = @as(?*anyopaque, @ptrCast(out.ptr)),
        };
        waves_state.put(@ptrCast(out.ptr), gpa);
        return w;
    }

    /// Silence-Wave generator.  Useful as a sequencer pad or as a
    /// time-aligned spacer between tones.  Caller owns the Wave;
    /// `waves.unload(waves_state, w)` to free it.
    /// Reads `duration_ms`, `sample_rate`.  Mutates `gpa.*`
    /// (allocates the zeroed PCM buffer).  Mutates
    /// `waves_state.entries` (registers the new buffer for
    /// tracking).
    pub fn silence(
        waves_state: *waves.AllocTable,
        gpa: Allocator,
        duration_ms: u32,
        sample_rate: u32,
    ) !Wave {
        const total_frames: u32 = (sample_rate * duration_ms + 500) / 1000;
        const byte_len: usize = @as(usize, total_frames) * 2;
        const out: []u8 = try gpa.alloc(u8, byte_len);
        @memset(out, 0);
        const w: Wave = .{
            .frameCount = total_frames,
            .sampleRate = sample_rate,
            .sampleSize = default_sample_size,
            .channels = default_channels,
            .data = @as(?*anyopaque, @ptrCast(out.ptr)),
        };
        waves_state.put(@ptrCast(out.ptr), gpa);
        return w;
    }

    /// One placement entry inside a Sequence: place `wave` starting
    /// at `start_frame` (offset from the sequence origin).  Multiple
    /// placements at overlapping time ranges sum sample-wise, with
    /// hard clipping.
    pub const Placement = struct {
        wave: Wave,
        start_frame: u32,
    };

    /// Multi-wave sequencer / mixer.  Build with `init`, append
    /// placements with `add`, finalize with `finalize`.
    /// All placements must share the same sample_rate + channels;
    /// `add` doesn't validate (caller's contract).  Finalize emits
    /// a single Wave with frameCount = max(start_frame +
    /// wave.frameCount) across all placements.
    pub const Sequence = struct {
        placements: ArrayList(Placement),
        gpa: Allocator,
        waves_state: *waves.AllocTable,
        sample_rate: u32,
        channels: u32,
        /// The least length of the finished wave, in frames: a loop's whole bar, so that a pattern whose last sound
        /// ends early still lasts its bar and loops in time. 0: the wave ends where its last sound ends.
        length_frames: u32 = 0,

        pub fn init(
            waves_state: *waves.AllocTable,
            gpa: Allocator,
            sample_rate: u32,
            channels: u32,
        ) Sequence {
            return .{
                .placements = .empty,
                .gpa = gpa,
                .waves_state = waves_state,
                .sample_rate = sample_rate,
                .channels = channels,
            };
        }

        pub fn deinit(self: *Sequence) void {
            self.placements.deinit(self.gpa);
        }

        /// Schedule `wave` to play starting at `start_frame`.
        /// The Sequence does NOT take ownership of the wave
        /// caller is responsible for keeping it alive until
        /// finalize.
        pub fn add(
            self: *Sequence,
            wave: Wave,
            start_frame: u32,
        ) !void {
            try self.placements.append(self.gpa, .{ .wave = wave, .start_frame = start_frame });
        }

        /// Mix all placements into a single Wave at the sequence's
        /// sample_rate + channels.  Output bit depth is 16-bit signed
        /// PCM.  Mixing is sample-wise sum with hard clipping at
        /// the int16 range.
        /// Note: cross-rate / cross-bit-depth mixing is NOT
        /// supported by this minimal mixer - placements must share
        /// the sequence's format (16-bit PCM at the same rate).
        /// Use `waves.format` to convert before adding.
        /// Reads `self.placements` (frame ranges + wave data),
        /// `self.sample_rate`, `self.channels`.  Mutates
        /// `self.gpa.*` (allocates the mixed buffer).  Mutates
        /// `self.waves_state.entries` (registers the new buffer
        /// for tracking).
        pub fn finalize(self: Sequence) !Wave {
            // Compute total frame extent.
            var max_end: u32 = 0;
            for (self.placements.items) |p| {
                const end: u32 = p.start_frame + p.wave.frameCount;
                if (end > max_end) {
                    max_end = end;
                }
            }
            max_end = @max(max_end, self.length_frames);
            if (max_end == 0) {
                return silence(self.waves_state, self.gpa, 0, self.sample_rate);
            }
            const byte_len: usize = @as(usize, max_end) * self.channels * 2;
            const out = try self.gpa.alloc(u8, byte_len);
            @memset(out, 0);
            errdefer self.gpa.free(out);

            // Per-frame accumulator.  i32 to give us headroom for
            // overlapping placements before we clip.
            const accum = try self.gpa.alloc(i32, max_end * self.channels);
            defer self.gpa.free(accum);
            @memset(accum, 0);

            for (self.placements.items) |p| {
                if (p.wave.data == null) {
                    continue;
                }
                const src_ptr: [*]const u8 = @ptrCast(p.wave.data.?);
                const fc: u32 = p.wave.frameCount;
                const ch: u32 = p.wave.channels;
                for (0..fc) |f| {
                    for (0..ch) |c| {
                        const out_frame: u32 = p.start_frame + @as(u32, @intCast(f));
                        if (out_frame >= max_end) {
                            break;
                        }
                        const src_off: usize = (f * ch + c) * 2;
                        const v: i16 = readInt(i16, src_ptr[src_off..][0..2], .little);
                        const out_idx: usize = out_frame * self.channels + c;
                        accum[out_idx] += v;
                    }
                }
            }

            // Clip + serialize.
            for (0..accum.len) |i| {
                const v: i32 = accum[i];
                const clipped: i16 = @intCast(clamp(v, -32768, 32767));
                writeInt(i16, out[i * 2 ..][0..2], clipped, .little);
            }

            const w: Wave = .{
                .frameCount = max_end,
                .sampleRate = self.sample_rate,
                .sampleSize = default_sample_size,
                .channels = self.channels,
                .data = @as(?*anyopaque, @ptrCast(out.ptr)),
            };
            self.waves_state.put(@ptrCast(out.ptr), self.gpa);
            return w;
        }
    };

    // ---- Tests
    test "Shape.sample: sine zero crossings" {
        try expectApproxEqAbs(@as(f32, 0.0), Shape.sine.sample(0.0), 0.001);
        try expectApproxEqAbs(@as(f32, 1.0), Shape.sine.sample(0.25), 0.001);
        try expectApproxEqAbs(@as(f32, 0.0), Shape.sine.sample(0.5), 0.001);
        try expectApproxEqAbs(@as(f32, -1.0), Shape.sine.sample(0.75), 0.001);
    }

    test "Shape.sample: square +/-1" {
        try expectEqual(@as(f32, 1.0), Shape.square.sample(0.0));
        try expectEqual(@as(f32, 1.0), Shape.square.sample(0.499));
        try expectEqual(@as(f32, -1.0), Shape.square.sample(0.5));
        try expectEqual(@as(f32, -1.0), Shape.square.sample(0.999));
    }

    test "Shape.sample: triangle peaks" {
        try expectApproxEqAbs(@as(f32, -1.0), Shape.triangle.sample(0.0), 0.001);
        try expectApproxEqAbs(@as(f32, 1.0), Shape.triangle.sample(0.5), 0.001);
    }

    test "Envelope.gainAt: rectangular (all zero) -> unity" {
        const env: Envelope = .{};
        try expectApproxEqAbs(@as(f32, 1.0), env.gainAt(0, 100, 44100), 0.001);
        try expectApproxEqAbs(@as(f32, 1.0), env.gainAt(50, 100, 44100), 0.001);
    }

    test "Envelope.gainAt: 10 ms attack ramps 0 -> 1" {
        const env: Envelope = .{ .attack_ms = 10.0 };
        // At 5 ms (frame 220 of 44100 Hz) we should be at 0.5.
        try expectApproxEqAbs(@as(f32, 0.5), env.gainAt(220, 4410, 44100), 0.05);
    }

    test "tone: A440 sine for 50 ms" {
        const ta: Allocator = testing_allocator;
        var ws: waves.AllocTable = .{};
        const w: Wave = try tone(&ws, ta, .{ .frequency_hz = 440.0, .duration_ms = 50 });
        defer waves.unload(&ws, w);
        try expect(waves.isValid(w));
        try expectEqual(@as(u32, 44100), w.sampleRate);
        // 50 ms * 44.1 frames/ms = 2205 frames
        try expectEqual(@as(u32, 2205), w.frameCount);
    }

    test "tone with envelope: starts and ends at zero" {
        const ta: Allocator = testing_allocator;
        var ws: waves.AllocTable = .{};
        const w: Wave = try tone(&ws, ta, .{
            .frequency_hz = 440.0,
            .duration_ms = 100,
            .envelope = .{ .attack_ms = 5.0, .release_ms = 5.0 },
        });
        defer waves.unload(&ws, w);
        const ptr: [*]const u8 = @ptrCast(w.data.?);
        const first: i16 = readInt(i16, ptr[0..2], .little);
        try expectEqual(@as(i16, 0), first);
        // Last frame: 4410 - 1 = 4409 -> byte offset 8818.
        const last_off: usize = (w.frameCount - 1) * 2;
        const last: i16 = readInt(i16, ptr[last_off..][0..2], .little);
        // With release ramp, the last frame is at gain = 0, so output ~ 0.
        try expect(@abs(last) < 100);
    }

    test "silence: all zeros" {
        const ta: Allocator = testing_allocator;
        var ws: waves.AllocTable = .{};
        const w: Wave = try silence(&ws, ta, 100, 44100);
        defer waves.unload(&ws, w);
        const ptr: [*]const u8 = @ptrCast(w.data.?);
        const byte_len: usize = w.frameCount * 2;
        for (0..byte_len) |i| {
            try expectEqual(@as(u8, 0), ptr[i]);
        }
    }

    test "Sequence: empty produces empty" {
        const ta: Allocator = testing_allocator;
        var ws: waves.AllocTable = .{};
        var seq: Sequence = .init(&ws, ta, 44100, 1);
        defer seq.deinit();
        const out: Wave = try seq.finalize();
        defer waves.unload(&ws, out);
        try expectEqual(@as(u32, 0), out.frameCount);
    }

    test "Sequence: two non-overlapping tones concatenate" {
        const ta: Allocator = testing_allocator;
        var ws: waves.AllocTable = .{};
        const t1: Wave = try tone(&ws, ta, .{ .frequency_hz = 440.0, .duration_ms = 100 });
        defer waves.unload(&ws, t1);
        const t2: Wave = try tone(&ws, ta, .{ .frequency_hz = 880.0, .duration_ms = 100 });
        defer waves.unload(&ws, t2);
        var seq: Sequence = .init(&ws, ta, 44100, 1);
        defer seq.deinit();
        try seq.add(t1, 0);
        try seq.add(t2, 4410);
        const out: Wave = try seq.finalize();
        defer waves.unload(&ws, out);
        try expectEqual(@as(u32, 4410 + 4410), out.frameCount);
    }

    test "Sequence: overlapping placements sum samples" {
        const ta: Allocator = testing_allocator;
        var ws: waves.AllocTable = .{};
        // Two short, identical waves at the same offset -> sum is
        // ~2x each sample, clipped at i16 range.
        const t1: Wave = try tone(&ws, ta, .{ .frequency_hz = 440.0, .duration_ms = 50 });
        defer waves.unload(&ws, t1);
        const t2: Wave = try tone(&ws, ta, .{ .frequency_hz = 440.0, .duration_ms = 50 });
        defer waves.unload(&ws, t2);
        var seq: Sequence = .init(&ws, ta, 44100, 1);
        defer seq.deinit();
        try seq.add(t1, 0);
        try seq.add(t2, 0);
        const out: Wave = try seq.finalize();
        defer waves.unload(&ws, out);
        try expectEqual(t1.frameCount, out.frameCount);
        // First frame's sample of a sine wave is exactly 0 (sin(0)
        // = 0), so 0 + 0 = 0.
        const ptr: [*]const u8 = @ptrCast(out.data.?);
        const first: i16 = readInt(i16, ptr[0..2], .little);
        try expectEqual(@as(i16, 0), first);
    }
};

pub const streams = struct {
    /// Side-table entry for an AudioStream: its format, as `load` was given it; whether it is paused, and its volume,
    /// pitch and pan, which its voice takes when it starts and as they change; its ring on the engine's mixer, in an
    /// allocation of its own (`RingBox`) - made at its first frames, null before - the voice reading it, `.none` until
    /// it starts, and the mixer.
    const StreamEntry = struct {
        sample_rate: u32 = 0,
        sample_size: u32 = 0,
        channels: u32 = 0,
        paused: bool = false,
        volume: f32 = 1.0,
        pitch: f32 = 1.0,
        pan: f32 = 0.0,
        ring_box: ?*RingBox = null,
        voice: mixer.Voice = .none,
        engine_mixer: ?*mixer.Mixer = null,
        in_use: bool = false,
    };

    pub const StreamTable = struct {
        const Capacity = 32;
        entries: [Capacity]StreamEntry = @splat(.{}),
        /// Rings given up - their stream stopped or unloaded - whose voice may still be reading them: the renderer
        /// reads a stopped voice's ring through its fade-out, on its own thread, until it says the voice has ended.
        /// Each is freed once the renderer holds its voice no more (`collectRetired`, `isStoppedVoiceStillHeld`).
        retired_rings: [Capacity]RetiredRing = @splat(.{}),

        fn allocate(self: *StreamTable) ?u32 {
            for (&self.entries, 0..) |*e, i| {
                if (!e.in_use) {
                    e.* = .{ .in_use = true };
                    return @intCast(i + 1);
                }
            }
            return null;
        }

        fn get(self: *StreamTable, slot: u32) ?*StreamEntry {
            if (slot == 0 or slot > Capacity) {
                return null;
            }
            const e: *StreamEntry = &self.entries[slot - 1];
            if (!e.in_use) {
                return null;
            }
            return e;
        }

        fn getConst(self: *const StreamTable, slot: u32) ?*const StreamEntry {
            if (slot == 0 or slot > Capacity) {
                return null;
            }
            const e: *const StreamEntry = &self.entries[slot - 1];
            if (!e.in_use) {
                return null;
            }
            return e;
        }

        fn release(self: *StreamTable, slot: u32) void {
            if (slot == 0 or slot > Capacity) {
                return;
            }
            self.entries[slot - 1] = .{};
        }

        /// Gives up `entry`'s ring: stops its voice, and keeps the ring for `collectRetired` to free once the voice has
        /// ended - at its next call, if it never played.
        fn retireRing(self: *StreamTable, entry: *StreamEntry) void {
            const ring_box: *RingBox = entry.ring_box orelse return;
            const engine_mixer: *mixer.Mixer = entry.engine_mixer.?;
            if (entry.voice != .none) {
                engine_mixer.stopVoice(entry.voice);
            }
            const retired: RetiredRing = .{ .ring_box = ring_box, .voice = entry.voice, .engine_mixer = engine_mixer };
            entry.ring_box = null;
            entry.voice = .none;
            for (&self.retired_rings) |*retired_slot| {
                if (retired_slot.ring_box == null) {
                    retired_slot.* = retired;
                    return;
                }
            }
            // Every place for a retired ring is taken - 32 rings stopped within the few milliseconds their voices take
            // to fade out. This one cannot be freed safely, and is not freed at all.
            std.log.scoped(.streams).warn("{d} stream rings already wait to be freed: one is never freed", .{Capacity});
        }

        /// Frees the retired rings whose voices have ended. Called by the calls that change the table - `load`,
        /// `update`, `stop`, `unload` - so that a game feeding its streams frees each ring within a frame of its
        /// voice's end; and once the mixer is stopped, as the engine stops it before an app's `deinit`, every voice has
        /// ended and an `unload` there frees its ring at once.
        fn collectRetired(self: *StreamTable) void {
            for (&self.retired_rings) |*retired_slot| {
                const ring_box: *RingBox = retired_slot.ring_box orelse continue;
                const engine_mixer: *mixer.Mixer = retired_slot.engine_mixer.?;
                const voice: mixer.Voice = retired_slot.voice;
                const is_voice_reading: bool = voice != .none and engine_mixer.isStoppedVoiceStillHeld(voice);
                if (is_voice_reading) {
                    continue;
                }
                engine_mixer.allocator.?.destroy(ring_box);
                retired_slot.* = .{};
            }
        }
    };

    // ---- Streams on the engine's mixer ----

    // Streams play on the engine's mixer, each a stream voice reading a ring the game writes (`mixer.Stream`), on every
    // platform alike: natively and headless the renderer reads the ring where it lies; on a page the mixer forwards the
    // stream to the renderer in the audio worklet - its frames sent each frame and kept in the ring until the worklet
    // reports them read (`Mixer.forwardStreamFrames`) - so that a stream is written, and its room counted, the same way
    // everywhere.

    /// The frames a stream's ring holds: 2048, 43 ms at 48 000 Hz. `isProcessed` asks for more while half of it is
    /// free, so the game keeps between a half and the whole of it queued: 21 to 43 ms, the most it delays a change in
    /// what it plays.
    const ring_capacity_frames: usize = 2048;

    /// A stream's ring and its samples, in one allocation of their own: the voice reads the ring by its address, which
    /// must not change when the table holding the stream is copied - as an app's `initState` may copy a table it filled
    /// in a local.
    const RingBox = struct {
        ring: mixer.StreamRing,
        /// Room for stereo; a mono ring uses the first half.
        samples: [ring_capacity_frames * 2]f32,
    };

    /// A ring given up, with what it waits for: its voice to end, on its mixer (`StreamTable.retireRing`).
    const RetiredRing = struct {
        ring_box: ?*RingBox = null,
        voice: mixer.Voice = .none,
        engine_mixer: ?*mixer.Mixer = null,
    };

    /// `entry`'s ring, made at the first call that needs it; null when the mixer could not give its memory.
    fn ringBoxOf(entry: *StreamEntry) ?*RingBox {
        if (entry.ring_box) |ring_box| {
            return ring_box;
        }
        const engine_mixer: *mixer.Mixer = entry.engine_mixer orelse return null;
        const allocator: Allocator = engine_mixer.allocator orelse return null;
        const ring_box: *RingBox = allocator.create(RingBox) catch return null;
        const channel_count: u8 = @intCast(entry.channels);
        const ring_samples: []f32 = ring_box.samples[0 .. ring_capacity_frames * channel_count];
        ring_box.ring = .initOver(ring_samples, channel_count, entry.sample_rate);
        entry.ring_box = ring_box;
        return ring_box;
    }

    /// Starts `entry`'s voice on its ring, at the stream's volume, pitch and pan - unless it plays already, or the
    /// stream is paused, or has no ring yet.
    fn startVoiceOf(entry: *StreamEntry) void {
        if (entry.voice != .none or entry.paused) {
            return;
        }
        const ring_box: *RingBox = entry.ring_box orelse return;
        const engine_mixer: *mixer.Mixer = entry.engine_mixer.?;
        const options: mixer.PlayOptions = .{ .volume = entry.volume, .pan = entry.pan, .pitch = entry.pitch };
        entry.voice = engine_mixer.play(.{ .stream = .{ .ring = &ring_box.ring } }, options);
    }

    /// Plays `entry` on: its voice resumed if it was paused, or started on its ring if it has none yet - a stream
    /// stopped, or never fed, starts with its next frames.
    fn continueStream(entry: *StreamEntry) void {
        if (entry.voice != .none) {
            entry.engine_mixer.?.resumeVoice(entry.voice);
            return;
        }
        startVoiceOf(entry);
    }

    /// A new AudioStream of `channels` channels - one or two - at `sample_rate`, played on the engine's mixer, which
    /// `device` names. `sample_size` is kept as raylib keeps it: frames are always pushed as f32 (`update`). An empty
    /// AudioStream (`.buffer = null`) when the device names no mixer, the format is not one a voice plays, or the table
    /// is full.
    pub fn load(
        state: *StreamTable,
        device: *const audio_device.AudioDeviceState,
        sample_rate: u32,
        sample_size: u32,
        channels: u32,
    ) AudioStream {
        const engine_mixer: *mixer.Mixer = device.engine_mixer orelse return .{};
        const is_mono_or_stereo: bool = channels == 1 or channels == 2;
        if (!is_mono_or_stereo or sample_rate == 0) {
            return .{};
        }
        state.collectRetired();
        const slot: u32 = state.allocate() orelse return .{};
        const entry: *StreamEntry = state.get(slot).?;
        entry.* = .{
            .in_use = true,
            .sample_rate = sample_rate,
            .sample_size = sample_size,
            .channels = channels,
            .engine_mixer = engine_mixer,
        };
        return .{
            .buffer = @ptrFromInt(@as(usize, slot)),
            .processor = null,
            .sampleRate = sample_rate,
            .sampleSize = sample_size,
            .channels = channels,
        };
    }

    /// Frees the stream: its ring retired - freed once its voice, stopped, has ended (`StreamTable.retireRing`) - and
    /// its slot released. Idempotent.
    pub fn unload(
        state: *StreamTable,
        stream: AudioStream,
    ) void {
        const slot: u32 = streamSlot(state, stream) orelse return;
        const e: *StreamEntry = state.get(slot) orelse return;
        state.retireRing(e);
        state.release(slot);
        state.collectRetired();
    }

    /// Whether `stream` names a stream that is loaded: its handle names a slot, and the slot holds a stream - not one
    /// `unload` has freed. (A handle carries no generation: one kept past its `unload`, its slot since given to another
    /// stream, names that one, as raylib's handles do.)
    pub fn isValid(
        state: *const StreamTable,
        stream: AudioStream,
    ) bool {
        const slot: u32 = streamSlot(state, stream) orelse return false;
        return state.entries[slot - 1].in_use;
    }

    /// Whether the stream wants more frames: while half its ring or more is free - so a game that tops it up each
    /// frame keeps between half the ring and all of it queued, 21 to 43 ms - and always before its ring is made.
    pub fn isProcessed(
        state: *const StreamTable,
        stream: AudioStream,
    ) bool {
        const slot: u32 = streamSlot(state, stream) orelse return false;
        const e: *const StreamEntry = state.getConst(slot) orelse return false;
        const ring_box: *RingBox = e.ring_box orelse return true;
        return ring_box.ring.freeFrames() >= ring_capacity_frames / 2;
    }

    /// Writes `frames` - interleaved f32, at the stream's rate and channels - into its ring, made at the first frames,
    /// and starts its voice if it has none: the stream sounds from its first frames. Frames past the ring's room are
    /// dropped: `isProcessed` says when there is room. A paused stream takes none: its voice is not reading, and frames
    /// written now would wait to play stale after the pause.
    pub fn update(
        state: *StreamTable,
        stream: AudioStream,
        frames: []const f32,
    ) void {
        const slot: u32 = streamSlot(state, stream) orelse return;
        const e: *StreamEntry = state.get(slot) orelse return;
        state.collectRetired();
        if (e.paused or frames.len == 0) {
            return;
        }
        const ring_box: *RingBox = ringBoxOf(e) orelse return;
        _ = ring_box.ring.write(frames);
        startVoiceOf(e);
    }

    /// Pauses the stream: its voice where it is, its ring kept; it takes no frames until it plays again.
    pub fn pause(
        state: *StreamTable,
        stream: AudioStream,
    ) void {
        const slot: u32 = streamSlot(state, stream) orelse return;
        const e: *StreamEntry = state.get(slot) orelse return;
        e.paused = true;
        if (e.voice != .none) {
            e.engine_mixer.?.pauseVoice(e.voice);
        }
    }

    /// Plays the stream on: a paused one resumed, a stopped or never fed one started with its next frames. A stream
    /// starts by itself at its first frames (`update`); this is raylib's call for it.
    pub fn play(
        state: *StreamTable,
        stream: AudioStream,
    ) void {
        const slot: u32 = streamSlot(state, stream) orelse return;
        const e: *StreamEntry = state.get(slot) orelse return;
        e.paused = false;
        continueStream(e);
    }

    /// Stops the stream, and its ring with its voice: frames queued before the stop are not heard after it. Its next
    /// frames start it again, on a new ring.
    pub fn stop(
        state: *StreamTable,
        stream: AudioStream,
    ) void {
        const slot: u32 = streamSlot(state, stream) orelse return;
        const e: *StreamEntry = state.get(slot) orelse return;
        state.retireRing(e);
        state.collectRetired();
        e.paused = false;
    }

    /// Resumes a paused stream, where it paused.
    pub fn resumeStream(
        state: *StreamTable,
        stream: AudioStream,
    ) void {
        const slot: u32 = streamSlot(state, stream) orelse return;
        const e: *StreamEntry = state.get(slot) orelse return;
        if (!e.paused) {
            return;
        }
        e.paused = false;
        continueStream(e);
    }

    /// Whether the stream plays: its voice started, not paused, and playing still.
    pub fn isPlaying(
        state: *const StreamTable,
        stream: AudioStream,
    ) bool {
        const slot: u32 = streamSlot(state, stream) orelse return false;
        const e: *const StreamEntry = state.getConst(slot) orelse return false;
        return e.voice != .none and !e.paused and e.engine_mixer.?.isPlaying(e.voice);
    }

    /// Sets the stream's volume, clamped to [0.0, 10.0]: its voice's at once, and the one its voice starts with.
    pub fn setVolume(
        state: *StreamTable,
        stream: AudioStream,
        volume: f32,
    ) void {
        const slot: u32 = streamSlot(state, stream) orelse return;
        const e: *StreamEntry = state.get(slot) orelse return;
        e.volume = clamp(volume, 0.0, 10.0);
        if (e.voice != .none) {
            e.engine_mixer.?.setVolume(e.voice, e.volume);
        }
    }

    /// Sets the stream's pitch, clamped to [0.0625, 16.0]: its voice's at once, and the one its voice starts with.
    pub fn setPitch(
        state: *StreamTable,
        stream: AudioStream,
        pitch: f32,
    ) void {
        const slot: u32 = streamSlot(state, stream) orelse return;
        const e: *StreamEntry = state.get(slot) orelse return;
        e.pitch = clamp(pitch, 0.0625, 16.0);
        if (e.voice != .none) {
            e.engine_mixer.?.setPitch(e.voice, e.pitch);
        }
    }

    /// Sets the stream's pan, clamped to [-1.0, 1.0]: its voice's at once, and the one its voice starts with.
    pub fn setPan(
        state: *StreamTable,
        stream: AudioStream,
        pan: f32,
    ) void {
        const slot: u32 = streamSlot(state, stream) orelse return;
        const e: *StreamEntry = state.get(slot) orelse return;
        e.pan = clamp(pan, -1.0, 1.0);
        if (e.voice != .none) {
            e.engine_mixer.?.setPan(e.voice, e.pan);
        }
    }

    fn streamSlot(
        state: *const StreamTable,
        stream: AudioStream,
    ) ?u32 {
        _ = state;
        const ptr: *types.rAudioBuffer = stream.buffer orelse return null;
        const as_int: usize = @intFromPtr(ptr);
        if (as_int == 0 or as_int > StreamTable.Capacity) {
            return null;
        }
        return @intCast(as_int);
    }

    // ---- Tests
    test "load: empty stream when device not ready" {
        var dev: audio_device.AudioDeviceState = .{};
        // intentionally NOT calling init - testing the not-ready early-out.
        var st: StreamTable = .{};
        const s: AudioStream = load(&st, &dev, 48000, 32, 2);
        try expect(!isValid(&st, s));
    }

    /// A mixer for the streams' tests, mixing by hand, its allocator the test's own, and a device naming it.
    const TestStreamOutput = struct {
        engine_mixer: mixer.Mixer = .{},
        device: audio_device.AudioDeviceState = .{},

        fn start(output: *TestStreamOutput) Allocator.Error!void {
            try mixer.allocateTestBlocks(&output.engine_mixer);
            output.engine_mixer.allocator = testing_allocator;
            output.device.engine_mixer = &output.engine_mixer;
        }

        fn finish(output: *TestStreamOutput) void {
            mixer.freeTestBlocks(&output.engine_mixer);
        }
    };

    test "a stream on the mixer plays its frames as written, and asks for more while half its ring is free" {
        var output: TestStreamOutput = .{};
        try output.start();
        defer output.finish();
        var table: StreamTable = .{};
        const stream: AudioStream = load(&table, &output.device, mixer.sample_rate, 32, 2);
        try expect(isValid(&table, stream));
        try expect(!isPlaying(&table, stream));
        try expect(isProcessed(&table, stream));
        // 1500 stereo frames, the left a ramp up and the right the same ramp down: the ring holds 2048, so after them
        // fewer than half are free, and the stream asks for no more.
        var frames: [1500 * 2]f32 = undefined;
        for (0..1500) |frame_index| {
            const ramp: f32 = float(frame_index) / 1500;
            frames[frame_index * 2] = ramp;
            frames[frame_index * 2 + 1] = -ramp;
        }
        update(&table, stream, &frames);
        try expect(isPlaying(&table, stream));
        try expect(!isProcessed(&table, stream));
        // A stereo stream at the centre plays at unity, each channel as written.
        var block: [256 * 2]f32 = undefined;
        output.engine_mixer.mixInto(&block);
        for (0..256) |frame_index| {
            try expectApproxEqAbs(frames[frame_index * 2], block[frame_index * 2], 1e-7);
            try expectApproxEqAbs(frames[frame_index * 2 + 1], block[frame_index * 2 + 1], 1e-7);
        }
        // 1500 less 256 read: 1244 queued, 804 free - still under half.
        try expect(!isProcessed(&table, stream));
        output.engine_mixer.mixInto(&block);
        try expect(isProcessed(&table, stream));
        // Unloaded, its ring waits while the voice fades out - `mixer.fade_out_frames`, 240, within the next block of
        // 256 - and is freed once the renderer has said the voice ended: nothing leaked.
        unload(&table, stream);
        try expect(!isValid(&table, stream));
        try expect(table.retired_rings[0].ring_box != null);
        output.engine_mixer.mixInto(&block);
        table.collectRetired();
        try expect(table.retired_rings[0].ring_box == null);
    }

    test "a stream on the mixer: paused, its frames wait; stopped, its ring is freed once its voice has ended" {
        var output: TestStreamOutput = .{};
        try output.start();
        defer output.finish();
        var table: StreamTable = .{};
        const stream: AudioStream = load(&table, &output.device, mixer.sample_rate, 32, 1);
        const frames: [64]f32 = @splat(0.25);
        update(&table, stream, &frames);
        pause(&table, stream);
        try expect(!isPlaying(&table, stream));
        // Paused, the frames stay in the ring: the mix reads none of them.
        var block: [32 * 2]f32 = undefined;
        output.engine_mixer.mixInto(&block);
        output.engine_mixer.mixInto(&block);
        const entry: *const StreamEntry = table.getConst(streamSlot(&table, stream).?).?;
        try expectEqual(@as(usize, ring_capacity_frames - 64), entry.ring_box.?.ring.freeFrames());
        // Resumed, it plays them on: a mono stream at the centre, at constant power.
        resumeStream(&table, stream);
        try expect(isPlaying(&table, stream));
        output.engine_mixer.mixInto(&block);
        try expectApproxEqAbs(@as(f32, 0.25 * 0.70710678), block[0], 1e-6);
        // Stopped: the ring is given up with its voice, and kept while the renderer fades the voice out - 240 frames,
        // more than a block of 32 - then freed by the next call that collects, here the unload; the test's allocator
        // finds nothing leaked.
        stop(&table, stream);
        try expect(!isPlaying(&table, stream));
        output.engine_mixer.mixInto(&block);
        const retired_while_fading: bool = table.retired_rings[0].ring_box != null;
        try expect(retired_while_fading);
        var long_block: [512 * 2]f32 = undefined;
        output.engine_mixer.mixInto(&long_block);
        output.engine_mixer.mixInto(&long_block);
        unload(&table, stream);
        for (table.retired_rings) |retired| {
            try expect(retired.ring_box == null);
        }
    }

    test "a stream's volume, pitch and pan are clamped, kept, and given to its voice" {
        var output: TestStreamOutput = .{};
        try output.start();
        defer output.finish();
        var table: StreamTable = .{};
        const stream: AudioStream = load(&table, &output.device, mixer.sample_rate, 32, 2);
        setVolume(&table, stream, 20);
        setPitch(&table, stream, 0.001);
        setPan(&table, stream, -3);
        const entry: *const StreamEntry = table.getConst(streamSlot(&table, stream).?).?;
        try expectEqual(@as(f32, 10), entry.volume);
        try expectEqual(@as(f32, 0.0625), entry.pitch);
        try expectEqual(@as(f32, -1), entry.pan);
        // An update with no frames starts nothing; one with frames starts the voice at those settings.
        update(&table, stream, &.{});
        try expect(!isPlaying(&table, stream));
        const frames: [8]f32 = @splat(0.5);
        update(&table, stream, &frames);
        try expect(isPlaying(&table, stream));
        unload(&table, stream);
        var block: [512 * 2]f32 = undefined;
        output.engine_mixer.mixInto(&block);
        table.collectRetired();
    }

    test "unload of an empty stream does nothing" {
        var table: StreamTable = .{};
        unload(&table, .{});
    }
};

pub const music = struct {
    /// Where a music's frames come from (`MusicEntry.source`): a Vorbis decoder over the file's bytes, decoding as it
    /// is read (`codecs.audio.vorbis.Decoder`), or a WAV's frames, read through in order. Nothing is decoded ahead: a
    /// song loads at once and is decoded half a ring at a time as it plays (`update`).
    const Source = union(enum) {
        none,
        vorbis: *codecs.audio.vorbis.Decoder,
        wav: WavSource,
    };

    /// A WAV's frames, stereo, at its own rate, and how far they have been read.
    const WavSource = struct {
        /// Interleaved stereo frames, the WAV's whole length, in the music's allocator.
        frames: []f32,
        /// The next frame to read.
        position: usize = 0,

        /// Copies the next frames into `out`, as many as it holds or are left: the frames copied.
        fn read(source: *WavSource, out: []f32) usize {
            const frames_left: usize = source.frames.len / 2 - source.position;
            const frame_count: usize = @min(frames_left, out.len / 2);
            const first_sample: usize = source.position * 2;
            @memcpy(out[0 .. frame_count * 2], source.frames[first_sample..][0 .. frame_count * 2]);
            source.position += frame_count;
            return frame_count;
        }
    };

    /// A music, as its table keeps it: its source and the file's bytes it reads, the stream it plays through, its
    /// format and length, how far it has played, and the settings its stream takes.
    const MusicEntry = struct {
        source: Source = .none,
        /// The allocator its source and bytes are in.
        gpa: ?Allocator = null,
        /// A Vorbis file's bytes, copied at load, for its decoder to read as it plays.
        bytes: []u8 = &.{},
        /// The stream it plays through, one of its table's own (`MusicTable.streams`).
        stream: AudioStream = .{},
        sample_rate: u32 = 0,
        channels: u32 = 0,
        /// Its length in frames: a Vorbis file's final granule position, a WAV's frame count.
        total_frames: u64 = 0,
        /// The frame playback began from: 0, or where a seek put it (`seek`).
        start_frame: u64 = 0,
        /// The frames written into the stream since playback began from `start_frame`.
        frames_written: u64 = 0,
        /// Whether it is playing - begun and not stopped or played out - and, playing, whether paused.
        is_playing: bool = false,
        is_paused: bool = false,
        /// Whether its source has given its last frame, the music not looping: the ring plays out, then it stops.
        is_source_done: bool = false,
        volume: f32 = 1.0,
        pitch: f32 = 1.0,
        pan: f32 = 0.0,
        looping: bool = true,
        in_use: bool = false,
    };

    /// How many frames a music decodes at a time: half a stream's ring - what a stream that asks for frames
    /// (`streams.isProcessed`) has room for.
    const half_ring_frames: usize = streams.ring_capacity_frames / 2;

    /// The music a program has loaded, and the streams they play through: the music functions take this table alone,
    /// and reach a music's stream through it, so a table copied with its streams keeps working.
    pub const MusicTable = struct {
        const Capacity = 16;
        entries: [Capacity]MusicEntry = @splat(.{}),
        /// The music's streams, one for each music (`MusicEntry.stream`).
        streams: streams.StreamTable = .{},
        /// Where half a ring's frames are decoded, stereo, before they are written into a stream.
        scratch: [half_ring_frames * 2]f32 = undefined,

        /// A free slot, marked in use: its number, from 1; null when the table is full.
        fn allocate(self: *MusicTable) ?u32 {
            for (&self.entries, 0..) |*e, i| {
                if (!e.in_use) {
                    e.* = .{ .in_use = true };
                    return @intCast(i + 1);
                }
            }
            return null;
        }

        /// The entry in `slot`, if it is in use.
        fn get(self: *MusicTable, slot: u32) ?*MusicEntry {
            if (slot == 0 or slot > Capacity) {
                return null;
            }
            const e: *MusicEntry = &self.entries[slot - 1];
            if (!e.in_use) {
                return null;
            }
            return e;
        }

        /// The entry in `slot`, if it is in use, to read.
        fn getConst(self: *const MusicTable, slot: u32) ?*const MusicEntry {
            if (slot == 0 or slot > Capacity) {
                return null;
            }
            const e: *const MusicEntry = &self.entries[slot - 1];
            if (!e.in_use) {
                return null;
            }
            return e;
        }

        /// Frees `slot` for another music.
        fn release(self: *MusicTable, slot: u32) void {
            if (slot == 0 or slot > Capacity) {
                return;
            }
            self.entries[slot - 1] = .{};
        }
    };

    /// Loads a music from a file's bytes - Ogg Vorbis or WAV, told apart by their first bytes (`Format.detect`) -
    /// to play through the engine's mixer, as raylib's `LoadMusicStreamFromMemory`. Nothing is decoded ahead: a
    /// Vorbis file's headers are read, its bytes copied for its decoder to read as it plays, and its length read
    /// from its last page's granule position (`ogg.sniff`); a WAV is converted to stereo frames whole. The music
    /// keeps its file's rate; its stream's voice converts it to the mixer's. An empty `Music` where the device names
    /// no mixer; `file_type` is kept on the signature as raylib's, the bytes telling the format.
    pub fn loadFromMemory(
        state: *MusicTable,
        device: *const audio_device.AudioDeviceState,
        waves_state: *waves.AllocTable,
        gpa: Allocator,
        file_type: []const u8,
        bytes: []const u8,
    ) !Music {
        _ = file_type;
        if (device.engine_mixer == null) {
            return .{};
        }
        const fmt: codecs.audio.Format = codecs.audio.Format.detect(bytes) orelse return error.UnknownAudioFormat;
        var source: Source = .none;
        var owned_bytes: []u8 = &.{};
        var sample_rate: u32 = 0;
        var channels: u32 = 0;
        var total_frames: u64 = 0;
        switch (fmt) {
            .wav => {
                const wave: Wave = try waves.loadFromMemory(waves_state, gpa, ".wav", bytes);
                defer waves.unload(waves_state, wave);
                const canonical: codecs.audio.CanonicalWave = codecs.audio.canonicalFromWave(wave);
                const frames: []f32 = try codecs.audio.wav.toFloat32Stereo(gpa, canonical);
                source = .{ .wav = .{ .frames = frames } };
                sample_rate = wave.sampleRate;
                channels = 2;
                total_frames = frames.len / 2;
            },
            .ogg => {
                owned_bytes = try gpa.dupe(u8, bytes);
                errdefer gpa.free(owned_bytes);
                const decoder: *codecs.audio.vorbis.Decoder = try gpa.create(codecs.audio.vorbis.Decoder);
                errdefer gpa.destroy(decoder);
                decoder.* = try codecs.audio.vorbis.Decoder.init(gpa, owned_bytes);
                source = .{ .vorbis = decoder };
                sample_rate = decoder.headers.identification.sample_rate;
                channels = decoder.headers.identification.channels;
                const metadata: ?codecs.audio.ogg.Metadata = codecs.audio.ogg.sniff(bytes);
                total_frames = if (metadata) |known| known.total_samples else 0;
            },
        }
        const stream: AudioStream = streams.load(&state.streams, device, sample_rate, 32, channels);
        const slot: ?u32 = if (streams.isValid(&state.streams, stream)) state.allocate() else null;
        if (slot == null) {
            if (streams.isValid(&state.streams, stream)) {
                streams.unload(&state.streams, stream);
            }
            freeSource(gpa, source, owned_bytes);
            return if (streams.isValid(&state.streams, stream)) error.MusicTableFull else error.UnsupportedChannelCount;
        }
        const e: *MusicEntry = state.get(slot.?).?;
        e.* = .{
            .in_use = true,
            .source = source,
            .gpa = gpa,
            .bytes = owned_bytes,
            .stream = stream,
            .sample_rate = sample_rate,
            .channels = channels,
            .total_frames = total_frames,
        };
        return Music{
            .stream = .{
                .buffer = @ptrFromInt(@as(usize, slot.?)),
                .processor = null,
                .sampleRate = sample_rate,
                .sampleSize = 32,
                .channels = channels,
            },
            .frameCount = @intCast(@min(total_frames, zm.maxInt(u32))),
            .looping = true,
            .ctxType = 0,
            .ctxData = null,
        };
    }

    /// Frees a music's source and its file's bytes.
    fn freeSource(gpa: Allocator, source: Source, bytes: []u8) void {
        switch (source) {
            .none => {},
            .vorbis => |decoder| {
                decoder.deinit();
                gpa.destroy(decoder);
            },
            .wav => |wav_source| gpa.free(wav_source.frames),
        }
        if (bytes.len > 0) {
            gpa.free(bytes);
        }
    }

    /// Reads the music's next frames from its source into `out`, interleaved, as many as it holds or the source has
    /// left: the frames read, 0 at the source's end - and at a Vorbis decoder's failure to allocate, which ends it.
    fn readSource(e: *MusicEntry, out: []f32) usize {
        return switch (e.source) {
            .none => 0,
            .vorbis => |decoder| decoder.readFrames(out) catch 0,
            .wav => |*wav_source| wav_source.read(out),
        };
    }

    /// Moves the music's source back to its first frame.
    fn rewindSource(e: *MusicEntry) void {
        switch (e.source) {
            .none => {},
            .vorbis => |decoder| decoder.rewind(),
            .wav => |*wav_source| wav_source.position = 0,
        }
    }

    /// Moves the music's source to `frame`: a WAV's straight there; a Vorbis decoder's by its pages
    /// (`Decoder.seekToFrame`), a few thousand frames decoded wherever it lands - exact to the frame. A decoder failing
    /// to allocate is left at its start.
    fn positionSource(e: *MusicEntry, frame: u64) void {
        rewindSource(e);
        switch (e.source) {
            .none => {},
            .wav => |*wav_source| wav_source.position = @intCast(@min(frame, wav_source.frames.len / 2)),
            .vorbis => |decoder| decoder.seekToFrame(frame) catch decoder.rewind(),
        }
    }

    /// Whether the music is loaded and ready to play: at once, a music loading whole when `loadFromMemory` returns.
    pub fn isReady(
        state: *MusicTable,
        track: Music,
    ) bool {
        const slot: u32 = musicSlot(state, track) orelse return false;
        const e: *const MusicEntry = state.getConst(slot) orelse return false;
        return e.source != .none;
    }

    /// Whether the Music slot is allocated and not yet unloaded.
    pub fn isValid(
        state: *const MusicTable,
        track: Music,
    ) bool {
        const slot: u32 = musicSlot(state, track) orelse return false;
        return state.getConst(slot) != null;
    }

    /// Frees the music: its stream - whose ring waits for its voice to end - its source and its file's bytes.
    pub fn unload(
        state: *MusicTable,
        track: Music,
    ) void {
        const slot: u32 = musicSlot(state, track) orelse return;
        const e: *MusicEntry = state.get(slot) orelse return;
        streams.unload(&state.streams, e.stream);
        freeSource(e.gpa.?, e.source, e.bytes);
        state.release(slot);
    }

    /// Starts the music from its beginning - or from where a `seek` last put it - and starts writing its frames into
    /// its stream; a music already playing starts over, its frames still queued dropped (raylib's parity: a music
    /// plays once at a time, unlike a sound). It goes on as long as `update` is called each frame.
    pub fn play(
        state: *MusicTable,
        track: Music,
    ) void {
        const slot: u32 = musicSlot(state, track) orelse return;
        const e: *MusicEntry = state.get(slot) orelse return;
        if (e.source == .none) {
            return;
        }
        if (e.is_playing) {
            streams.stop(&state.streams, e.stream);
        }
        positionSource(e, e.start_frame);
        e.frames_written = 0;
        e.is_playing = true;
        e.is_paused = false;
        e.is_source_done = false;
        streams.setVolume(&state.streams, e.stream, e.volume);
        streams.setPitch(&state.streams, e.stream, e.pitch);
        streams.setPan(&state.streams, e.stream, e.pan);
        streams.play(&state.streams, e.stream);
        update(state, track);
    }

    /// Stops the music: its stream stopped, its frames still queued dropped, and its position back at the
    /// beginning - the next `play` starts from there.
    pub fn stop(
        state: *MusicTable,
        track: Music,
    ) void {
        const slot: u32 = musicSlot(state, track) orelse return;
        const e: *MusicEntry = state.get(slot) orelse return;
        streams.stop(&state.streams, e.stream);
        rewindSource(e);
        e.is_playing = false;
        e.is_paused = false;
        e.is_source_done = false;
        e.start_frame = 0;
        e.frames_written = 0;
    }

    /// Moves the music to `position_seconds`, kept within its length. A music playing goes on from there, its frames
    /// still queued dropped, paused or not as it was; a stopped one starts from there at its next `play`.
    pub fn seek(
        state: *MusicTable,
        track: Music,
        position_seconds: f32,
    ) void {
        const slot: u32 = musicSlot(state, track) orelse return;
        const e: *MusicEntry = state.get(slot) orelse return;
        const wanted_frame: f64 = @max(0.0, @as(f64, position_seconds)) * float64(e.sample_rate);
        const last_frame: f64 = float64(e.total_frames);
        e.start_frame = @trunc(@min(wanted_frame, last_frame));
        if (!e.is_playing) {
            return;
        }
        const was_paused: bool = e.is_paused;
        streams.stop(&state.streams, e.stream);
        positionSource(e, e.start_frame);
        e.frames_written = 0;
        e.is_source_done = false;
        if (was_paused) {
            streams.pause(&state.streams, e.stream);
            return;
        }
        streams.play(&state.streams, e.stream);
        update(state, track);
    }

    /// Pauses the music where it is, its frames still queued kept. Resume with `resumeMusic`.
    pub fn pause(
        state: *MusicTable,
        track: Music,
    ) void {
        const slot: u32 = musicSlot(state, track) orelse return;
        const e: *MusicEntry = state.get(slot) orelse return;
        if (!e.is_playing) {
            return;
        }
        e.is_paused = true;
        streams.pause(&state.streams, e.stream);
    }

    /// Resumes a paused music. Named `resumeMusic` to dodge Zig's `resume` keyword.
    pub fn resumeMusic(
        state: *MusicTable,
        track: Music,
    ) void {
        const slot: u32 = musicSlot(state, track) orelse return;
        const e: *MusicEntry = state.get(slot) orelse return;
        if (!e.is_playing or !e.is_paused) {
            return;
        }
        e.is_paused = false;
        streams.resumeStream(&state.streams, e.stream);
        update(state, track);
    }

    /// Whether the music is playing: begun, not paused, not stopped, not played out.
    pub fn isPlaying(
        state: *const MusicTable,
        track: Music,
    ) bool {
        const slot: u32 = musicSlot(state, track) orelse return false;
        const e: *const MusicEntry = state.getConst(slot) orelse return false;
        return e.is_playing and !e.is_paused;
    }

    /// Keeps the music playing - called each frame, as raylib's `UpdateMusicStream` is. While its stream asks for
    /// frames (`streams.isProcessed`: half its ring free), half a ring is read from its source and written in. At
    /// the source's end a looping music starts its source over and reads on, so that the seam lies inside the ring,
    /// continuous; one not looping lets its ring play out, and stops when it has. A source that gives no frames even
    /// from its start - a file whose sound is all damaged, or whose last page claims a length its packets do not
    /// hold - ends as one not looping does, rather than starting over and over within the frame.
    pub fn update(
        state: *MusicTable,
        track: Music,
    ) void {
        const slot: u32 = musicSlot(state, track) orelse return;
        const e: *MusicEntry = state.get(slot) orelse return;
        if (!e.is_playing or e.is_paused) {
            return;
        }
        const channel_count: usize = e.channels;
        while (!e.is_source_done and streams.isProcessed(&state.streams, e.stream)) {
            const samples: []f32 = state.scratch[0 .. half_ring_frames * channel_count];
            var frames_filled: usize = 0;
            var is_just_rewound: bool = false;
            while (frames_filled < half_ring_frames) {
                const frames_read: usize = readSource(e, samples[frames_filled * channel_count ..]);
                if (frames_read > 0) {
                    frames_filled += frames_read;
                    is_just_rewound = false;
                    continue;
                }
                // The source's end: on from its start, if looping and it has frames at all - but not twice in a row,
                // a source giving nothing from its start being empty.
                if (e.looping and e.total_frames > 0 and !is_just_rewound) {
                    rewindSource(e);
                    is_just_rewound = true;
                    continue;
                }
                e.is_source_done = true;
                break;
            }
            if (frames_filled > 0) {
                streams.update(&state.streams, e.stream, samples[0 .. frames_filled * channel_count]);
                e.frames_written += frames_filled;
            }
        }
        if (e.is_source_done and queuedFrames(state, e) == 0) {
            streams.stop(&state.streams, e.stream);
            e.is_playing = false;
        }
    }

    /// How many of the music's frames wait in its stream's ring, written and not yet played.
    fn queuedFrames(state: *const MusicTable, e: *const MusicEntry) usize {
        const slot: u32 = streams.streamSlot(&state.streams, e.stream) orelse return 0;
        const stream_entry: *const streams.StreamEntry = state.streams.getConst(slot) orelse return 0;
        const ring_box: *streams.RingBox = stream_entry.ring_box orelse return 0;
        return streams.ring_capacity_frames - ring_box.ring.freeFrames();
    }

    /// How far the music has played, in seconds: the frames written since it began, less those still waiting in
    /// its ring, from where it began - round its length again while it loops.
    pub fn getTimePlayed(
        state: *const MusicTable,
        track: Music,
    ) f32 {
        const slot: u32 = musicSlot(state, track) orelse return 0;
        const e: *const MusicEntry = state.getConst(slot) orelse return 0;
        if (e.sample_rate == 0) {
            return 0;
        }
        const queued: u64 = queuedFrames(state, e);
        const frames_heard: u64 = e.frames_written - @min(queued, e.frames_written);
        var position: u64 = e.start_frame + frames_heard;
        if (e.total_frames > 0) {
            position %= e.total_frames;
        }
        return @floatCast(float64(position) / float64(e.sample_rate));
    }

    /// The music's length in seconds: its frames over its rate.
    pub fn getTimeLength(
        state: *const MusicTable,
        track: Music,
    ) f32 {
        const slot: u32 = musicSlot(state, track) orelse return 0;
        const e: *const MusicEntry = state.getConst(slot) orelse return 0;
        if (e.sample_rate == 0) {
            return 0;
        }
        return @floatCast(float64(e.total_frames) / float64(e.sample_rate));
    }

    /// Sets the music's volume, 0 to 1 and kept there, which its stream plays at.
    pub fn setVolume(
        state: *MusicTable,
        track: Music,
        volume: f32,
    ) void {
        const slot: u32 = musicSlot(state, track) orelse return;
        const e: *MusicEntry = state.get(slot) orelse return;
        e.volume = clamp(volume, 0.0, 1.0);
        streams.setVolume(&state.streams, e.stream, e.volume);
    }

    /// Sets the music's pitch, a rate of play - 1 as recorded - kept from going to 0 or below, which its stream plays
    /// at.
    pub fn setPitch(
        state: *MusicTable,
        track: Music,
        pitch: f32,
    ) void {
        const slot: u32 = musicSlot(state, track) orelse return;
        const e: *MusicEntry = state.get(slot) orelse return;
        e.pitch = @max(pitch, 0.01);
        streams.setPitch(&state.streams, e.stream, e.pitch);
    }

    /// Sets the music's pan, -1 left to 1 right and kept there, which its stream plays at.
    pub fn setPan(
        state: *MusicTable,
        track: Music,
        pan: f32,
    ) void {
        const slot: u32 = musicSlot(state, track) orelse return;
        const e: *MusicEntry = state.get(slot) orelse return;
        e.pan = clamp(pan, -1.0, 1.0);
        streams.setPan(&state.streams, e.stream, e.pan);
    }

    /// Sets whether the music starts over at its end (`update`).
    pub fn setLooping(
        state: *MusicTable,
        track: Music,
        looping: bool,
    ) void {
        const slot: u32 = musicSlot(state, track) orelse return;
        const e: *MusicEntry = state.get(slot) orelse return;
        e.looping = looping;
    }

    /// The table slot a `Music` names: its stream's buffer pointer carries the slot number, from 1.
    fn musicSlot(
        state: *const MusicTable,
        track: Music,
    ) ?u32 {
        _ = state;
        const ptr: *types.rAudioBuffer = track.stream.buffer orelse return null;
        const as_int: usize = @intFromPtr(ptr);
        if (as_int == 0 or as_int > MusicTable.Capacity) {
            return null;
        }
        return @intCast(as_int);
    }

    // ---- Tests

    /// Loads a test's music from `bytes` - a WAV or an Ogg file, told apart by their first bytes - onto the test
    /// mixer.
    fn loadTestMusic(
        table: *MusicTable,
        output: *streams.TestStreamOutput,
        wave_table: *waves.AllocTable,
        bytes: []const u8,
    ) !Music {
        return loadFromMemory(table, &output.device, wave_table, testing_allocator, "", bytes);
    }

    /// Unloads a test's music, then mixes a block, in which its voice fades out and ends, and frees its stream's
    /// ring and any rings retired before - a stopped stream's ring waits for its voice to end (`collectRetired`).
    fn finishMusic(
        table: *MusicTable,
        track: Music,
        output: *streams.TestStreamOutput,
    ) void {
        unload(table, track);
        var block: [256 * 2]f32 = undefined;
        output.engine_mixer.mixInto(&block);
        table.streams.collectRetired();
    }

    /// Mixes `block_count` blocks of the test mixer, calling `update` before each as a frame would: the largest
    /// sample mixed.
    fn playBlocks(
        table: *MusicTable,
        track: Music,
        output: *streams.TestStreamOutput,
        block_count: usize,
    ) f32 {
        var block: [256 * 2]f32 = undefined;
        var peak: f32 = 0;
        for (0..block_count) |_| {
            update(table, track);
            output.engine_mixer.mixInto(&block);
            for (block) |sample| {
                peak = @max(peak, @abs(sample));
            }
        }
        return peak;
    }

    test "a WAV loads at once, at its own rate, stereo, its length its frames" {
        var output: streams.TestStreamOutput = .{};
        try output.start();
        defer output.finish();
        var wave_table: waves.AllocTable = .{};
        var table: MusicTable = .{};
        const track: Music = try loadTestMusic(&table, &output, &wave_table, codecs.audio.wav.test_sine_wav);
        defer finishMusic(&table, track, &output);
        try expect(isValid(&table, track));
        try expect(isReady(&table, track));
        try expectEqual(@as(u32, 22050), track.stream.sampleRate);
        try expectEqual(@as(u32, 2), track.stream.channels);
        try expectApproxEqAbs(@as(f32, 0.5), getTimeLength(&table, track), 1e-6);
    }

    test "loadFromMemory: rejects unknown format" {
        var output: streams.TestStreamOutput = .{};
        try output.start();
        defer output.finish();
        var wave_table: waves.AllocTable = .{};
        var table: MusicTable = .{};
        try expectError(
            error.UnknownAudioFormat,
            loadFromMemory(&table, &output.device, &wave_table, testing_allocator, ".mp3", "not audio at all"),
        );
    }

    test "a WAV not looping plays through its stream onto the mixer, then plays out and stops" {
        var output: streams.TestStreamOutput = .{};
        try output.start();
        defer output.finish();
        var wave_table: waves.AllocTable = .{};
        var table: MusicTable = .{};
        const track: Music = try loadTestMusic(&table, &output, &wave_table, codecs.audio.wav.test_sine_wav);
        defer finishMusic(&table, track, &output);
        setLooping(&table, track, false);
        try expect(!isPlaying(&table, track));
        play(&table, track);
        try expect(isPlaying(&table, track));
        // Half a second at 22 050, played at 48 000: 24 000 of the mixer's frames, 94 blocks of 256 - and the ring's
        // last frames after them. Well before then the sine sounds; by 140 blocks the music has stopped.
        const peak: f32 = playBlocks(&table, track, &output, 60);
        try expect(peak > 0.1);
        try expect(isPlaying(&table, track));
        _ = playBlocks(&table, track, &output, 80);
        try expect(!isPlaying(&table, track));
    }

    test "a WAV looping plays on past its end, its frames written without a break" {
        var output: streams.TestStreamOutput = .{};
        try output.start();
        defer output.finish();
        var wave_table: waves.AllocTable = .{};
        var table: MusicTable = .{};
        const track: Music = try loadTestMusic(&table, &output, &wave_table, codecs.audio.wav.test_sine_wav);
        defer finishMusic(&table, track, &output);
        setLooping(&table, track, true);
        play(&table, track);
        // A second and a half of the mixer's frames: three times the WAV's length, its source started over twice.
        _ = playBlocks(&table, track, &output, 282);
        try expect(isPlaying(&table, track));
        const e: *const MusicEntry = table.getConst(musicSlot(&table, track).?).?;
        try expect(e.frames_written > 3 * e.total_frames);
        // Time played wraps round the length while looping.
        try expect(getTimePlayed(&table, track) < 0.5);
    }

    test "time played: the frames written, less those waiting in the ring; stop goes back to the start" {
        var output: streams.TestStreamOutput = .{};
        try output.start();
        defer output.finish();
        var wave_table: waves.AllocTable = .{};
        var table: MusicTable = .{};
        const track: Music = try loadTestMusic(&table, &output, &wave_table, codecs.audio.wav.test_sine_wav);
        defer finishMusic(&table, track, &output);
        setLooping(&table, track, false);
        play(&table, track);
        try expectApproxEqAbs(@as(f32, 0), getTimePlayed(&table, track), 1e-6);
        // 20 blocks of the mixer's 256 at 48 000 are 5120 frames, 2352 of the music's at 22 050: about 0.107 s.
        _ = playBlocks(&table, track, &output, 20);
        const played: f32 = getTimePlayed(&table, track);
        try expect(played > 0.09 and played < 0.12);
        stop(&table, track);
        try expect(!isPlaying(&table, track));
        try expectApproxEqAbs(@as(f32, 0), getTimePlayed(&table, track), 1e-6);
    }

    test "seek moves a music playing, paused or not; pause holds it; resume goes on" {
        var output: streams.TestStreamOutput = .{};
        try output.start();
        defer output.finish();
        var wave_table: waves.AllocTable = .{};
        var table: MusicTable = .{};
        const track: Music = try loadTestMusic(&table, &output, &wave_table, codecs.audio.wav.test_sine_wav);
        defer finishMusic(&table, track, &output);
        play(&table, track);
        seek(&table, track, 0.25);
        try expectApproxEqAbs(@as(f32, 0.25), getTimePlayed(&table, track), 1e-3);
        pause(&table, track);
        try expect(!isPlaying(&table, track));
        const paused_at: f32 = getTimePlayed(&table, track);
        _ = playBlocks(&table, track, &output, 10);
        try expectApproxEqAbs(paused_at, getTimePlayed(&table, track), 1e-6);
        resumeMusic(&table, track);
        try expect(isPlaying(&table, track));
        _ = playBlocks(&table, track, &output, 10);
        try expect(getTimePlayed(&table, track) > paused_at);
        // Sought past the end: kept to the length.
        seek(&table, track, 100);
        const e: *const MusicEntry = table.getConst(musicSlot(&table, track).?).?;
        try expectEqual(e.total_frames, e.start_frame);
    }

    test "the Ogg sample loads at once, its length its final granule, and sounds through the mixer" {
        var output: streams.TestStreamOutput = .{};
        try output.start();
        defer output.finish();
        var wave_table: waves.AllocTable = .{};
        var table: MusicTable = .{};
        const track: Music = try loadTestMusic(&table, &output, &wave_table, codecs.audio.ogg.sample_ogg);
        defer finishMusic(&table, track, &output);
        try expect(isReady(&table, track));
        try expectEqual(@as(u32, 44100), track.stream.sampleRate);
        try expectEqual(@as(u32, 4_236_528), track.frameCount);
        try expectApproxEqAbs(@as(f32, 96.066), getTimeLength(&table, track), 1e-3);
        play(&table, track);
        const peak: f32 = playBlocks(&table, track, &output, 200);
        try expect(peak > 0.01);
        try expect(isPlaying(&table, track));
        try expect(getTimePlayed(&table, track) > 0.9);
    }

    test "a looping music whose source gives no frames ends, rather than starting over and over" {
        var output: streams.TestStreamOutput = .{};
        try output.start();
        defer output.finish();
        var wave_table: waves.AllocTable = .{};
        var table: MusicTable = .{};
        // The sample cut at its first page of sound: three good headers, and no sound.
        var probe: codecs.audio.vorbis.Decoder = try .init(testing_allocator, codecs.audio.ogg.sample_ogg);
        const first_sound_page: usize = probe.first_sound_page_offset;
        probe.deinit();
        const headers_only: []const u8 = codecs.audio.ogg.sample_ogg[0..first_sound_page];
        const track: Music = try loadTestMusic(&table, &output, &wave_table, headers_only);
        defer finishMusic(&table, track, &output);
        // A length claimed, as a damaged file's last page may claim one: looping, its source would start over for
        // ever within `play`'s first update.
        const e: *MusicEntry = table.get(musicSlot(&table, track).?).?;
        e.total_frames = 44_100;
        play(&table, track);
        _ = playBlocks(&table, track, &output, 4);
        try expect(!isPlaying(&table, track));
    }

    test "setVolume, setPitch, setPan: kept within their ranges" {
        var output: streams.TestStreamOutput = .{};
        try output.start();
        defer output.finish();
        var wave_table: waves.AllocTable = .{};
        var table: MusicTable = .{};
        const track: Music = try loadTestMusic(&table, &output, &wave_table, codecs.audio.wav.test_sine_wav);
        defer finishMusic(&table, track, &output);
        setVolume(&table, track, 3);
        setPitch(&table, track, -1);
        setPan(&table, track, -9);
        const e: *const MusicEntry = table.getConst(musicSlot(&table, track).?).?;
        try expectEqual(@as(f32, 1), e.volume);
        try expectEqual(@as(f32, 0.01), e.pitch);
        try expectEqual(@as(f32, -1), e.pan);
    }

    test "an empty Music: not valid, nothing to unload, nothing to play" {
        var table: MusicTable = .{};
        const empty: Music = .{};
        try expect(!isValid(&table, empty));
        unload(&table, empty);
        play(&table, empty);
        try expect(!isPlaying(&table, empty));
    }
};

/// Spectrum analysis of everything mixed: what Web Audio's `AnalyserNode` gives with `getByteFrequencyData` at its
/// defaults, computed from the mixer's own sound. The renderer keeps the last frames it mixed, each the mean of its
/// channels (`Renderer.analysis_ring`); a read takes the last `fft_size` of them and turns them into one byte a bin:
///
///     window      each frame times the Blackman window, 0.42 - 0.5 cos(2 pi n / N) + 0.08 cos(4 pi n / N), which
///                 falls to zero at both ends, so that the frames' cut edges do not smear every frequency into
///                 every bin
///     transform   the real transform of the N windowed frames (`zn.rfft`); bin k is the frequency k x rate / N,
///                 N / 2 bins below half the rate
///     magnitude   |X[k]| / N
///     smoothing   each bin's magnitude kept from read to read: 0.8 of the last read's and 0.2 of this one's, so the
///                 bars fall back over some tenths of a second instead of flickering with every frame
///     decibels    20 log10 of the smoothed magnitude; -100 dB to -30 dB onto 0 to 255, floored, and held within
///
/// It is a tap, not an insert: the analysis reads a copy of the sound, so attaching one cannot change what is heard.
/// Natively and headless the main side reads the renderer's frames straight from it. On a page the renderer runs in
/// the audio worklet, in the other memory: each read asks it for its last frames (`ForwardingOutput.ask_analysis`)
/// and analyses the ones its last answer brought - a frame behind, which a picture of the sound does not show.
pub const analyser = struct {
    const Mixer = mixer.Mixer;
    const analysis_ring_frames: usize = mixer.analysis_ring_frames;

    /// Web Audio's defaults: the smoothing, and the decibels mapped onto the bytes' range.
    const smoothing: f32 = 0.8;
    const quietest_decibels: f32 = -100;
    const loudest_decibels: f32 = -30;

    /// An analyser attached to the mixer (`attach`): which of the mixer's analyser slots is its - null for none, an
    /// analyser never attached or found no free slot - and how many bins a read gives.
    pub const Analyser = struct {
        slot_index: ?u32 = null,
        bins: u32 = 0,
    };

    /// Attaches an analyser reading the last `fft_size` frames mixed, `fft_size / 2` bins: a power of two from 32 to
    /// 2048, the frames the renderer keeps - a larger size, which Web Audio allows up to 32 768, gives 2048. An empty
    /// analyser, which reads nothing, for a size that is no power of two or under 32, for a device with no mixer, and
    /// when the mixer's analysers are all in use.
    pub fn attach(device: *const audio_device.AudioDeviceState, fft_size: u32) Analyser {
        const is_power_of_two: bool = fft_size >= 32 and (fft_size & (fft_size - 1)) == 0;
        if (!is_power_of_two) {
            return .{};
        }
        const engine_mixer: *Mixer = device.engine_mixer orelse return .{};
        const size: u32 = @min(fft_size, @as(u32, analysis_ring_frames));
        for (&engine_mixer.analysers, 0..) |*analyser_slot, index| {
            if (!analyser_slot.is_in_use) {
                analyser_slot.* = .{ .is_in_use = true, .fft_size = size };
                return .{ .slot_index = @intCast(index), .bins = size / 2 };
            }
        }
        return .{};
    }

    /// Fills `out` with the spectrum, a byte a bin, and returns how many bins it wrote: as many as the analyser has
    /// or `out` holds, 0 for an empty analyser.
    pub fn read(
        device: *const audio_device.AudioDeviceState,
        a: Analyser,
        out: []u8,
    ) u32 {
        const slot_index: u32 = a.slot_index orelse return 0;
        const engine_mixer: *Mixer = device.engine_mixer orelse return 0;
        const analyser_slot: *mixer.AnalyserSlot = &engine_mixer.analysers[slot_index];
        if (!analyser_slot.is_in_use) {
            return 0;
        }
        const frame_count: usize = analyser_slot.fft_size;
        const frames: []f32 = engine_mixer.analysis_frames[0..frame_count];
        if (engine_mixer.forwarding) |forwarding| {
            // The renderer in the other memory: the frames its last answer brought, and the next asked for; silence
            // before the first answer.
            const frames_taken: usize = if (forwarding.take_analysis_frames) |take| take(frames) else 0;
            if (frames_taken < frame_count) {
                @memset(frames, 0);
            }
            if (forwarding.ask_analysis) |ask| {
                ask();
            }
        } else {
            engine_mixer.renderer.copyAnalysisFrames(frames);
        }
        const bin_count: usize = @min(frame_count / 2, out.len);
        analyseFrames(
            frames,
            analyser_slot.smoothed_magnitudes[0 .. frame_count / 2],
            out[0..bin_count],
            engine_mixer.analysis_spectrum[0 .. frame_count / 2 + 1],
            engine_mixer.analysis_scratch[0 .. frame_count / 2],
        );
        return @intCast(bin_count);
    }

    /// Detaches the analyser: its slot free for another.
    pub fn detach(device: *const audio_device.AudioDeviceState, a: Analyser) void {
        const slot_index: u32 = a.slot_index orelse return;
        const engine_mixer: *Mixer = device.engine_mixer orelse return;
        engine_mixer.analysers[slot_index] = .{};
    }

    /// The analysis of `frames`, the last N mixed, oldest first, into a byte a bin (the steps above): `frames` is
    /// windowed in place, `smoothed_magnitudes` - N / 2 of them - carries each bin's magnitude from the last read and
    /// takes this one's, and the first `out.len` bins are written. `spectrum` holds N / 2 + 1 values and `scratch`
    /// N / 2, the transform's room.
    fn analyseFrames(
        frames: []f32,
        smoothed_magnitudes: []f32,
        out: []u8,
        spectrum: []zn.ComplexNumber(f32),
        scratch: []zn.ComplexNumber(f32),
    ) void {
        const frame_count: usize = frames.len;
        const turn_per_frame: f32 = 2 * pi / float(frame_count);
        for (frames, 0..) |*frame, index| {
            const angle: f32 = turn_per_frame * float(index);
            const window: f32 = 0.42 - 0.5 * @cos(angle) + 0.08 * @cos(2 * angle);
            frame.* *= window;
        }
        // The sizes hold by construction: a power of two of frames, half as many values and scratch, and one more.
        zn.rfft(f32, spectrum, frames, scratch) catch |transform_error| {
            assertUnreachable(@src(), "sound: the analysis transform refused {d} frames: {s}", .{
                frame_count,
                @errorName(transform_error),
            });
        };
        const bytes_per_decibel: f32 = 255 / (loudest_decibels - quietest_decibels);
        for (smoothed_magnitudes, 0..) |*smoothed, bin| {
            const value: zn.ComplexNumber(f32) = spectrum[bin];
            const magnitude: f32 = @sqrt(value.re * value.re + value.im * value.im) / float(frame_count);
            smoothed.* = smoothing * smoothed.* + (1 - smoothing) * magnitude;
            if (bin >= out.len) {
                continue;
            }
            const decibels: f32 = 20 * @log10(smoothed.*);
            const scaled: f32 = bytes_per_decibel * (decibels - quietest_decibels);
            // A silent bin's decibels are minus infinity; anything not above 0 is 0.
            out[bin] = if (scaled > 0) @floor(@min(scaled, 255)) else 0;
        }
    }

    // ---- Tests

    test "a 440 Hz sine peaks in 440 Hz's bins, and every byte is the analysis summed out in full" {
        var output: streams.TestStreamOutput = .{};
        try output.start();
        defer output.finish();
        var wave_table: waves.AllocTable = .{};
        var table: music.MusicTable = .{};
        const sine_wav: []const u8 = codecs.audio.wav.test_sine_wav;
        const track: Music = try music.loadTestMusic(&table, &output, &wave_table, sine_wav);
        defer music.finishMusic(&table, track, &output);
        music.play(&table, track);
        _ = music.playBlocks(&table, track, &output, 16);
        const sine_analyser: Analyser = attach(&output.device, 2048);
        defer detach(&output.device, sine_analyser);
        try expectEqual(@as(u32, 1024), sine_analyser.bins);
        // The frames the analyser reads, for the sums below.
        var frames: [2048]f32 = undefined;
        output.engine_mixer.renderer.copyAnalysisFrames(&frames);
        var bytes: [1024]u8 = undefined;
        try expectEqual(@as(u32, 1024), read(&output.device, sine_analyser, &bytes));
        // 440 Hz lies between bins 18 and 19, 23.4 Hz apart at 48 000 Hz.
        var peak_bin: usize = 0;
        for (bytes, 0..) |byte, bin| {
            if (byte > bytes[peak_bin]) {
                peak_bin = bin;
            }
        }
        try expect(peak_bin == 18 or peak_bin == 19);
        try expect(bytes[peak_bin] > 200);
        // The same steps, the transform a plain sum over the frames, in f64: the first read's smoothing is 0.2 of
        // the magnitude, the bins having started at 0.
        const frame_count: f64 = 2048;
        for (bytes, 0..) |byte, bin| {
            var real_sum: f64 = 0;
            var imaginary_sum: f64 = 0;
            for (frames, 0..) |frame, index| {
                const window_angle: f64 = 2 * pi * float64(index) / frame_count;
                const window: f64 = 0.42 - 0.5 * @cos(window_angle) + 0.08 * @cos(2 * window_angle);
                const angle: f64 = -2 * pi * float64(bin) * float64(index) / frame_count;
                real_sum += frame * window * @cos(angle);
                imaginary_sum += frame * window * @sin(angle);
            }
            const magnitude: f64 = @sqrt(real_sum * real_sum + imaginary_sum * imaginary_sum) / frame_count;
            const smoothed: f64 = (1 - smoothing) * magnitude;
            const decibels: f64 = 20 * @log10(smoothed);
            const scaled: f64 = 255 / (loudest_decibels - quietest_decibels) * (decibels - quietest_decibels);
            const expected: f64 = if (scaled > 0) @min(@floor(scaled), 255) else 0;
            try expectApproxEqAbs(expected, float64(byte), 1);
        }
    }
};

pub const sounds = struct {
    /// A sound's state, kept in a table beside its `Sound`: raylib's `Sound` is an extern struct the engine cannot
    /// grow, so its `stream.buffer` holds the entry's place in the table, from 1 (null for no sound).
    const SoundEntry = struct {
        /// The sound's samples as the mixer reads them (`waves.mixerSamplesOf`): `channels` a frame, at `sample_rate`.
        /// Shared by its aliases.
        samples: []const f32 = &.{},
        channels: u8 = 0,
        sample_rate: u32 = 0,
        /// The allocator that made `samples`, to free them at `unload`; null for an alias, which shares its original's.
        samples_allocator: ?Allocator = null,
        /// The mixer the sound plays on - the audio device's, given at load - and the voice of its most recent `play`.
        /// Playing a sound again while it plays starts a second voice beside the first; `stop`, `pause`,
        /// `resumeSound`, `isPlaying` and the setters act on the most recent.
        engine_mixer: ?*mixer.Mixer = null,
        voice: mixer.Voice = .none,
        /// Kept across plays: each `play` starts at them.
        volume: f32 = 1.0,
        pitch: f32 = 1.0,
        pan: f32 = 0.0,
        /// Whether the sound loops (`setLooping`): from its end back to its start, until stopped.
        is_looping: bool = false,
        in_use: bool = false,

        /// The sound as a source of the mixer's.
        fn source(entry: *const SoundEntry) mixer.Source {
            return .{ .samples = .{
                .samples = entry.samples,
                .channels = entry.channels,
                .sample_rate = entry.sample_rate,
                .is_looping = entry.is_looping,
            } };
        }
    };

    pub const SoundTable = struct {
        const Capacity = 128;
        entries: [Capacity]SoundEntry = @splat(.{}),

        fn allocate(self: *SoundTable) ?u32 {
            for (&self.entries, 0..) |*e, i| {
                if (!e.in_use) {
                    e.* = .{ .in_use = true };
                    return @intCast(i + 1);
                }
            }
            return null;
        }

        fn get(self: *SoundTable, slot: u32) ?*SoundEntry {
            if (slot == 0 or slot > Capacity) {
                return null;
            }
            const e: *SoundEntry = &self.entries[slot - 1];
            if (!e.in_use) {
                return null;
            }
            return e;
        }

        fn getConst(self: *const SoundTable, slot: u32) ?*const SoundEntry {
            if (slot == 0 or slot > Capacity) {
                return null;
            }
            const e: *const SoundEntry = &self.entries[slot - 1];
            if (!e.in_use) {
                return null;
            }
            return e;
        }

        fn release(self: *SoundTable, slot: u32) void {
            if (slot == 0 or slot > Capacity) {
                return;
            }
            self.entries[slot - 1] = .{};
        }
    };

    /// The table's place of `sound`, from 1; null for no sound.
    fn soundSlot(
        state: *const SoundTable,
        sound: Sound,
    ) ?u32 {
        _ = state;
        const ptr: *types.rAudioBuffer = sound.stream.buffer orelse return null;
        const as_int: usize = @intFromPtr(ptr);
        if (as_int == 0 or as_int > SoundTable.Capacity) {
            return null;
        }
        return @intCast(as_int);
    }

    /// The entry of `sound`, or null for no sound or one unloaded.
    fn entryOf(state: *SoundTable, sound: Sound) ?*SoundEntry {
        const slot: u32 = soundSlot(state, sound) orelse return null;
        return state.get(slot);
    }

    fn constEntryOf(state: *const SoundTable, sound: Sound) ?*const SoundEntry {
        const slot: u32 = soundSlot(state, sound) orelse return null;
        return state.getConst(slot);
    }

    // ---- Loading

    /// A sound of `wave`'s samples, kept as the mixer reads them - at the wave's own rate, which the mixer steps
    /// through at its own (no resampling at load), and with one channel for a mono wave, two for a wider one
    /// (`waves.mixerSamplesOf`). It plays on the device's mixer. An empty wave gives an empty `Sound`.
    pub fn loadFromWave(
        state: *SoundTable,
        device: *const audio_device.AudioDeviceState,
        gpa: Allocator,
        wave: Wave,
    ) !Sound {
        if (!waves.isValid(wave)) {
            return .{};
        }
        const samples: []f32 = try waves.mixerSamplesOf(gpa, wave);
        errdefer gpa.free(samples);
        const slot: u32 = state.allocate() orelse return error.SoundTableFull;
        const entry: *SoundEntry = state.get(slot).?;
        entry.samples = samples;
        entry.channels = waves.mixerChannelsOf(wave);
        entry.sample_rate = wave.sampleRate;
        entry.samples_allocator = gpa;
        entry.engine_mixer = device.engine_mixer;
        return .{
            .stream = .{
                .buffer = @ptrFromInt(@as(usize, slot)),
                .sampleRate = wave.sampleRate,
                .sampleSize = 32,
                .channels = entry.channels,
            },
            .frameCount = wave.frameCount,
        };
    }

    /// A sound from a file's bytes in memory: WAV, decoded at once. An OGG file is refused (`error.OggNeedsDecoder`) -
    /// Vorbis plays as music, decoded as it plays; any other format is unknown (`error.UnknownAudioFormat`).
    pub fn loadFromMemory(
        state: *SoundTable,
        device: *const audio_device.AudioDeviceState,
        waves_state: *waves.AllocTable,
        gpa: Allocator,
        file_type: []const u8,
        bytes: []const u8,
    ) !Sound {
        _ = file_type;
        const format: codecs.audio.Format = codecs.audio.Format.detect(bytes) orelse return error.UnknownAudioFormat;
        switch (format) {
            .wav => {
                const wave: Wave = try waves.loadFromMemory(waves_state, gpa, ".wav", bytes);
                defer waves.unload(waves_state, wave);
                return try loadFromWave(state, device, gpa, wave);
            },
            .ogg => return error.OggNeedsDecoder,
        }
    }

    /// A second sound sharing `source`'s samples, with playback parameters of its own - for playing one sound at
    /// several places or pitches. Unloading the original stops the alias's voices and empties it (`unload`).
    pub fn loadAlias(
        state: *SoundTable,
        source: Sound,
    ) Sound {
        const original: *SoundEntry = entryOf(state, source) orelse return .{};
        const original_entry: SoundEntry = original.*;
        const slot: u32 = state.allocate() orelse return .{};
        const alias: *SoundEntry = state.get(slot).?;
        alias.samples = original_entry.samples;
        alias.channels = original_entry.channels;
        alias.sample_rate = original_entry.sample_rate;
        alias.engine_mixer = original_entry.engine_mixer;
        var alias_sound: Sound = source;
        alias_sound.stream.buffer = @ptrFromInt(@as(usize, slot));
        return alias_sound;
    }

    /// Whether `sound` has samples to play.
    pub fn isReady(
        state: *SoundTable,
        sound: Sound,
    ) bool {
        const entry: *SoundEntry = entryOf(state, sound) orelse return false;
        return entry.samples.len > 0;
    }

    pub fn isValid(
        state: *const SoundTable,
        sound: Sound,
    ) bool {
        const entry: *const SoundEntry = constEntryOf(state, sound) orelse return false;
        return entry.samples.len > 0;
    }

    /// Frees `sound`. An original's samples are freed once nothing reads them (`mixer.Mixer.releaseSamples`): every
    /// voice reading them, its aliases' included, copies what it still needs and fades out over the copy; and its
    /// aliases are emptied, so that playing one later plays nothing rather than freed memory. An
    /// alias only stops its most recent voice and frees its entry. Unloading no sound, or one unloaded, does nothing.
    pub fn unload(
        state: *SoundTable,
        sound: Sound,
    ) void {
        const slot: u32 = soundSlot(state, sound) orelse return;
        const entry: *SoundEntry = state.get(slot) orelse return;
        if (entry.samples_allocator) |allocator| {
            for (&state.entries) |*other_entry| {
                const is_alias: bool = other_entry.in_use and other_entry.samples_allocator == null and
                    other_entry.samples.ptr == entry.samples.ptr;
                if (is_alias) {
                    other_entry.samples = &.{};
                    other_entry.voice = .none;
                }
            }
            // The mixer frees the samples once nothing reads them; with no mixer, nothing ever did.
            if (entry.engine_mixer) |engine_mixer| {
                engine_mixer.releaseSamples(allocator, entry.samples);
            } else {
                allocator.free(entry.samples);
            }
        } else if (entry.engine_mixer) |engine_mixer| {
            engine_mixer.stopVoice(entry.voice);
        }
        state.release(slot);
    }

    // ---- Playback

    /// Starts `sound` playing at its volume, pitch and pan, on a voice of its own - beside any earlier play still
    /// sounding. Does nothing for no sound, an emptied alias, or a sound with no mixer.
    pub fn play(
        state: *SoundTable,
        sound: Sound,
    ) void {
        const entry: *SoundEntry = entryOf(state, sound) orelse return;
        const engine_mixer: *mixer.Mixer = entry.engine_mixer orelse return;
        if (entry.samples.len == 0) {
            return;
        }
        entry.voice = engine_mixer.play(entry.source(), .{
            .volume = entry.volume,
            .pan = entry.pan,
            .pitch = entry.pitch,
        });
    }

    /// Stops the sound's most recent voice.
    pub fn stop(
        state: *SoundTable,
        sound: Sound,
    ) void {
        const entry: *SoundEntry = entryOf(state, sound) orelse return;
        const engine_mixer: *mixer.Mixer = entry.engine_mixer orelse return;
        engine_mixer.stopVoice(entry.voice);
    }

    /// Pauses the sound's most recent voice where it is.
    pub fn pause(
        state: *SoundTable,
        sound: Sound,
    ) void {
        const entry: *SoundEntry = entryOf(state, sound) orelse return;
        const engine_mixer: *mixer.Mixer = entry.engine_mixer orelse return;
        engine_mixer.pauseVoice(entry.voice);
    }

    /// Resumes the sound's most recent voice where it paused.
    pub fn resumeSound(
        state: *SoundTable,
        sound: Sound,
    ) void {
        const entry: *SoundEntry = entryOf(state, sound) orelse return;
        const engine_mixer: *mixer.Mixer = entry.engine_mixer orelse return;
        engine_mixer.resumeVoice(entry.voice);
    }

    /// Whether the sound's most recent voice plays: started, not stopped, not paused, not finished.
    pub fn isPlaying(
        state: *const SoundTable,
        sound: Sound,
    ) bool {
        const entry: *const SoundEntry = constEntryOf(state, sound) orelse return false;
        const engine_mixer: *mixer.Mixer = entry.engine_mixer orelse return false;
        return engine_mixer.isPlaying(entry.voice) and !engine_mixer.isPaused(entry.voice);
    }

    /// The sound's volume, from 0 to 10, for its later plays and its most recent voice.
    pub fn setVolume(
        state: *SoundTable,
        sound: Sound,
        volume: f32,
    ) void {
        const entry: *SoundEntry = entryOf(state, sound) orelse return;
        entry.volume = clamp(volume, 0.0, 10.0);
        if (entry.engine_mixer) |engine_mixer| {
            engine_mixer.setVolume(entry.voice, entry.volume);
        }
    }

    /// The sound's pitch, from 1/16 to 16, for its later plays and its most recent voice.
    pub fn setPitch(
        state: *SoundTable,
        sound: Sound,
        pitch: f32,
    ) void {
        const entry: *SoundEntry = entryOf(state, sound) orelse return;
        entry.pitch = clamp(pitch, 0.0625, 16.0);
        if (entry.engine_mixer) |engine_mixer| {
            engine_mixer.setPitch(entry.voice, entry.pitch);
        }
    }

    /// Whether the sound loops: a zimr addition to raylib's sounds, which play once. A looping sound plays from its end
    /// back to its start without a gap until stopped - a rhythm baked into one sound keeps its time exactly, as
    /// replaying it from a frame could not. For its later plays and its most recent voice.
    pub fn setLooping(
        state: *SoundTable,
        sound: Sound,
        is_looping: bool,
    ) void {
        const entry: *SoundEntry = entryOf(state, sound) orelse return;
        entry.is_looping = is_looping;
        if (entry.engine_mixer) |engine_mixer| {
            engine_mixer.setLooping(entry.voice, is_looping);
        }
    }

    /// The sound's pan, from -1 (left) to 1 (right), for its later plays and its most recent voice.
    pub fn setPan(
        state: *SoundTable,
        sound: Sound,
        pan: f32,
    ) void {
        const entry: *SoundEntry = entryOf(state, sound) orelse return;
        entry.pan = clamp(pan, -1.0, 1.0);
        if (entry.engine_mixer) |engine_mixer| {
            engine_mixer.setPan(entry.voice, entry.pan);
        }
    }

    // ---- Tests

    /// The engine's test WAV: a short sine.
    const test_wav: []const u8 = codecs.audio.wav.test_sine_wav;

    test "loadFromWave: an empty wave gives an empty sound" {
        var device: audio_device.AudioDeviceState = .{};
        var table: SoundTable = .{};
        const sound: Sound = try loadFromWave(&table, &device, testing_allocator, .{});
        try expect(sound.stream.buffer == null);
        try expect(!isValid(&table, sound));
        try expect(!isReady(&table, sound));
        unload(&table, sound);
        play(&table, sound);
        setVolume(&table, sound, 0.5);
    }

    test "loadFromWave: a WAV's sound keeps the wave's rate, and one channel for a mono wave" {
        var device: audio_device.AudioDeviceState = .{};
        var wave_table: waves.AllocTable = .{};
        var table: SoundTable = .{};
        const wave: Wave = try waves.loadFromMemory(&wave_table, testing_allocator, ".wav", test_wav);
        defer waves.unload(&wave_table, wave);
        const sound: Sound = try loadFromWave(&table, &device, testing_allocator, wave);
        defer unload(&table, sound);
        try expect(isValid(&table, sound) and isReady(&table, sound));
        try expectEqual(wave.sampleRate, sound.stream.sampleRate);
        try expectEqual(@as(u32, waves.mixerChannelsOf(wave)), sound.stream.channels);
        try expectEqual(@as(u32, 32), sound.stream.sampleSize);
    }

    test "loadFromMemory: WAV decodes at once; an unknown format is refused" {
        var device: audio_device.AudioDeviceState = .{};
        var wave_table: waves.AllocTable = .{};
        var table: SoundTable = .{};
        const sound: Sound = try loadFromMemory(
            &table,
            &device,
            &wave_table,
            testing_allocator,
            ".wav",
            test_wav,
        );
        defer unload(&table, sound);
        try expect(isReady(&table, sound));
        const unknown: [8]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
        try expectError(error.UnknownAudioFormat, loadFromMemory(
            &table,
            &device,
            &wave_table,
            testing_allocator,
            ".bin",
            &unknown,
        ));
    }

    test "a sound plays on the device's mixer: play, pause, resume, stop; the setters persist and reach its voice" {
        var engine_mixer: mixer.Mixer = .{};
        var device: audio_device.AudioDeviceState = .{ .engine_mixer = &engine_mixer };
        var wave_table: waves.AllocTable = .{};
        var table: SoundTable = .{};
        const wave: Wave = try waves.loadFromMemory(&wave_table, testing_allocator, ".wav", test_wav);
        defer waves.unload(&wave_table, wave);
        const sound: Sound = try loadFromWave(&table, &device, testing_allocator, wave);
        defer unload(&table, sound);
        try expect(!isPlaying(&table, sound));
        play(&table, sound);
        try expect(isPlaying(&table, sound));
        pause(&table, sound);
        try expect(!isPlaying(&table, sound));
        resumeSound(&table, sound);
        try expect(isPlaying(&table, sound));
        setVolume(&table, sound, 100.0);
        setPitch(&table, sound, 0.001);
        setPan(&table, sound, 5.0);
        const entry: *SoundEntry = entryOf(&table, sound).?;
        try expectEqual(@as(f32, 10.0), entry.volume);
        try expectEqual(@as(f32, 0.0625), entry.pitch);
        try expectEqual(@as(f32, 1.0), entry.pan);
        stop(&table, sound);
        try expect(!isPlaying(&table, sound));
    }

    test "unloading a sound stops every voice reading it, an alias's too, and empties the alias" {
        var engine_mixer: mixer.Mixer = .{};
        var device: audio_device.AudioDeviceState = .{ .engine_mixer = &engine_mixer };
        var wave_table: waves.AllocTable = .{};
        var table: SoundTable = .{};
        const wave: Wave = try waves.loadFromMemory(&wave_table, testing_allocator, ".wav", test_wav);
        defer waves.unload(&wave_table, wave);
        const sound: Sound = try loadFromWave(&table, &device, testing_allocator, wave);
        const alias: Sound = loadAlias(&table, sound);
        defer unload(&table, alias);
        try expect(soundSlot(&table, alias).? != soundSlot(&table, sound).?);
        play(&table, sound);
        play(&table, sound);
        play(&table, alias);
        try expectEqual(@as(u32, 3), engine_mixer.playingVoiceCount());
        unload(&table, sound);
        try expectEqual(@as(u32, 0), engine_mixer.playingVoiceCount());
        try expect(!isReady(&table, alias));
        play(&table, alias);
        try expectEqual(@as(u32, 0), engine_mixer.playingVoiceCount());
    }
};

// Force discovery of nested-namespace inline tests.
comptime {
    _ = mixer;
    _ = audio_device;
    _ = waves;
    _ = composer;
    _ = sounds;
    _ = streams;
    _ = music;
    _ = analyser;
}

// ============================================================================
// SECTION - music (raylib's Music - long-form looped audio)
// ============================================================================
// Music in raylib is a long-form, looping playback container
// background music, ambient loops, in-game radio.  The defining
// characteristics vs Sound: streaming-friendly, naturally looped,
// callers expect to update its progress per-frame.
// On the web, both common music formats decode through Web Audio:
//   - WAV: sync decode via `wav.decode`; full PCM in memory; play
//     via a looping AudioBufferSourceNode.  Practical for short
//     loops only (a 3-min stereo WAV at 44.1k = ~30 MB resident).
//   - OGG: async decode via `decodeAudioData`; same looped
//     AudioBufferSourceNode after decode.  Decoded once,
//     played from the resulting AudioBuffer - same RAM cost
//     as WAV after decode but ~10x smaller download.
// For TRUE streaming (decode-as-played, low RAM), the recommended
// pattern is `HTMLAudioElement` + `MediaElementAudioSourceNode`
// - but that requires a DOM bridge to construct `<audio>`
// elements and route them through Web Audio.  This phase ships
// the buffered path; true streaming is a tracked enhancement.
// Music's surface mirrors raylib's verbs exactly:
// `loadFromMemory` / `unload` / `play` / `stop` / `pause` /
// `resumeMusic` / `isPlaying` / `update` / `setVolume` / `setPitch`
// / `setPan` / `setLooping` / `getTimePlayed` / `getTimeLength`.

// ============================================================================
// SECTION - streams (raylib's AudioStream - push-based PCM playback)
// ============================================================================
// An `AudioStream` plays frames the app makes as it goes - a synthesizer, procedural music, a voice. Its frames go
// into a ring, which a voice of the mixer reads at the stream's rate: `update` writes the next frames in, and
// `isProcessed` says whether half the ring is free for more - asked once a frame, and answered with half a ring's
// frames, the ring stays fed while the voice reads its other half. On a page the frames written each frame are
// forwarded to a ring of the renderer in the audio worklet, which its voice reads there.

// ============================================================================
// SECTION - sounds (raylib's Sound-typed playback)
// ============================================================================
// A `Sound` is a wave's samples registered with the mixer; playing it starts a voice reading them, at the sound's
// volume, pitch and pan. A sound is made from:
//   - `loadFromWave(wave)` - a wave in memory: a WAV file's, or one the composer made.
//   - `loadFromMemory(bytes)` - a WAV file's bytes. An OGG file is refused (`error.OggNeedsDecoder`): Vorbis plays
//     as music, decoded as it plays.
//   - `loadAlias(source)` - a second sound sharing another's samples, with playback parameters of its own.

// ============================================================================
// SECTION - composer (zimr-original synthesis primitives)
// ============================================================================
// Synth + sequencing toolkit.  Inspired by lightmix's Composer
// pattern (build up a list of {wave, start_offset} entries, then
// finalize into a single mixed Wave) but rewritten clean for our
// types and our 16-bit-int target format.
// Three building blocks:
//   - `tone(gpa, opts)` - generate a fixed-duration Wave of a
//     single waveform shape (sine / square / saw / triangle).
//     ADSR envelope optional.
//   - `silence(gpa, opts)` - zero-filled Wave of a given duration.
//     Useful as a sequencer pad.
//   - `Sequence` - a builder for multi-Wave compositions.
//     Place waves at sample-offset positions, finalize to a single
//     mixed Wave.  Mixing is sample-wise summation with hard
//     clipping at i16 range.
// All composer outputs are 16-bit signed PCM at 44100 Hz mono by
// default - these match the `waves` defaults so callers can chain
// directly into `format` if they need a different shape.

// ============================================================================
// SECTION - waves (raylib's Wave-typed loading + manipulation)
// ============================================================================
// `Wave` is the in-memory PCM container - bytes + format header.
// It mirrors raylib's `Wave` extern struct (`types.Wave`) so user
// code that names the type is portable.  Internally we round-trip
// via `codecs.audio.CanonicalWave` for any operation that needs to
// touch the samples uniformly.
// All allocations go through the caller-provided `gpa`.  Waves
// own their `data` pointer until `unload`.

// ============================================================================
// SECTION - AudioState bundle (user-State opt-in for audio resource pools)
// ============================================================================
// Apps that play audio reserve one field of this type in their
// `State` struct.  Apps that don't, don't.  This makes the cost of
// opting into audio visible at the State level.
// `device` is NOT in this bundle - it lives in `Runtime` because
// the JS audio-decode callbacks need to find it at a fixed
// address through the anchor.  Apps reach the device via
// `f.audio_device` (Frame ref into Runtime).
// As Phase C migrates each audio family, its table joins this
// bundle:
//   .music   ok  Phase C1
//   .sounds  ok  Phase C2
//   .streams ok  Phase C3
//   .waves   ok  Phase C4

pub const AudioState = struct {
    music: music.MusicTable = .{},
    sounds: sounds.SoundTable = .{},
    streams: streams.StreamTable = .{},
    waves: waves.AllocTable = .{},
};
