//! tools/sound_capture_check - checks the sound a headless run saved against what it should be.
//!
//! A headless run's script can save the sound it played as a WAV file (`.capture_audio_to`); this reads that file, and
//! a list of expectations, one line a window of the run:
//!
//!     # start  end    notes      rms
//!     0.20     0.45   C          0.1328
//!     7.20     7.45   C E G      0.2300
//!
//! For each window it measures two things on the left channel, and fails the window when either is wrong:
//!
//!     loudness       the root mean square of the samples - within 3% of the line's
//!     pitch classes  how strongly each of the twelve sounds (`pitchClassAmplitude`): each named on the line present,
//!                    each other absent
//!
//! The pitch classes are measured as a Shepard instrument plays them: every note sounds in every octave at once, under
//! a bell centred at 400 Hz, so each pitch class is measured at its partial in the octave from middle C, 261.6 to
//! 523.3 Hz - near the bell's centre, where every pitch class's partial is strong. It exits with 1 if any window fails.
const std = @import("std");
const cli = @import("cli");
const zm = @import("zm");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Io = std.Io;
const eql = std.mem.eql;
const tokenizeAny = std.mem.tokenizeAny;
const splitScalar = std.mem.splitScalar;
const parseFloat = std.fmt.parseFloat;
const readInt = std.mem.readInt;
const trim = std.mem.trim;
const bufPrint = std.fmt.bufPrint;
const float = zm.float;
const sqrt = zm.sqrt;
const cosTurns = zm.cosTurns;
const sinTurns = zm.sinTurns;
const exp2 = zm.exp2;

/// The rate the headless output plays at: frames a second.
const sample_rate: f32 = 48_000;

/// The names of the twelve pitch classes, C to B, as the expectations name them.
const pitch_class_names = [12][]const u8{ "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" };

/// Middle C, the octave's first partial measured (`pitchClassAmplitude`): 440 Hz nine semitones down.
const middle_c_hz: f32 = 261.6256;

/// The loudness's tolerance: a window within 3% of the expected root mean square passes.
const loudness_tolerance: f32 = 0.03;

/// A pitch class is present when its partial's amplitude is at least this, and absent when it is under the second.
/// A Shepard note at velocity 0.5, centred, has partials of about 0.12 to 0.14 near the bell's centre; a pitch class no
/// note plays, only the leakage of its neighbours' partials, a semitone and more away - under 0.002.
const present_amplitude: f32 = 0.03;
const absent_amplitude: f32 = 0.01;

/// The command line: the WAV file the run saved, and the expectations.
const CheckArgs = struct {
    capture: []const u8,
    expectations: []const u8,
};

const check_cli: cli.Config(CheckArgs) = .{
    .prog = "sound_capture_check",
    .description = "Checks a headless run's saved sound against expected notes and loudness, window by window.",
};

/// The left channel of a WAV file the headless output writes: 32-bit float samples (format 3), two channels
/// interleaved, at 48 000 frames a second. Its chunks are walked from the RIFF header - "fmt " for the format, "data"
/// for the samples - so that a chunk this does not know is stepped over.
fn readLeftChannel(gpa: Allocator, wav_bytes: []const u8) ![]f32 {
    if (wav_bytes.len < 12 or !eql(u8, wav_bytes[0..4], "RIFF") or !eql(u8, wav_bytes[8..12], "WAVE")) {
        return error.NotAWavFile;
    }
    var chunk_start: usize = 12;
    var channel_count: u16 = 0;
    var sample_format: u16 = 0;
    while (chunk_start + 8 <= wav_bytes.len) {
        const chunk_name: []const u8 = wav_bytes[chunk_start..][0..4];
        const chunk_size: u32 = readInt(u32, wav_bytes[chunk_start + 4 ..][0..4], .little);
        const body_start: usize = chunk_start + 8;
        const body_end: usize = @min(body_start + chunk_size, wav_bytes.len);
        const body: []const u8 = wav_bytes[body_start..body_end];
        if (eql(u8, chunk_name, "fmt ")) {
            // The format chunk begins with the sample format and the channel count, two bytes each.
            if (body.len < 4) {
                return error.FormatChunkTooShort;
            }
            sample_format = readInt(u16, body[0..2], .little);
            channel_count = readInt(u16, body[2..4], .little);
        } else if (eql(u8, chunk_name, "data")) {
            if (sample_format != 3 or channel_count != 2) {
                return error.NotFloatStereo;
            }
            const frame_count: usize = body.len / 8;
            const left: []f32 = try gpa.alloc(f32, frame_count);
            for (left, 0..) |*sample, frame_index| {
                const sample_bits: u32 = readInt(u32, body[frame_index * 8 ..][0..4], .little);
                sample.* = @bitCast(sample_bits);
            }
            return left;
        }
        // Chunks are padded to an even size.
        chunk_start = body_start + chunk_size + (chunk_size & 1);
    }
    return error.NoSamples;
}

