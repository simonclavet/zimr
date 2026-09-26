// examples/audio_amp_envelope.zig - shaping a tone's amplitude over time (ADSR).
// Ports raylib's `audio_amp_envelope`.
//
//   ATTACK  silence -> full, over attack_ms      (0 = a hard click)
//   DECAY   full -> sustain_level, over decay_ms
//   SUSTAIN held at sustain_level
//   RELEASE sustain_level -> silence, over release_ms
//
// The four sliders regenerate the Wave on the CPU, so the plot below is not an
// illustration of the envelope - it IS the PCM that will be played. What you see
// is literally what you hear, which is the only way to be sure the envelope is
// actually being applied rather than merely configured.
//
// No engine work needed: `composer.Envelope` already carries the full ADSR
// (attack_ms / decay_ms / sustain_level / release_ms) and `tone()` multiplies it
// into every sample. That shape is pinned by a host test in features_test.zig -
// tone generation is pure CPU, so it is checkable without a device or ears.
//
// Leak-clean (`.memory = .managed`): each regeneration releases the previous
// Sound + samples before allocating the next.

const std = @import("std");
const Allocator = std.mem.Allocator;

const z = @import("zimr");
const zm = @import("zm");

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const Color = zm.Color;
const c = Color;
const float = zm.float;
const clamp = zm.clamp;

const plot_cols: usize = 220;
const duration_ms: u32 = 900;

const State = struct {
    gpa: Allocator, // Frame carries no allocator; regeneration happens in update
    ui_host: z.UiHost,
    font: z.Font,
    ui_font: z.Font,
    audio: z.AudioState = .{},

    snd: z.Sound = .{},
    have_snd: bool = false,

    // live ADSR
    attack_ms: f32 = 60.0,
    decay_ms: f32 = 120.0,
    sustain: f32 = 0.55,
    release_ms: f32 = 320.0,
    freq_hz: f32 = 330.0,

    /// Per-column peak |sample| of the generated PCM - the envelope, MEASURED off
    /// the wave rather than re-derived from the sliders.
    plot: [plot_cols]f32 = @splat(0),
    frames: u32 = 0,
    dirty: bool = true,
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    z.audio_device.init(f.audio_device);
    const ui_font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24);
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 15);
    s.* = .{
        .gpa = gpa,
        .ui_font = ui_font,
        .ui_host = z.UiHost.init(gpa, ui_font),
        .font = font,
    };
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    z.unloadFont(gpa, s.ui_font);
    if (s.have_snd) {
        z.sounds.unload(&s.audio.sounds, s.snd);
    }
    s.ui_host.deinit();
}

/// Rebuild the Wave from the current ADSR, upload it, and measure its envelope
/// for the plot. The OLD sound is released first - regenerating on every slider
/// nudge would otherwise pile up buffers.
fn regenerate(f: *z.Frame, s: *State) void {
    const w: z.Wave = z.composer.tone(&s.audio.waves, s.gpa, .{
        .frequency_hz = s.freq_hz,
        .duration_ms = duration_ms,
        .shape = .sine,
        .amplitude = 0.9,
        .envelope = .{
            .attack_ms = s.attack_ms,
            .decay_ms = s.decay_ms,
            .sustain_level = s.sustain,
            .release_ms = s.release_ms,
        },
    }) catch return;
    defer z.waves.unload(&s.audio.waves, w);

    // Measure the envelope OFF THE PCM: peak |sample| per column. At these
    // frequencies a column spans many periods, so its peak is the envelope there.
    const samples: []f32 = z.waves.loadSamples(s.gpa, w) catch return;
    defer z.waves.unloadSamples(s.gpa, samples);

    s.frames = w.frameCount;
    const per: usize = @max(samples.len / plot_cols, 1);
    for (0..plot_cols) |i| {
        const a: usize = i * per;
        const b: usize = @min(a + per, samples.len);
        var m: f32 = 0;
        var k: usize = a;
        while (k < b) : (k += 1) {
            m = @max(m, @abs(samples[k]));
        }
        s.plot[i] = m;
    }

    if (s.have_snd) {
        z.sounds.unload(&s.audio.sounds, s.snd);
        s.have_snd = false;
    }
    s.snd = z.sounds.loadFromWave(&s.audio.sounds, f.audio_device, s.gpa, w) catch return;
    s.have_snd = true;
}

