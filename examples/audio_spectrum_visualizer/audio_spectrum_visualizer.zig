// examples/audio_spectrum_visualizer.zig - live FFT of whatever is playing.
// Ports raylib's `audio_spectrum_visualizer`.
//
// The spectrum comes from a WebAudio AnalyserNode tapped off the master bus. It
// is a TAP, not an insert: master already reaches the speakers, and the analyser
// merely receives a copy - so attaching one cannot alter what you hear. Each
// frame it writes one byte per frequency bin (0..255) STRAIGHT into a wasm-side
// slice; there is no intermediate copy.
//
// What this exercises (the engine work this drove):
//   - `z.analyser.attach / read / detach` - NEW. Backed by three new host
//     functions in the WebAudio bridge (`js_audio_create_analyser`,
//     `js_audio_get_frequency_data`, `js_audio_destroy_analyser`), which is only
//     possible now that bridge.zig provides an `audio` import namespace at all.
//
// Bins are drawn on a LOG frequency axis, because a linear one wastes most of the
// screen on the inaudible top octaves - musical content lives in the bottom fifth
// of a linear FFT.
//
// Leak-clean (`.memory = .managed`): sounds + UiHost are released in deinit.

const std = @import("std");
const Allocator = std.mem.Allocator;

const z = @import("zimr");
const zm = @import("zm");

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const Color = zm.Color;
const c = Color;
const float = zm.float;
const clamp = zm.clamp;

const fft_size: u32 = 1024;
const max_bins: usize = fft_size / 2; // usable bins = half the FFT
const bars: usize = 48;
const voice_count: usize = 4;

/// Four tones spread over the spectrum, so the bars have something to separate.
const freqs = [voice_count]f32{ 110.0, 330.0, 880.0, 2200.0 };
const names = [voice_count][]const u8{ "110 Hz", "330 Hz", "880 Hz", "2.2 kHz" };

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,
    ui_font: z.Font,
    audio: z.AudioState = .{},
    an: z.analyser.Analyser = .{},

    voice: [voice_count]z.Sound,
    spectrum: [max_bins]u8 = @splat(0),
    smooth: [bars]f32 = @splat(0), // display-smoothed bar heights
    bins: u32 = 0,
    loop_on: bool = false,
    next_hit: f32 = 0,
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    z.audio_device.init(f.audio_device);

    var audio: z.AudioState = .{};
    const env: z.composer.Envelope = .{ .attack_ms = 8.0, .release_ms = 260.0 };

    var voice: [voice_count]z.Sound = undefined;
    for (freqs, 0..) |hz, i| {
        const w: z.Wave = try z.composer.tone(&audio.waves, gpa, .{
            .frequency_hz = hz,
            .duration_ms = 700,
            .shape = .sine, // a pure tone => one clean peak, so the FFT is readable
            .amplitude = 0.32,
            .envelope = env,
        });
        defer z.waves.unload(&audio.waves, w);
        voice[i] = try z.sounds.loadFromWave(&audio.sounds, f.audio_device, gpa, w);
    }

    const an: z.analyser.Analyser = z.analyser.attach(f.audio_device, fft_size);

    const ui_font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24);
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 15);

    s.* = .{
        .ui_font = ui_font,
        .ui_host = z.UiHost.init(gpa, ui_font),
        .font = font,
        .audio = audio,
        .an = an,
        .voice = voice,
        .bins = an.bins,
    };
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    z.unloadFont(gpa, s.ui_font);
    for (s.voice) |v| {
        z.sounds.unload(&s.audio.sounds, v);
    }
    s.ui_host.deinit();
}