/// The root mean square of `samples`: the square root of their mean square - a steady sine's amplitude times
/// 1 / sqrt 2.
fn rootMeanSquare(samples: []const f32) f32 {
    var sum_of_squares: f64 = 0;
    for (samples) |sample| {
        sum_of_squares += sample * sample;
    }
    const mean_square: f64 = sum_of_squares / float(samples.len);
    return @floatCast(sqrt(mean_square));
}

/// How strongly pitch class `pitch_class` sounds in `samples`: the amplitude of its partial in the octave from middle
/// C, by the Goertzel algorithm - the one bin of a discrete Fourier transform at that frequency, computed alone. The
/// samples are weighed by a Hann window first, `0.5 - 0.5 cos`, which keeps a strong partial a semitone away from
/// leaking into the bin; the window halves a sine's sum, so the amplitude is twice the bin's magnitude over half the
/// sample count: `4 |X| / N`.
fn pitchClassAmplitude(samples: []const f32, pitch_class: u4) f32 {
    const frequency_hz: f32 = middle_c_hz * exp2(float(pitch_class) / 12);
    const turns_per_sample: f32 = frequency_hz / sample_rate;
    var real_sum: f64 = 0;
    var imaginary_sum: f64 = 0;
    const sample_count: f32 = float(samples.len);
    for (samples, 0..) |sample, sample_index| {
        const window: f32 = 0.5 - 0.5 * cosTurns(float(sample_index) / sample_count);
        const phase_turns: f32 = @mod(turns_per_sample * float(sample_index), 1);
        const weighed: f32 = sample * window;
        real_sum += weighed * cosTurns(phase_turns);
        imaginary_sum -= weighed * sinTurns(phase_turns);
    }
    const magnitude: f64 = sqrt(real_sum * real_sum + imaginary_sum * imaginary_sum);
    return @floatCast(4 * magnitude / sample_count);
}

/// One line of the expectations: a window, the pitch classes that sound in it, and its loudness.
const Expectation = struct {
    start_seconds: f32,
    end_seconds: f32,
    /// Bit `p` set when pitch class `p` must sound.
    pitch_classes: u12,
    root_mean_square: f32,
};

/// A line of the expectations read: the window's start and end, the notes' names, and the loudness last.
fn parseExpectation(line: []const u8) !Expectation {
    var tokens = tokenizeAny(u8, line, " \t\r");
    var words: [16][]const u8 = undefined;
    var word_count: usize = 0;
    while (tokens.next()) |token| {
        if (word_count == words.len) {
            return error.TooManyWords;
        }
        words[word_count] = token;
        word_count += 1;
    }
    if (word_count < 3) {
        return error.TooFewWords;
    }
    var expectation: Expectation = .{
        .start_seconds = try parseFloat(f32, words[0]),
        .end_seconds = try parseFloat(f32, words[1]),
        .pitch_classes = 0,
        .root_mean_square = try parseFloat(f32, words[word_count - 1]),
    };
    for (words[2 .. word_count - 1]) |note_name| {
        const pitch_class: u4 = for (pitch_class_names, 0..) |name, index| {
            if (eql(u8, name, note_name)) {
                break @intCast(index);
            }
        } else return error.UnknownNote;
        expectation.pitch_classes |= @as(u12, 1) << pitch_class;
    }
    return expectation;
}

