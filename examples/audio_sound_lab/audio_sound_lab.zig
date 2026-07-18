// examples/audio_sound_lab.zig - loading, polyphony and positioning.
// MERGES three raylib audio samples behind a mode switch — `audio_sound_loading`,
// `audio_sound_multi` and `audio_sound_positioning`. They all need the same
// device bring-up and differ only in what they do with a Sound, so one app means
// one build and one listening session instead of three.
//
//   LOAD  — decode a real FILE (a .wav) into a Wave, read back what the decoder
//           actually found (rate / channels / frames), then upload it as a Sound:
//           play / stop / pause / resume, volume + pitch.
//           Deliberately a small WAV, not the bundled 96 s Vorbis: decoding that
//           to PCM would allocate ~16 MB up front and stall startup, and OGG is
//           already covered — as STREAMING, which is the right way to play it —
//           by the music_streaming example.
//   MULTI — polyphony via ALIASES. One Sound = one playback slot, so re-playing
//           it restarts it. `sounds.loadAlias` shares the decoded buffer but adds
//           an independent voice, so N aliases = N overlapping copies for the
//           price of one buffer. Tap fast and hear them stack.
//   POS   — pan + distance attenuation from a draggable emitter. NOTE zimr's pan
//           is [-1, 1] (left..right), NOT raylib's [0, 1] — see sounds.setPan.
//
// Lifecycle rule that bites: aliases share the source's buffer id, so ALIASES
// MUST BE UNLOADED BEFORE THE SOURCE, or their buffer id is already stale.
//
// Browsers won't start audio without a user gesture; the runtime wires
// `audio_device.resumeFromGesture` into the input layer, so the first tap on any
// button unlocks it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const z = @import("zimr");
const zm = @import("zm");

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
const test_sine_wav = @embedFile("test_sine_wav");

const Color = zm.Color;
const c = Color;
const Vec2 = zm.Vec2;
const float = zm.float;
const clamp = zm.clamp;
const bufPrint = std.fmt.bufPrint;

const alias_count: usize = 8;

const Mode = enum { load, multi, position };

/// What the emitter geometry resolves to — a named type so the audio params and
/// the on-screen readout can't drift apart.
const Placement = struct {
    pan: f32,
    vol: f32,
};

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,
    ui_font: z.Font,
    audio: z.AudioState = .{},

    clip: z.Sound, // decoded from the .wav
    clip_ok: bool,
    clip_rate: u32 = 0,
    clip_frames: u32 = 0,
    clip_ch: u32 = 0,
    blip: z.Sound, // synthesized; the alias source
    alias: [alias_count]z.Sound,
    alias_i: usize = 0,
    ping: z.Sound, // positioning voice

    mode: Mode = .load,
    volume: f32 = 0.8,
    pitch: f32 = 1.0,
    emitter: Vec2 = .{ 0, 0 },
    emitter_set: bool = false,
    repeat: bool = false,
    next_ping: f32 = 0,
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    z.audio_device.init(f.audio_device);

    var audio: z.AudioState = .{};

    // --- LOAD: decode a real file -----------------------------------------
    const wave: z.Wave = z.waves.loadFromMemory(&audio.waves, gpa, ".wav", test_sine_wav) catch .{};
    const clip_ok: bool = z.waves.isValid(wave);
    var clip: z.Sound = .{};
    var clip_rate: u32 = 0;
    var clip_frames: u32 = 0;
    var clip_ch: u32 = 0;
    if (clip_ok) {
        // What the DECODER found — not what we assumed. This is the whole point
        // of the loading path: the file dictates rate/channels, not the caller.
        clip_rate = wave.sampleRate;
        clip_frames = wave.frameCount;
        clip_ch = wave.channels;
        clip = try z.sounds.loadFromWave(&audio.sounds, f.audio_device, gpa, wave);
        z.waves.unload(&audio.waves, wave); // the Sound owns its buffer now
    }

    // --- MULTI: one buffer, many voices ------------------------------------
    const env: z.composer.Envelope = .{ .attack_ms = 3.0, .release_ms = 90.0 };
    const blip_wave: z.Wave = try z.composer.tone(&audio.waves, gpa, .{
        .frequency_hz = 660.0,
        .duration_ms = 220,
        .shape = .sine,
        .amplitude = 0.35,
        .envelope = env,
    });
    defer z.waves.unload(&audio.waves, blip_wave);
    const blip: z.Sound = try z.sounds.loadFromWave(&audio.sounds, f.audio_device, gpa, blip_wave);

    var alias: [alias_count]z.Sound = undefined;
    for (&alias) |*a| {
        a.* = z.sounds.loadAlias(&audio.sounds, blip);
    }

    // --- POS: a longer voice so panning is audible while dragging ----------
    const ping_wave: z.Wave = try z.composer.tone(&audio.waves, gpa, .{
        .frequency_hz = 440.0,
        .duration_ms = 400,
        .shape = .triangle,
        .amplitude = 0.4,
        .envelope = env,
    });
    defer z.waves.unload(&audio.waves, ping_wave);
    const ping: z.Sound = try z.sounds.loadFromWave(&audio.sounds, f.audio_device, gpa, ping_wave);

    const ui_font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24);
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 16);

    s.* = .{
        .ui_font = ui_font,
        .ui_host = z.UiHost.init(gpa, ui_font),
        .font = font,
        .audio = audio,
        .clip = clip,
        .clip_ok = clip_ok,
        .clip_rate = clip_rate,
        .clip_frames = clip_frames,
        .clip_ch = clip_ch,
        .blip = blip,
        .alias = alias,
        .ping = ping,
    };
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    z.unloadFont(gpa, s.ui_font);
    // Aliases FIRST: they share the source's buffer id, which goes stale the
    // moment the source is unloaded.
    for (s.alias) |a| {
        z.sounds.unload(&s.audio.sounds, a);
    }
    z.sounds.unload(&s.audio.sounds, s.blip);
    z.sounds.unload(&s.audio.sounds, s.ping);
    if (s.clip_ok) {
        z.sounds.unload(&s.audio.sounds, s.clip);
    }
    s.ui_host.deinit();
}