fn update(f: *z.Frame, s: *State) void {
    const fw: f32 = f.window.widthf();
    const fh: f32 = f.window.heightf();

    if (s.dirty) {
        regenerate(f, s);
        s.dirty = false;
    }

    z.clearViewport(f, .{ .r = 16, .g = 18, .b = 26, .a = 255 });

    const u: z.ui_real.Ui = s.ui_host.begin(f);

    // ---- the measured envelope ------------------------------------------
    const base: f32 = fh - 60.0;
    const top: f32 = 330.0;
    const h: f32 = @max(base - top, 80.0);
    const cw: f32 = (fw - 32.0) / float(plot_cols);

    // Mirror it about the centre line: that's what a waveform actually looks
    // like, and it makes the attack/decay/release slopes obvious.
    const mid: f32 = base - h * 0.5;
    for (0..plot_cols) |i| {
        const v: f32 = clamp(s.plot[i], 0.0, 1.0) * h * 0.5;
        const x: f32 = 16.0 + float(i) * cw;
        const heat: f32 = clamp(s.plot[i], 0.0, 1.0);
        const col: Color = .{
            .r = @trunc(70.0 + 150.0 * heat),
            .g = @trunc(210.0 - 40.0 * heat),
            .b = @trunc(160.0 + 40.0 * heat),
            .a = 255,
        };
        f.gl.rect(
            .{ .x = x, .y = mid - v, .width = @max(cw - 1.0, 1.0), .height = @max(v * 2.0, 1.0) },
            .{ .color = col },
        );
    }
    f.gl.line(.{ 16, mid }, .{ fw - 16.0, mid }, .{
        .color = .{ .r = 60, .g = 66, .b = 84, .a = 255 },
        .thickness = 1,
    });

    // Stage boundaries, so each slider's region of the curve is identifiable.
    const total: f32 = float(duration_ms);
    const marks = [3]f32{
        s.attack_ms,
        s.attack_ms + s.decay_ms,
        total - s.release_ms,
    };
    const labels = [3][]const u8{ "A", "D", "R" };
    for (marks, labels) |ms, lb| {
        const t: f32 = clamp(ms / total, 0.0, 1.0);
        const x: f32 = 16.0 + t * (fw - 32.0);
        f.gl.line(.{ x, mid - h * 0.5 }, .{ x, mid + h * 0.5 }, .{
            .color = .{ .r = 120, .g = 130, .b = 160, .a = 140 },
            .thickness = 1,
        });
        f.gl.text(.{ x + 3.0, mid + h * 0.5 + 4.0 }, lb, .{
            .size = 14,
            .color = c.gray,
            .font = &s.font,
        });
    }
    f.gl.text(
        .{ 16, base + 6.0 },
        "peak |sample| per column - the ACTUAL pcm, not a sketch",
        .{ .size = 14, .color = c.gray, .font = &s.font },
    );

    // ---- UI ---------------------------------------------------------------
    u.setNextWindowPos(.{ 8, 8 }, .{});
    u.setNextWindowSize(.{ fw - 16.0, 300 }, .{});
    if (u.window("Amp envelope (ADSR)", .{})) |w| {
        defer w.close();
        if (u.button("PLAY", .{})) {
            if (s.have_snd) {
                z.sounds.play(&s.audio.sounds, s.snd);
            }
        }
        u.sameLine(.{});
        u.text("{d} ms tone", .{duration_ms});
        u.separator();

        var changed: bool = false;
        changed = u.slider("attack ms", &s.attack_ms, .{ .min = 0, .max = 400 }) or changed;
        changed = u.slider("decay ms", &s.decay_ms, .{ .min = 0, .max = 400 }) or changed;
        changed = u.slider("sustain", &s.sustain, .{ .min = 0.0, .max = 1.0 }) or changed;
        changed = u.slider("release ms", &s.release_ms, .{ .min = 0, .max = 600 }) or changed;
        changed = u.slider("freq Hz", &s.freq_hz, .{ .min = 80, .max = 900 }) or changed;
        if (changed) {
            s.dirty = true; // regenerate ONCE next frame, not per slider event
        }
        u.text("frames {d}", .{s.frames});
    }

    s.ui_host.render(f);
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - audio - amp envelope",
            .width = 800,
            .height = 450,
            .scale_mode = .responsive,
            .depth_format = null,
            .clear = .{ .r = 16.0 / 255.0, .g = 18.0 / 255.0, .b = 26.0 / 255.0, .a = 1.0 },
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
    .memory = .managed,
};