/// Checks one window: its loudness, and each pitch class present or absent as the line says. Prints what it measured,
/// and returns whether the window passed.
fn checkWindow(out: *Io.Writer, left: []const f32, expectation: Expectation) !bool {
    const first_sample: usize = @round(expectation.start_seconds * sample_rate);
    const end_sample: usize = @round(expectation.end_seconds * sample_rate);
    if (end_sample > left.len or first_sample >= end_sample) {
        try out.print("FAIL {d:.2}-{d:.2} s: past the end of the capture ({d:.2} s)\n", .{
            expectation.start_seconds,
            expectation.end_seconds,
            float(left.len) / sample_rate,
        });
        return false;
    }
    const samples: []const f32 = left[first_sample..end_sample];
    const measured_rms: f32 = rootMeanSquare(samples);
    const loudness_error: f32 = @abs(measured_rms - expectation.root_mean_square) / expectation.root_mean_square;
    var is_passed: bool = loudness_error <= loudness_tolerance;
    var pitch_class_report: [128]u8 = undefined;
    var report_length: usize = 0;
    for (0..12) |pitch_class_index| {
        const pitch_class: u4 = @intCast(pitch_class_index);
        const amplitude: f32 = pitchClassAmplitude(samples, pitch_class);
        const is_expected: bool = expectation.pitch_classes & (@as(u12, 1) << pitch_class) != 0;
        const is_right: bool = if (is_expected) amplitude >= present_amplitude else amplitude < absent_amplitude;
        is_passed = is_passed and is_right;
        if (is_expected or !is_right) {
            const marker: []const u8 = if (is_right) "" else "!";
            const written: []const u8 = bufPrint(pitch_class_report[report_length..], " {s}{s}={d:.3}", .{
                marker,
                pitch_class_names[pitch_class_index],
                amplitude,
            }) catch "";
            report_length += written.len;
        }
    }
    const verdict: []const u8 = if (is_passed) "ok  " else "FAIL";
    try out.print("{s} {d:.2}-{d:.2} s: rms {d:.4} (expected {d:.4}),{s}\n", .{
        verdict,
        expectation.start_seconds,
        expectation.end_seconds,
        measured_rms,
        expectation.root_mean_square,
        pitch_class_report[0..report_length],
    });
    return is_passed;
}

pub fn main(init: std.process.Init) !void {
    var arena_state: ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const gpa: Allocator = arena_state.allocator();
    const io: Io = init.io;
    const args: CheckArgs = cli.args(&init, CheckArgs, check_cli);
    const cwd: Io.Dir = .cwd();
    var out_buffer: [4096]u8 = undefined;
    var out_writer: Io.File.Writer = Io.File.stdout().writer(io, &out_buffer);
    const out: *Io.Writer = &out_writer.interface;
    const wav_bytes: []const u8 = try cwd.readFileAlloc(io, args.capture, gpa, .unlimited);
    const left: []const f32 = try readLeftChannel(gpa, wav_bytes);
    const expectations_text: []const u8 = try cwd.readFileAlloc(io, args.expectations, gpa, .unlimited);
    var failure_count: usize = 0;
    var window_count: usize = 0;
    var lines = splitScalar(u8, expectations_text, '\n');
    while (lines.next()) |line| {
        const trimmed: []const u8 = trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') {
            continue;
        }
        const expectation: Expectation = try parseExpectation(trimmed);
        window_count += 1;
        if (!try checkWindow(out, left, expectation)) {
            failure_count += 1;
        }
    }
    try out.print("sound_capture_check: {d} windows, {d} failed\n", .{ window_count, failure_count });
    try out.flush();
    if (failure_count > 0 or window_count == 0) {
        std.process.exit(1);
    }
}
