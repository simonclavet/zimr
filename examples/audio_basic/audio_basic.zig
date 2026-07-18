//! audio_basic — port of the GL `audio_basic`: the first sound on the
//! wgpu backend. Synthesizes three short tones on the CPU with `composer.tone`
//! (square/sine/triangle, with an attack/release envelope), uploads each to a
//! GPU-side... no — to a Web Audio buffer via `sounds.loadFromWave`, and plays
//! them when you tap a pad or press 1/2/3. The audio path is backend-agnostic
//! (Web Audio); the wgpu runner now hands the app an `f.audio_device`. Browsers
//! start the AudioContext suspended, so the first tap also resumes it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const Vec2 = zm.Vec2;
const Color = zm.Color;

const co = @import("example_common");
const c = z.colors;

const roboto_mono_ttf = @embedFile("roboto_mono_ttf");

const pad_count: usize = 3;
const labels = [pad_count][]const u8{ "LOW  (1)", "MID  (2)", "HIGH (3)" };
const pad_colors = [pad_count]Color{
    .{ .r = 56, .g = 96, .b = 200, .a = 255 },
    .{ .r = 56, .g = 180, .b = 110, .a = 255 },
    .{ .r = 210, .g = 120, .b = 64, .a = 255 },
};

const State = struct {
    font: z.Font,
    scratch: std.heap.ArenaAllocator,
    audio: z.AudioState = .{},
    snd: [pad_count]z.Sound,
    frame_count: usize = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    for (s.snd) |snd| {
        z.sounds.unload(&s.audio.sounds, snd);
    }
    s.scratch.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    z.audio_device.init(f.audio_device);

    const env: z.composer.Envelope = .{ .attack_ms = 5.0, .release_ms = 30.0 };
    var audio: z.AudioState = .{};

    // Three tones; the source Waves are freed after upload (the Sound owns its
    // GPU/Web-Audio buffer).
    const low: z.Wave = try z.composer.tone(&audio.waves, gpa, .{
        .frequency_hz = 220.0,
        .duration_ms = 250,
        .shape = .square,
        .amplitude = 0.3,
        .envelope = env,
    });
    defer z.waves.unload(&audio.waves, low);
    const mid: z.Wave = try z.composer.tone(&audio.waves, gpa, .{
        .frequency_hz = 440.0,
        .duration_ms = 250,
        .shape = .sine,
        .amplitude = 0.4,
        .envelope = env,
    });
    defer z.waves.unload(&audio.waves, mid);
    const high: z.Wave = try z.composer.tone(&audio.waves, gpa, .{
        .frequency_hz = 880.0,
        .duration_ms = 250,
        .shape = .triangle,
        .amplitude = 0.4,
        .envelope = env,
    });
    defer z.waves.unload(&audio.waves, high);

    var snd: [pad_count]z.Sound = undefined;
    snd[0] = try z.sounds.loadFromWave(&audio.sounds, f.audio_device, gpa, low);
    snd[1] = try z.sounds.loadFromWave(&audio.sounds, f.audio_device, gpa, mid);
    snd[2] = try z.sounds.loadFromWave(&audio.sounds, f.audio_device, gpa, high);

    s.* = .{
        .font = try z.loadFont(f, gpa, roboto_mono_ttf, 28),
        .scratch = std.heap.ArenaAllocator.init(gpa),
        .audio = audio,
        .snd = snd,
    };
}

fn inRect(px: f32, py: f32, x: f32, y: f32, w: f32, h: f32) bool {
    return px >= x and px < x + w and py >= y and py < y + h;
}

fn update(f: *z.Frame, state: *State) void {
    _ = state.scratch.reset(.retain_capacity);
    state.frame_count += 1;
    z.clearViewport(f, .{ .r = 18, .g = 20, .b = 30, .a = 255 });

    const mouse: Vec2 = z.getMousePosition(f.input);
    const click: bool = z.isMouseButtonPressed(f.input, .left);
    const KbK: type = z.KeyboardKey;
    const keys = [pad_count]KbK{ KbK.one, KbK.two, KbK.three };

    f.gl.text(.{ 16, 16 }, "zimr audio", .{ .size = 28, .color = c.white, .font = &state.font });
    f.gl.text(.{ 16, 50 }, "tap a pad or press 1 / 2 / 3", .{ .size = 15, .color = c.slate_400, .font = &state.font });

    const margin: f32 = 16;
    const pad_w: f32 = f.window.widthf() - margin * 2;
    const pad_h: f32 = 150;
    const gap: f32 = 18;
    const start_y: f32 = 92;

    var i: usize = 0;
    while (i < pad_count) : (i += 1) {
        const y: f32 = start_y + float(i) * (pad_h + gap);
        const hovered: bool = inRect(mouse[0], mouse[1], margin, y, pad_w, pad_h);
        const hit: bool = (click and hovered) or z.isKeyPressed(f.input, keys[i]);
        if (hit) {
            z.sounds.play(&state.audio.sounds, state.snd[i]);
        }
        const base: Color = pad_colors[i];
        const fill: Color = if (hovered)
            .{ .r = base.r +| 30, .g = base.g +| 30, .b = base.b +| 30, .a = 255 }
        else
            base;
        f.gl.rect(.{ .x = margin, .y = y, .width = pad_w, .height = pad_h }, .{ .color = fill });
        f.gl.rect(.{ .x = margin, .y = y, .width = pad_w, .height = pad_h }, .{ .color = c.white, .outline = 1.0 });
        f.gl.text(
            .{ margin + 20, y + pad_h / 2 - 14 },
            labels[i],
            .{ .size = 26, .color = c.white, .font = &state.font },
        );

        // Ready dot: green once the Web Audio buffer is decoded/uploaded.
        const ready: bool = z.sounds.isReady(&state.audio.sounds, state.snd[i]);
        const dot_color: Color = if (ready) c.emerald_400 else c.slate_500;
        f.gl.circle(.{ margin + pad_w - 28, y + 28 }, 9, .{ .color = dot_color, .segments = 16 });
    }

    co.caption(f.gl, state.font, "composer.tone -> Web Audio buffers; first tap resumes the AudioContext");
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - audio basic",
            .width = 450,
            .height = 800,
            .scale_mode = .fit,
            .depth_format = null,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
