//! music_streaming — port of the GL `music_streaming`: stream an embedded
//! OGG (~2.3 MB, 96 s stereo Vorbis) on the wgpu audio bridge. `music.loadFromMemory`
//! kicks off the browser's async `decodeAudioData` (the `js_audio_decode_ogg_bytes`
//! path implemented this turn); `isReady` flips true a few frames later. Tap PLAY
//! to play/stop the looping track; tap the bar to seek. A progress bar tracks
//! the playhead. No per-frame pump — the decoded buffer loops in Web Audio.
const std = @import("std");
const allocPrint = std.fmt.allocPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Vec2 = zm.Vec2;
const Color = zm.Color;

const clamp = zm.clamp;
const co = @import("example_common");
const c = z.colors;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
const sample_ogg = @embedFile("sample_ogg");

const State = struct {
    font: z.Font,
    scratch: std.heap.ArenaAllocator,
    audio: z.AudioState = .{},
    track: z.Music = .{},
    play_requested: bool = false,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.scratch.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    z.audio_device.init(f.audio_device);
    var audio: z.AudioState = .{};
    // Kicks off async decodeAudioData; isReady is false until it resolves.
    const m: z.Music = try z.music.loadFromMemory(&audio.music, f.audio_device, &audio.waves, gpa, ".ogg", sample_ogg);
    z.music.setLooping(&audio.music, m, true);
    z.music.setVolume(&audio.music, m, 0.5);
    s.* = .{
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 28),
        .scratch = std.heap.ArenaAllocator.init(gpa),
        .audio = audio,
        .track = m,
    };
}

const bar_x: f32 = 32;
const bar_y: f32 = 300;
const bar_h: f32 = 34;
const btn_y: f32 = 430;
const btn_h: f32 = 110;

fn update(f: *z.Frame, s: *State) void {
    _ = s.scratch.reset(.retain_capacity);
    const w: f32 = f.window.widthf();
    const bar_w: f32 = w - bar_x * 2;
    const btn_x: f32 = 40;
    const btn_w: f32 = w - 80;

    const mp: Vec2 = z.getMousePosition(f.input);
    const click: bool = z.isMouseButtonPressed(f.input, .left);
    const ready: bool = z.music.isReady(&s.audio.music, s.track);

    // PLAY / STOP.
    const in_btn: bool = mp[0] >= btn_x and mp[0] <= btn_x + btn_w and mp[1] >= btn_y and mp[1] <= btn_y + btn_h;
    if (ready and click and in_btn) {
        if (s.play_requested) {
            z.music.stop(&s.audio.music, s.track);
            s.play_requested = false;
        } else {
            z.music.play(&s.audio.music, s.track);
            s.play_requested = true;
        }
    }

    const total_s: f32 = z.music.getTimeLength(&s.audio.music, s.track);
    // Tap the bar to seek.
    const in_bar: bool = mp[0] >= bar_x and mp[0] <= bar_x + bar_w and
        mp[1] >= bar_y - 12 and mp[1] <= bar_y + bar_h + 12;
    if (ready and click and in_bar and total_s > 0) {
        const target: f32 = clamp((mp[0] - bar_x) / bar_w, 0, 1) * total_s;
        z.music.seek(&s.audio.music, s.track, target);
        if (!s.play_requested) {
            z.music.play(&s.audio.music, s.track);
            s.play_requested = true;
        }
    }

    z.clearViewport(f, .{ .r = 24, .g = 26, .b = 32, .a = 255 });
    f.gl.text(.{ 16, 16 }, "streaming OGG", .{ .size = 26, .color = c.white, .font = &s.font });
    f.gl.text(.{ 16, 50 }, "tap PLAY - tap the bar to seek", .{ .size = 14, .color = c.slate_400, .font = &s.font });

    if (!ready) {
        f.gl.text(
            .{ bar_x, 180 },
            "decoding... (decodeAudioData)",
            .{ .size = 18, .color = c.amber_400, .font = &s.font },
        );
    } else {
        const info: []const u8 = allocPrint(s.scratch.allocator(), "{d} Hz - {d} ch - {d:.0}s", .{
            s.track.stream.sampleRate, s.track.stream.channels, total_s,
        }) catch "track";
        f.gl.text(.{ bar_x, 180 }, info, .{ .size = 18, .color = c.slate_300, .font = &s.font });
    }

    // Progress bar.
    const cur_s: f32 = z.music.getTimePlayed(&s.audio.music, s.track);
    const progress: f32 = if (total_s > 0) clamp(cur_s / total_s, 0, 1) else 0;
    f.gl.rect(
        .{ .x = bar_x, .y = bar_y, .width = bar_w, .height = bar_h },
        .{ .color = .{ .r = 50, .g = 54, .b = 64, .a = 255 } },
    );
    f.gl.rect(.{ .x = bar_x, .y = bar_y, .width = bar_w * progress, .height = bar_h }, .{ .color = c.sky_400 });
    f.gl.rect(.{ .x = bar_x, .y = bar_y, .width = bar_w, .height = bar_h }, .{ .color = c.slate_600, .outline = 1.0 });

    const tstr: []const u8 = allocPrint(
        s.scratch.allocator(),
        "{d:.0}s / {d:.0}s",
        .{ cur_s, total_s },
    ) catch "0";
    f.gl.text(.{ bar_x, bar_y + bar_h + 12 }, tstr, .{ .size = 16, .color = c.slate_300, .font = &s.font });

    // Button.
    const fill: Color = if (s.play_requested) c.rose_500 else if (ready) c.emerald_500 else c.slate_700;
    f.gl.rect(.{ .x = btn_x, .y = btn_y, .width = btn_w, .height = btn_h }, .{ .color = fill });
    f.gl.rect(.{ .x = btn_x, .y = btn_y, .width = btn_w, .height = btn_h }, .{ .color = c.white, .outline = 1.0 });
    const label: []const u8 = if (!ready) "..." else if (s.play_requested) "STOP" else "PLAY";
    f.gl.text(
        .{ btn_x + btn_w / 2 - 36, btn_y + btn_h / 2 - 16 },
        label,
        .{ .size = 32, .color = c.white, .font = &s.font },
    );

    co.caption(f.gl, s.font, "music.loadFromMemory -> async decodeAudioData -> looping playback");
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - music streaming",
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
