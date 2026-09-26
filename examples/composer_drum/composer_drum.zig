//! composer_drum - port of the GL `composer_drum`: a tiny drum machine on
//! the wgpu audio bridge. Synthesizes a kick (60Hz sine), snare (250Hz saw),
//! and hat (4kHz triangle) with `composer.tone`, then bakes an 8-step pattern
//! into ONE looping Wave via `composer.Sequence` (each drum added at its step's
//! frame offset). Tap PLAY (or press SPACE) to play the loop; a step grid shows
//! the pattern and a playhead sweeps it. All PCM - no streaming/OGG needed.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const Vec2 = zm.Vec2;
const Color = zm.Color;

const common = @import("example_common");
const c = z.colors;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const sample_rate: u32 = 44100;
const step_ms: usize = 125;
const steps_per_loop: usize = 8;

const State = struct {
    font: z.Font,
    scratch: std.heap.ArenaAllocator,
    audio: z.AudioState = .{},
    loop: z.Sound = .{},
    playing: bool = false,
    play_started_at_frame: usize = 0,
    frame_count: usize = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.scratch.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    z.audio_device.init(f.audio_device);
    var audio: z.AudioState = .{};

    const kick: z.Wave = try z.composer.tone(&audio.waves, gpa, .{
        .frequency_hz = 60.0,
        .duration_ms = 100,
        .shape = .sine,
        .amplitude = 0.7,
        .sample_rate = sample_rate,
        .envelope = .{ .attack_ms = 1.0, .release_ms = 80.0 },
    });
    defer z.waves.unload(&audio.waves, kick);
    const snare: z.Wave = try z.composer.tone(&audio.waves, gpa, .{
        .frequency_hz = 250.0,
        .duration_ms = 80,
        .shape = .sawtooth,
        .amplitude = 0.5,
        .sample_rate = sample_rate,
        .envelope = .{ .attack_ms = 0.5, .release_ms = 60.0 },
    });
    defer z.waves.unload(&audio.waves, snare);
    const hat: z.Wave = try z.composer.tone(&audio.waves, gpa, .{
        .frequency_hz = 4000.0,
        .duration_ms = 30,
        .shape = .triangle,
        .amplitude = 0.3,
        .sample_rate = sample_rate,
        .envelope = .{ .attack_ms = 0.5, .release_ms = 20.0 },
    });
    defer z.waves.unload(&audio.waves, hat);

    // Bake the 8-step pattern into one Wave (kick on 0,4; snare on 2,6; hat all).
    var seq: z.composer.Sequence = .init(&audio.waves, gpa, sample_rate, 1);
    defer seq.deinit();
    const step_frames: u32 = (sample_rate * @as(u32, @intCast(step_ms))) / 1000;
    try seq.add(kick, 0 * step_frames);
    try seq.add(kick, 4 * step_frames);
    try seq.add(snare, 2 * step_frames);
    try seq.add(snare, 6 * step_frames);
    for (0..steps_per_loop) |si| {
        try seq.add(hat, @as(u32, @intCast(si)) * step_frames);
    }
    const loop_wave: z.Wave = try seq.finalize();
    defer z.waves.unload(&audio.waves, loop_wave);

    const loop_snd: z.Sound = try z.sounds.loadFromWave(&audio.sounds, f.audio_device, gpa, loop_wave);
    s.* = .{
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 28),
        .scratch = std.heap.ArenaAllocator.init(gpa),
        .audio = audio,
        .loop = loop_snd,
    };
}

const Lane = struct { name: []const u8, hits: [steps_per_loop]bool, color: Color };
const lanes = [3]Lane{
    .{
        .name = "KICK",
        .hits = .{ true, false, false, false, true, false, false, false },
        .color = .{ .r = 210, .g = 100, .b = 80, .a = 255 },
    },
    .{
        .name = "SNRE",
        .hits = .{ false, false, true, false, false, false, true, false },
        .color = .{ .r = 100, .g = 200, .b = 90, .a = 255 },
    },
    .{
        .name = "HAT ",
        .hits = .{ true, true, true, true, true, true, true, true },
        .color = .{ .r = 100, .g = 150, .b = 230, .a = 255 },
    },
};