/// Round-robin the next free voice. Re-playing a Sound restarts it, so cycling
/// aliases is what turns one buffer into polyphony.
fn fireAlias(s: *State) void {
    const a: z.Sound = s.alias[s.alias_i];
    s.alias_i = (s.alias_i + 1) % alias_count;
    z.sounds.setVolume(&s.audio.sounds, a, s.volume);
    z.sounds.setPitch(&s.audio.sounds, a, s.pitch);
    z.sounds.play(&s.audio.sounds, a);
}

/// Pan + attenuation from the emitter's offset relative to the listener.
fn applyPositioning(s: *State, listener: Vec2, span: f32) Placement {
    const dx: f32 = s.emitter[0] - listener[0];
    const dy: f32 = s.emitter[1] - listener[1];
    // zimr pan is [-1, 1]: -1 hard left, 0 centre, +1 hard right.
    const pan: f32 = clamp(dx / span, -1.0, 1.0);
    const dist: f32 = @sqrt(dx * dx + dy * dy);
    const vol: f32 = clamp(1.0 - dist / (span * 1.6), 0.0, 1.0) * s.volume;
    z.sounds.setPan(&s.audio.sounds, s.ping, pan);
    z.sounds.setVolume(&s.audio.sounds, s.ping, vol);
    return .{ .pan = pan, .vol = vol };
}

