//! audio_stream_synth — port of the GL `audio_stream_synth`: a theremin on
//! the wgpu audio bridge. Mouse Y maps (logarithmically) to a pitch in
//! 110–1760 Hz; each frame it synthesizes sine samples and feeds them to an
//! `AudioStream` — a 3-buffer rotation scheduled gaplessly via the bridge's
//! `play_buffer_at` (implemented this turn). Click toggles the sound. The synth
//! phase_turns persists across chunks so the wave doesn't click at chunk seams.
const std = @import("std");
const allocPrint = std.fmt.allocPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const sinTurns = zm.sinTurns;
const Vec2 = zm.Vec2;

const float = zm.float;
const clamp = zm.clamp;
const common = @import("example_common");
const c = z.colors;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const sample_rate: u32 = 48000;
const frames_per_push: usize = 480;

const State = struct {
    font: z.Font,
    scratch: std.heap.ArenaAllocator,
    audio: z.AudioState = .{},
    stream: z.AudioStream = .{},
    phase_turns: f32 = 0.0,
    enabled: bool = false,
    frame_count: usize = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    z.streams.unload(&s.audio.streams, s.stream);
    s.scratch.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    z.audio_device.init(f.audio_device);
    var audio: z.AudioState = .{};
    const stream: z.AudioStream = z.streams.load(&audio.streams, f.audio_device, sample_rate, 32, 2);
    z.streams.setVolume(&audio.streams, stream, 0.3);
    z.streams.pause(&audio.streams, stream); // silent until the user holds
    s.* = .{
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 28),
        .scratch = std.heap.ArenaAllocator.init(gpa),
        .audio = audio,
        .stream = stream,
    };
}

/// Mouse Y → frequency in [110, 1760] Hz (4 octaves of A), logarithmic so equal
/// pixel-spans give equal musical intervals.
fn mouseToFreq(mouse_y: f32, height: f32) f32 {
    const min_freq: f32 = 110.0;
    const max_freq: f32 = 1760.0;
    const t: f32 = clamp(1.0 - mouse_y / height, 0.0, 1.0);
    const log_min: f32 = @log2(min_freq);
    const log_max: f32 = @log2(max_freq);
    return @exp2(log_min + t * (log_max - log_min));
}

fn update(f: *z.Frame, state: *State) void {
    _ = state.scratch.reset(.retain_capacity);
    state.frame_count += 1;
    const h: f32 = f.window.heightf();
    const mp: Vec2 = z.getMousePosition(f.input);

    // Hold-to-play (theremin): sound while the finger/button is held, silent on
    // release — so lifting your finger stops it.
    const down: bool = z.isMouseButtonDown(f.input, .left);
    if (down and !state.enabled) {
        state.enabled = true;
        z.streams.resumeStream(&state.audio.streams, state.stream);
    } else if (!down and state.enabled) {
        state.enabled = false;
        z.streams.pause(&state.audio.streams, state.stream);
    }

    // Top up the stream while the scheduler wants data (≈ one chunk/frame).
    if (state.enabled) {
        const freq: f32 = mouseToFreq(mp[1], h);
        const phase_step_turns: f32 = freq / float(sample_rate);
        var pushes: u8 = 0;
        while (z.streams.isProcessed(&state.audio.streams, state.stream) and pushes < 4) : (pushes += 1) {
            const samples = state.scratch.allocator().alloc(f32, frames_per_push * 2) catch return;
            for (0..frames_per_push) |i| {
                // `state.phase_turns` is already a turn count on [0, 1), so `sinTurns` takes it
                // directly. Measured over one cycle at 48 kHz: 4.11e-7 of error becomes 1.04e-7,
                // and every whole turn lands on exactly zero instead of drifting.
                const v: f32 = sinTurns(state.phase_turns);
                samples[i * 2 + 0] = v;
                samples[i * 2 + 1] = v;
                state.phase_turns += phase_step_turns;
                if (state.phase_turns >= 1.0) {
                    state.phase_turns -= 1.0;
                }
            }
            z.streams.update(&state.audio.streams, state.stream, samples);
        }
    }

    z.clearViewport(f, .{ .r = 16, .g = 16, .b = 24, .a = 255 });
    // Pitch bar tracking the cursor's Y.
    f.gl.line(
        .{ 0, mp[1] },
        .{ f.window.widthf(), mp[1] },
        .{ .color = if (state.enabled) c.amber_400 else c.slate_600, .thickness = 1.0 },
    );
    f.gl.circle(mp, 7, .{ .color = if (state.enabled) c.white else c.slate_500, .segments = 16 });

    const hud: []const u8 = allocPrint(
        state.scratch.allocator(),
        "freq: {d:.1} Hz  ({s})",
        .{ mouseToFreq(mp[1], h), if (state.enabled) "ON" else "OFF" },
    ) catch "freq";
    f.gl.text(.{ 16, 16 }, "theremin", .{ .size = 28, .color = c.white, .font = &state.font });
    f.gl.text(.{ 16, 52 }, hud, .{ .size = 16, .color = c.amber_300, .font = &state.font });
    f.gl.text(
        .{ 16, 78 },
        "hold + move to play - release to stop",
        .{ .size = 14, .color = c.slate_400, .font = &state.font },
    );

    common.caption(f.gl, state.font, "AudioStream: live sine fed gaplessly via play_buffer_at");
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - audio stream synth",
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