fn update(f: *z.Frame, state: *State) void {
    _ = state.scratch.reset(.retain_capacity);
    state.frame_count += 1;

    const w: f32 = f.window.widthf();
    const mp: Vec2 = z.getMousePosition(f.input);
    const click: bool = z.isMouseButtonPressed(f.input, .left);

    const button_x: f32 = 40;
    const button_w: f32 = w - 80;
    const button_y: f32 = 470;
    const button_h: f32 = 110;
    const in_button: bool = mp[0] >= button_x and mp[0] <= button_x + button_w and
        mp[1] >= button_y and mp[1] <= button_y + button_h;

    if ((click and in_button) or z.isKeyPressed(f.input, .space)) {
        state.playing = !state.playing;
        if (state.playing) {
            z.sounds.play(&state.audio.sounds, state.loop);
            state.play_started_at_frame = state.frame_count;
        } else {
            z.sounds.stop(&state.audio.sounds, state.loop);
        }
    }

    const total_ms: usize = steps_per_loop * step_ms;
    // The baked Wave plays once (Sound.play is one-shot); re-trigger when it
    // ends so the pattern loops continuously while "playing".
    if (state.playing) {
        const el: usize = (state.frame_count - state.play_started_at_frame) * 16;
        if (el >= total_ms) {
            z.sounds.play(&state.audio.sounds, state.loop);
            state.play_started_at_frame = state.frame_count;
        }
    }

    z.clearViewport(f, .{ .r = 20, .g = 22, .b = 28, .a = 255 });
    f.gl.text(.{ 16, 16 }, "8-step drum loop", .{ .size = 26, .color = c.white, .font = &state.font });
    f.gl.text(.{ 16, 50 }, "tap PLAY or press SPACE", .{ .size = 15, .color = c.slate_400, .font = &state.font });

    // Playhead step (loops with the audio; ~60fps frame->ms approximation).
    const elapsed_ms: usize = if (state.playing) (state.frame_count - state.play_started_at_frame) * 16 else 0;
    const cur_step: usize = if (state.playing)
        (elapsed_ms / step_ms) % steps_per_loop
    else
        steps_per_loop;

    const grid_x: f32 = 64;
    const grid_y: f32 = 110;
    const cell_w: f32 = (w - grid_x - 16) / float(steps_per_loop);
    const cell_h: f32 = 56;
    for (lanes, 0..) |lane, li| {
        const ly: f32 = grid_y + float(li) * (cell_h + 10);
        f.gl.text(.{ 12, ly + 18 }, lane.name, .{ .size = 16, .color = c.slate_300, .font = &state.font });
        for (lane.hits, 0..) |hit, step| {
            const cx: f32 = grid_x + float(step) * cell_w;
            const fill: Color = if (hit) lane.color else .{ .r = 40, .g = 42, .b = 52, .a = 255 };
            f.gl.rect(.{ .x = cx + 2, .y = ly, .width = cell_w - 6, .height = cell_h }, .{ .color = fill });
            if (step == cur_step) {
                f.gl.rect(
                    .{ .x = cx + 2, .y = ly, .width = cell_w - 6, .height = cell_h },
                    .{ .color = c.white, .outline = 1.0 },
                );
            }
        }
    }

    // PLAY / STOP button.
    const btn_fill: Color = if (state.playing) c.rose_500 else c.emerald_500;
    f.gl.rect(.{ .x = button_x, .y = button_y, .width = button_w, .height = button_h }, .{ .color = btn_fill });
    f.gl.rect(
        .{ .x = button_x, .y = button_y, .width = button_w, .height = button_h },
        .{ .color = c.white, .outline = 1.0 },
    );
    const label: []const u8 = if (state.playing) "STOP" else "PLAY";
    f.gl.text(
        .{ button_x + button_w / 2 - 38, button_y + button_h / 2 - 16 },
        label,
        .{ .size = 32, .color = c.white, .font = &state.font },
    );

    common.caption(f.gl, state.font, "composer.tone + composer.Sequence baked into one looping Wave");
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - composer drum",
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