fn update(f: *z.Frame, s: *State) void {
    const fw: f32 = f.window.widthf();
    const fh: f32 = f.window.heightf();

    // Pull this frame's spectrum. Returns 0 bins when there's no analyser (e.g. a
    // native host), so everything below degrades to a flat, silent display rather
    // than reading stale samples.
    const n: u32 = z.analyser.read(f.audio_device, s.an, &s.spectrum);

    z.clearViewport(f, .{ .r = 14, .g = 16, .b = 24, .a = 255 });

    const u: z.ui_real.Ui = s.ui_host.begin(f);

    if (s.loop_on and f.time.time >= s.next_hit) {
        // Round-robin the voices so the peak visibly walks up the spectrum.
        const idx: usize = @trunc(@mod(f.time.time * 1.6, float(voice_count)));
        z.sounds.play(&s.audio.sounds, s.voice[idx]);
        s.next_hit = f.time.time + 0.62;
    }

    // ---- bars -------------------------------------------------------------
    const base_y: f32 = fh - 30.0;
    const top_y: f32 = 300.0;
    const height: f32 = @max(base_y - top_y, 60.0);
    const bw: f32 = (fw - 24.0) / float(bars);

    for (0..bars) |i| {
        // LOG bin mapping: bar i covers [lo, hi) so each bar spans a constant
        // RATIO of frequency, which is how pitch actually works. A linear map
        // would cram every musical tone into the leftmost few bars.
        const t0: f32 = float(i) / float(bars);
        const t1: f32 = float(i + 1) / float(bars);
        const nb: f32 = float(@max(n, 1));
        const lo: usize = @trunc(@min(nb - 1.0, @exp(t0 * @log(nb))));
        const hi: usize = @trunc(@min(nb, @exp(t1 * @log(nb))));

        var peak: f32 = 0;
        var k: usize = lo;
        while (k < @max(hi, lo + 1) and k < n) : (k += 1) {
            peak = @max(peak, float(s.spectrum[k]) / 255.0);
        }

        // Attack fast, release slow - otherwise the bars strobe and read as noise.
        const prev: f32 = s.smooth[i];
        s.smooth[i] = if (peak > prev) peak else prev + (peak - prev) * 0.18;

        const h: f32 = clamp(s.smooth[i], 0.0, 1.0) * height;
        const x: f32 = 12.0 + float(i) * bw;
        const heat: f32 = clamp(s.smooth[i], 0.0, 1.0);
        const col: Color = .{
            .r = @trunc(60.0 + 195.0 * heat),
            .g = @trunc(200.0 - 90.0 * heat),
            .b = @trunc(180.0 - 60.0 * heat),
            .a = 255,
        };
        f.gl.rect(
            .{ .x = x + 1.0, .y = base_y - h, .width = bw - 2.0, .height = h },
            .{ .color = col },
        );
    }
    f.gl.line(.{ 12, base_y }, .{ fw - 12.0, base_y }, .{
        .color = .{ .r = 60, .g = 66, .b = 84, .a = 255 },
        .thickness = 2,
    });
    f.gl.text(.{ 12, base_y + 6.0 }, "low", .{ .size = 14, .color = c.gray, .font = &s.font });
    f.gl.text(
        .{ fw - 60.0, base_y + 6.0 },
        "high",
        .{ .size = 14, .color = c.gray, .font = &s.font },
    );

    // ---- UI ---------------------------------------------------------------
    u.setNextWindowPos(.{ 8, 8 }, .{});
    u.setNextWindowSize(.{ fw - 16.0, 270 }, .{});
    if (u.window("Spectrum", .{})) |w| {
        defer w.close();
        u.text("Tap a tone; watch its peak move.", .{});
        u.separator();
        for (names, 0..) |nm, i| {
            if (u.button(nm, .{})) {
                z.sounds.play(&s.audio.sounds, s.voice[i]);
            }
            if (i % 2 == 0) {
                u.sameLine(.{});
            }
        }
        u.separator();
        if (u.button(if (s.loop_on) "Auto: ON" else "Auto: OFF", .{})) {
            s.loop_on = !s.loop_on;
        }
        // If bins is 0 the analyser never attached - say so, rather than showing a
        // convincingly-empty graph.
        if (s.bins == 0) {
            u.text("no analyser (audio host missing?)", .{});
        } else {
            u.text("fft {d}   bins {d}   live {d}", .{ fft_size, s.bins, n });
        }
    }

    s.ui_host.render(f);
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - audio - spectrum visualizer",
            .width = 800,
            .height = 450,
            .scale_mode = .responsive,
            .depth_format = null,
            .clear = .{ .r = 14.0 / 255.0, .g = 16.0 / 255.0, .b = 24.0 / 255.0, .a = 1.0 },
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
    .memory = .managed,
};
