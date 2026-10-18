//! examples/audio_mixer - the engine's mixer, heard. T starts and stops a 440 Hz tone; Space, or a click, plays a
//! short blip at a random pan and pitch; Up and Down raise and lower the master volume. The screen shows what the
//! mixer is doing: the voices playing, the margin it keeps queued, and how often the output ran dry. In a page, the
//! browser keeps the sound silent until the first click or key press, which starts it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const asBytes = std.mem.asBytes;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const float = zm.float;
const sinTurns = zm.sinTurns;
const clamp = zm.clamp;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const background: Color = .{ .r = 24, .g = 26, .b = 34, .a = 255 };
const text_color: Color = .{ .r = 230, .g = 230, .b = 235, .a = 255 };
const dim_text_color: Color = .{ .r = 150, .g = 156, .b = 170, .a = 255 };

/// The blip: a 660 Hz sine lasting a quarter of a second, starting over 2 ms and fading out exponentially.
const blip_frequency: f32 = 660;
const blip_duration_seconds: f32 = 0.25;
const blip_attack_seconds: f32 = 0.002;
/// How fast the blip fades: its loudness falls by a factor of e every 1/14 s.
const blip_fade_rate: f32 = 14;
const blip_amplitude: f32 = 0.6;
/// The tone's loudness: quiet, since it plays until stopped.
const tone_amplitude: f32 = 0.2;

const State = struct {
    font: z.Font,
    /// The blip's samples, mono, at the mixer's rate: made once, read by every blip voice.
    blip_samples: []f32,
    /// The tone's frequency, which its generator reads through the voice's context.
    tone_frequency: f32,
    /// The tone's voice, while it plays; a stale name once stopped.
    tone_voice: z.mixer.Voice,
    blips_played: u32,
};

/// Makes the blip's samples: each one the sine at its moment, times an envelope - a rise from 0 to 1 over the attack,
/// so the blip does not start with a step (a click), times an exponential fade.
fn makeBlipSamples(gpa: Allocator) ![]f32 {
    const sample_rate: f32 = float(z.mixer.sample_rate);
    const blip_frame_count: usize = @round(blip_duration_seconds * sample_rate);
    const blip_samples: []f32 = try gpa.alloc(f32, blip_frame_count);
    for (blip_samples, 0..) |*blip_sample, frame_index| {
        const time_seconds: f32 = float(frame_index) / sample_rate;
        const attack: f32 = @min(time_seconds / blip_attack_seconds, 1);
        const fade: f32 = @exp(-time_seconds * blip_fade_rate);
        const sine: f32 = sinTurns(blip_frequency * time_seconds);
        blip_sample.* = blip_amplitude * attack * fade * sine;
    }
    return blip_samples;
}

/// The tone's generator: a sine at the frequency its state holds - the voice's own copy of `tone_frequency`, made when
/// it plays - the same on both channels. The sample at the voice's frame `n` is `amplitude x sin(2 pi f n / rate)` -
/// in turns, `sinTurns(f n / rate)`.
fn generateTone(state: *anyopaque, frames: []f32, first_frame: u64) void {
    const frequency: *const f32 = @ptrCast(@alignCast(state));
    const sample_rate: f32 = float(z.mixer.sample_rate);
    const frame_count: usize = frames.len / 2;
    for (0..frame_count) |frame_offset| {
        const frame_number: f32 = float(first_frame + frame_offset);
        const phase_turns: f32 = frequency.* * frame_number / sample_rate;
        const sample: f32 = tone_amplitude * sinTurns(phase_turns);
        frames[frame_offset * 2] = sample;
        frames[frame_offset * 2 + 1] = sample;
    }
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 16);
    const blip_samples: []f32 = try makeBlipSamples(gpa);
    s.* = .{
        .font = font,
        .blip_samples = blip_samples,
        .tone_frequency = 440,
        .tone_voice = .none,
        .blips_played = 0,
    };
    z.audio_device.init(f.audio_device);
}

/// The engine stops the mixer before this runs, so no voice still reads the blip's samples.
fn deinit(gpa: Allocator, s: *State) void {
    gpa.free(s.blip_samples);
    z.unloadFont(gpa, s.font);
}