fn update(f: *z.Frame, s: *State) void {
    const fw: f32 = f.window.widthf();
    const fh: f32 = f.window.heightf();

    z.clearViewport(f, .{ .r = 20, .g = 22, .b = 30, .a = 255 });

    const u: z.ui_real.Ui = s.ui_host.begin(f);

    const listener: Vec2 = .{ fw * 0.5, fh * 0.72 };
    const span: f32 = fw * 0.5;
    if (!s.emitter_set) {
        s.emitter = .{ fw * 0.5, fh * 0.50 };
        s.emitter_set = true;
    }

    var pan: f32 = 0;
    var vol: f32 = 0;
    if (s.mode == .position) {
        if (!u.wantCaptureMouse() and z.isMouseButtonDown(f.input, .left)) {
            s.emitter = z.getMousePosition(f.input);
        }
        const pv: Placement = applyPositioning(s, listener, span);
        pan = pv.pan;
        vol = pv.vol;
        if (s.repeat and f.time.time >= s.next_ping) {
            z.sounds.play(&s.audio.sounds, s.ping);
            s.next_ping = f.time.time + 0.6;
        }
    }

    // ---- scene ------------------------------------------------------------
    if (s.mode == .position) {
        // Listener, emitter, and the line between them: the geometry the pan and
        // volume are derived from, drawn so the numbers are checkable by eye.
        f.gl.line(listener, s.emitter, .{ .color = .{ .r = 70, .g = 80, .b = 100, .a = 255 }, .thickness = 2 });
        f.gl.circle(listener, 14, .{ .color = c.raywhite });
        f.gl.circle(listener, 22, .{ .color = .{ .r = 90, .g = 100, .b = 120, .a = 255 }, .outline = 2 });
        f.gl.circle(s.emitter, 16, .{ .color = .{ .r = 255, .g = 160, .b = 90, .a = 255 } });
        f.gl.text(
            .{ listener[0] - 34.0, listener[1] + 28.0 },
            "listener",
            .{ .size = 14, .color = c.gray, .font = &s.font },
        );
    } else if (s.mode == .multi) {
        // One bar per alias voice, lit while it's sounding — polyphony made
        // visible, so "did they overlap?" isn't a matter of trusting my ears.
        var playing: usize = 0;
        for (s.alias, 0..) |a, i| {
            const on: bool = z.sounds.isPlaying(&s.audio.sounds, a);
            if (on) {
                playing += 1;
            }
            const bw: f32 = (fw - 40.0) / float(alias_count);
            const x: f32 = 20.0 + float(i) * bw;
            const h: f32 = if (on) 90.0 else 16.0;
            const lit: Color = .{ .r = 90, .g = 220, .b = 140, .a = 255 };
            const dim: Color = .{ .r = 55, .g = 60, .b = 75, .a = 255 };
            f.gl.rect(
                .{ .x = x + 3.0, .y = fh * 0.62 - h, .width = bw - 6.0, .height = h },
                .{ .color = if (on) lit else dim },
            );
        }
        var vb: [48]u8 = undefined;
        const vt: []const u8 = bufPrint(&vb, "voices sounding: {d} / {d}", .{ playing, alias_count }) catch "?";
        f.gl.text(.{ 20, fh * 0.62 + 14.0 }, vt, .{ .size = 16, .color = c.raywhite, .font = &s.font });
    }

    // ---- UI ---------------------------------------------------------------
    u.setNextWindowPos(.{ 8, 8 }, .{});
    u.setNextWindowSize(.{ fw - 16.0, 300 }, .{});
    if (u.window("Sound lab", .{})) |w| {
        defer w.close();
        if (u.button("Load", .{})) {
            s.mode = .load;
        }
        u.sameLine(.{});
        if (u.button("Multi", .{})) {
            s.mode = .multi;
        }
        u.sameLine(.{});
        if (u.button("Position", .{})) {
            s.mode = .position;
        }
        u.separator();

        switch (s.mode) {
            .load => {
                if (!s.clip_ok) {
                    u.text("wav decode FAILED", .{});
                } else {
                    const secs: f32 = if (s.clip_rate > 0) float(s.clip_frames) / float(s.clip_rate) else 0;
                    u.text(".wav decoded: {d} Hz, {d} ch", .{ s.clip_rate, s.clip_ch });
                    u.text("{d} frames = {d:.2} s", .{ s.clip_frames, secs });
                    if (u.button("Play", .{})) {
                        z.sounds.setVolume(&s.audio.sounds, s.clip, s.volume);
                        z.sounds.setPitch(&s.audio.sounds, s.clip, s.pitch);
                        z.sounds.play(&s.audio.sounds, s.clip);
                    }
                    u.sameLine(.{});
                    if (u.button("Stop", .{})) {
                        z.sounds.stop(&s.audio.sounds, s.clip);
                    }
                    if (u.button("Pause", .{})) {
                        z.sounds.pause(&s.audio.sounds, s.clip);
                    }
                    u.sameLine(.{});
                    if (u.button("Resume", .{})) {
                        z.sounds.resumeSound(&s.audio.sounds, s.clip);
                    }
                    u.text("playing: {}", .{z.sounds.isPlaying(&s.audio.sounds, s.clip)});
                }
            },
            .multi => {
                u.text("One buffer, {d} alias voices.", .{alias_count});
                if (u.button("FIRE (tap fast)", .{})) {
                    fireAlias(s);
                }
            },
            .position => {
                u.text("Drag the orange emitter.", .{});
                if (u.button("Ping", .{})) {
                    z.sounds.play(&s.audio.sounds, s.ping);
                }
                u.sameLine(.{});
                if (u.button(if (s.repeat) "Repeat: ON" else "Repeat: OFF", .{})) {
                    s.repeat = !s.repeat;
                }
                u.text("pan {d:.2}   volume {d:.2}", .{ pan, vol });
            },
        }

        u.separator();
        _ = u.slider("volume", &s.volume, .{ .min = 0.0, .max = 1.0 });
        _ = u.slider("pitch", &s.pitch, .{ .min = 0.5, .max = 2.0 });
    }

    s.ui_host.render(f);
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - audio - sound lab",
            .width = 800,
            .height = 450,
            .scale_mode = .responsive,
            .depth_format = null,
            .clear = .{ .r = 20.0 / 255.0, .g = 22.0 / 255.0, .b = 30.0 / 255.0, .a = 1.0 },
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
    .memory = .managed,
};