/// Starts the tone, or stops it if it plays.
fn toggleTone(f: *z.Frame, s: *State) void {
    if (f.mixer.isPlaying(s.tone_voice)) {
        f.mixer.stopVoice(s.tone_voice);
        return;
    }
    const tone_source: z.mixer.Source = .{ .generator = .{
        .generate = &generateTone,
        .initial_state = asBytes(&s.tone_frequency),
    } };
    s.tone_voice = f.mixer.play(tone_source, .{});
}

/// Plays a blip somewhere between the speakers, a little higher or lower each time.
fn playBlip(f: *z.Frame, s: *State) void {
    const pan: f32 = f.random.float(f32) * 1.6 - 0.8;
    const pitch: f32 = 0.75 + f.random.float(f32) * 0.75;
    const blip_source: z.mixer.Source = .{ .samples = .{
        .samples = s.blip_samples,
        .channels = 1,
        .sample_rate = z.mixer.sample_rate,
    } };
    _ = f.mixer.play(blip_source, .{ .pan = pan, .pitch = pitch });
    s.blips_played += 1;
}

fn draw(f: *z.Frame, s: *State) void {
    z.clearViewport(f, background);
    const instructions: []const u8 = "T: tone on or off    Space or click: a blip    Up, Down: master volume";
    f.gl.text(.{ 24, 24 }, instructions, .{ .size = 18, .color = text_color, .font = &s.font });
    const tone_state: []const u8 = if (f.mixer.isPlaying(s.tone_voice)) "on" else "off";
    f.gl.textf(
        .{ 24, 60 },
        "voices playing {d}   tone {s}   blips {d}   master volume {d:.1}",
        .{ f.mixer.playingVoiceCount(), tone_state, s.blips_played, f.mixer.master_volume },
        .{ .size = 18, .color = text_color, .font = &s.font },
    );
    const browser_note: []const u8 = "in a page, the first click or key press starts the sound";
    f.gl.text(.{ 24, 92 }, browser_note, .{ .size = 16, .color = dim_text_color, .font = &s.font });
    // The latency readout: the output that plays, then the last five starts the mixer measured, newest first
    // (`Mixer.formatLatencyLine`).
    f.gl.textf(
        .{ 24, 132 },
        "output: {s}",
        .{f.mixer.outputName()},
        .{ .size = 15, .color = dim_text_color, .font = &s.font },
    );
    const readout_header: []const u8 = z.mixer.Mixer.latency_readout_header;
    f.gl.text(.{ 24, 154 }, readout_header, .{ .size = 15, .color = dim_text_color, .font = &s.font });
    var recent: [z.mixer.recent_start_capacity]z.mixer.LatencySample = undefined;
    const measured: []z.mixer.LatencySample = f.mixer.recentStarts(&recent);
    const past_output_ms: f64 = f.mixer.outputLatencyMilliseconds();
    const shown_count: usize = @min(measured.len, 5);
    for (measured[0..shown_count], 0..) |latency_sample, line_index| {
        var line_buffer: [96]u8 = undefined;
        const line: []const u8 = z.mixer.Mixer.formatLatencyLine(latency_sample, past_output_ms, &line_buffer);
        const line_top: f32 = 176 + float(line_index) * 22;
        f.gl.text(.{ 24, line_top }, line, .{ .size = 15, .color = dim_text_color, .font = &s.font });
    }
}

fn update(f: *z.Frame, s: *State) void {
    // A black screen with a start button, until it is pressed and the audio runs (`z.showAudioStartScreen`).
    if (z.showAudioStartScreen(f, &s.font)) {
        return;
    }
    if (z.isKeyPressed(f.input, .t)) {
        toggleTone(f, s);
    }
    const wants_blip: bool = z.isKeyPressed(f.input, .space) or z.isMouseButtonPressed(f.input, .left);
    if (wants_blip) {
        playBlip(f, s);
    }
    if (z.isKeyPressed(f.input, .up)) {
        f.mixer.setMasterVolume(clamp(f.mixer.master_volume + 0.1, 0, 1));
    }
    if (z.isKeyPressed(f.input, .down)) {
        f.mixer.setMasterVolume(clamp(f.mixer.master_volume - 0.1, 0, 1));
    }
    draw(f, s);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - the mixer",
            .width = 760,
            .height = 300,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
