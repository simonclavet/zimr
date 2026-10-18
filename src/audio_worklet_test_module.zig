//! src/audio_worklet_test_module.zig - the module the audio worklet's program is tested against, in Node
//! (`zig build audio-worklet-test`, `tools/c2js_cases/audio_worklet_test.cjs`).
//!
//! In a browser the worklet runs a second instance of the app's own module, and the app's first instance - on the main
//! thread - sends it commands. This module plays both parts, as a small app would. The Node test instantiates it once
//! as the main thread's instance, whose test entry points make commands with a real `Mixer` and hand over their bytes;
//! and the worklet's program instantiates it again, through its renderer entry points (`worklet_abi`), exactly as it
//! does the app's module. So no test spells out the layout of a command: the bytes the worklet receives are the bytes a
//! mixer wrote.
//!
//!     Node test                         this module, first instance          this module, second instance
//!       play a sine, samples, a stream -> Mixer: commands queued
//!       forward                    -->    mixFrame: the platform's forwarding
//!                                         functions record each message
//!       the records, as messages   -------------------------------------->  the worklet's program: accepted
//!       process, 128 frames        -------------------------------------->  render: the block
//!       render the same locally    -->    a RendererHost here: the block
//!       the notices posted         -->    handed over at the next mixFrame (`take_notice_bytes`)
//!
//! The first instance's mixer forwards as a page's does: its output is a stand-in platform whose forwarding functions
//! record what they are given - each frame's commands in one batch, samples, notes, a stream's frames - so the test
//! runs the mixer's own forward (`forwardToOtherMemory`), its order and its batching, as a page does.
//!
//! The first instance also renders everything it forwards with a renderer host of its own, on its own memory: the
//! reference the worklet's blocks must equal, bit for bit.
//!
//! The module is built for `wasm32-freestanding` with no entry point, and with the `zm` module, which `sound.zig` uses.

const std = @import("std");
const sound = @import("sound.zig");
const contract = @import("platform/contract.zig");
const zm = @import("zm");
const sinTurns = zm.sinTurns;
const float = zm.float;
const asBytes = std.mem.asBytes;
const wasm_allocator = std.heap.wasm_allocator;

const mixer = sound.mixer;
const Mixer = mixer.Mixer;
const RendererHost = mixer.RendererHost;
const SamplesId = mixer.SamplesId;

/// A freestanding module has no output to log to: the mixer's warnings are dropped. The test checks what the mixer
/// does, not what it says. `args` is `anytype` because `std.Options.logFn` requires it: a message's arguments, of any
/// types.
fn dropLogMessage(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = level;
    _ = scope;
    _ = format;
    _ = args;
}
pub const std_options: std.Options = .{ .logFn = dropLogMessage };

/// The names this module's test entry points are exported under; the Node test calls them by these.
const test_abi = struct {
    const start = "zimr_audio_test_start";
    const play_sine = "zimr_audio_test_play_sine";
    const play_ramp = "zimr_audio_test_play_ramp";
    const forward = "zimr_audio_test_forward";
    const messages = "zimr_audio_test_messages";
    const sine_frames = "zimr_audio_test_sine_frames";
    const render_locally = "zimr_audio_test_render_locally";
    const notice_room = "zimr_audio_test_notice_room";
    const analysis_room = "zimr_audio_test_analysis_room";
    const set_clock = "zimr_audio_test_set_clock";
    const record_words_name = "zimr_audio_test_record_words";
    const newest_start = "zimr_audio_test_newest_start";
    const accept_notices = "zimr_audio_test_accept_notices";
    const is_playing = "zimr_audio_test_is_playing";
    const stop_voice = "zimr_audio_test_stop_voice";
    const set_instrument = "zimr_audio_test_set_instrument";
    const set_shepard_instrument = "zimr_audio_test_set_shepard_instrument";
    const send_note = "zimr_audio_test_send_note";
    const play_stream = "zimr_audio_test_play_stream";
    const feed_stream = "zimr_audio_test_feed_stream";
    const notice_byte_count = "zimr_audio_test_notice_byte_count";
};

// ---- The sounds ----

/// The sine generator the test plays: a mono tone at half volume, its frequency the voice's state. A generator is a
/// function pointer, which the play command carries as an index in the module's table - the same index in both
/// instances, so the worklet's instance calls this same function.
fn generateSine(state: *anyopaque, frames: []f32, first_frame: u64) void {
    const frequency: *const f32 = @ptrCast(@alignCast(state));
    const rate: f32 = float(mixer.sample_rate);
    const frame_count: usize = frames.len / mixer.channel_count;
    for (0..frame_count) |frame_offset| {
        const frame_number: f32 = float(first_frame + frame_offset);
        const phase_turns: f32 = frequency.* * frame_number / rate;
        const value: f32 = 0.5 * sinTurns(phase_turns);
        frames[frame_offset * mixer.channel_count] = value;
        frames[frame_offset * mixer.channel_count + 1] = value;
    }
}

/// The ramp the test plays: 960 mono samples recorded at 24 000 Hz, so 1 920 frames at the mixer's 48 000 - fifteen
/// quanta of 128 - after which the buffer ends and its voice with it. Each sample is its index over 2 048, so every
/// value, and every value halfway between two of them, is exact in a float.
const ramp_sample_count: usize = 960;
const ramp_sample_rate: u32 = 24_000;
fn rampSamples() [ramp_sample_count]f32 {
    @setEvalBranchQuota(ramp_sample_count * 4);
    var ramp_values: [ramp_sample_count]f32 = undefined;
    for (&ramp_values, 0..) |*ramp_sample, ramp_index| {
        ramp_sample.* = float(ramp_index) / 2048;
    }
    return ramp_values;
}
const ramp: [ramp_sample_count]f32 = rampSamples();

// ---- What the main side forwards ----

/// What a forwarded message carries (`ForwardedMessage.kind`), numbered as the Node tests read it from a record's
/// first word.
const ForwardedKind = enum(u32) {
    /// A frame's commands' bytes.
    commands = 0,
    /// Samples to register under an id.
    samples = 1,
    /// A key's event.
    note = 2,
    /// A stream's frames.
    stream_frames = 3,
};

/// The three times of a measured start (`testNewestStart`), numbered as the Node test asks for them: when it was
/// requested, when the block that started it was asked for, and when that block's first frame went out.
const StartTime = enum(u32) {
    requested = 0,
    applied = 1,
    first_frame_out = 2,
};

/// One message's worth of what the main side forwarded, as the Node test reads it from this instance's memory: a
/// frame's commands, samples to register, a key's event, or a stream's frames. Its addresses are in this instance's
/// memory.
const ForwardedMessage = extern struct {
    kind: ForwardedKind,
    /// The samples' id, or the stream's number; unused otherwise.
    samples_id: u32 = 0,
    /// Where the commands' bytes, the samples or the stream's frames are; unused for a note.
    address: u32 = 0,
    byte_count: u32 = 0,
    /// A note's key, 1 for down or 0 for up, and velocity; for a stream's frames, their channels in `note_key`.
    note_key: u32 = 0,
    note_is_down: u32 = 0,
    note_velocity: f32 = 0,
    /// A stream's frames' rate; unused otherwise.
    stream_sample_rate: u32 = 0,
    /// A note's times, which the Node test sends with it: when it was requested, and when its key was pressed.
    note_requested_at_ms: f32 = 0,
    note_pressed_at_ms: f32 = 0,
};

/// How many 32-bit words a forwarded message's record takes (`ForwardedMessage`), for the Node tests to read the
/// records by (`testRecordWords`).
const record_words: usize = @sizeOf(ForwardedMessage) / 4;

/// The most messages one forward holds: far more than the test sends at once.
const forwarded_capacity: usize = 64;

/// What the test entry points share - a module's exported functions can share state only through a global.
const MainSideState = struct {
    main_side: Mixer = .{},
    /// The reference: a renderer host in this instance, sent everything the worklet is sent.
    local_host: RendererHost = .{},
    /// The messages forwarded since the Node test last took them, and those it took last (`testForward`).
    forwarded: [forwarded_capacity]ForwardedMessage = undefined,
    forwarded_count: usize = 0,
    taken: [forwarded_capacity]ForwardedMessage = undefined,
    /// The commands' bytes, batch after batch, kept here for the Node test to read.
    command_bytes: [forwarded_capacity * mixer.worklet_abi.command_byte_count]u8 = undefined,
    command_bytes_used: usize = 0,
    /// The notices' bytes the Node test copied into `notice_room`, and those handed to the mixer so far.
    notice_byte_count_waiting: usize = 0,
    notice_byte_count_handed: usize = 0,
    /// The stream the test plays: a mono ring of 2 048 frames, the sine's frequency, and its frames written so far.
    stream_ring_samples: [2048]f32 = undefined,
    stream_ring: mixer.StreamRing = undefined,
    stream_frequency: f32 = 0,
    stream_frames_written: u64 = 0,
    /// The sine generator's own frames, for the test to compare the worklet's with.
    sine_frames: [mixer.render_block_most_frames * mixer.channel_count]f32 = undefined,
    /// Where the Node test copies the notices the worklet posted.
    notice_room: [64 * mixer.worklet_abi.notice_byte_count]u8 = undefined,
    /// Where page audio copies an analyser's frames, as a page's platform asks it to (`takeAudioAnalysisFrames`).
    analysis_room: [mixer.worklet_abi.analysis_frame_count]f32 = undefined,
    /// The main side's clock, as the test sets it (`testSetClock`): the time its requests are stamped with.
    clock_ms: f64 = 0,
};
// lint:off module-var: the test module's one state - its exported functions can share nothing else
var main_side_state: MainSideState = .{};

/// The stand-in output the mixer starts on: a platform that forwards, as a page with its worklet loaded does. Its
/// forwarding functions record each message for the Node test (`ForwardedMessage`) and hand the same to the local host,
/// the reference; its notices are those the Node test copied in (`testAcceptNotices`). Nothing pulls: the worklet
/// renders.
const stand_in_output = struct {
    /// Never called: the forwarding starts, and a mixer that forwards does not pull.
    fn startPulling(wanted: contract.AudioFormat, render_callback: contract.AudioRenderCallback) contract.AudioFormat {
        _ = render_callback;
        return wanted;
    }

    fn startForwarding(wanted: contract.AudioFormat) ?contract.AudioFormat {
        return wanted;
    }

    /// The test's clock (`testSetClock`): 0, which stamps nothing, until a test sets it.
    fn clockMilliseconds() f64 {
        return main_side_state.clock_ms;
    }

    fn name() []const u8 {
        return "the worklet test's stand-in";
    }

    fn stop() void {}

    /// Adds `message` to the messages forwarded since the Node test last took them (`testForward`).
    fn record(message: ForwardedMessage) void {
        const state: *MainSideState = &main_side_state;
        zm.assert(state.forwarded_count < forwarded_capacity, @src());
        state.forwarded[state.forwarded_count] = message;
        state.forwarded_count += 1;
    }

    /// A frame's commands, one after another: kept for the Node test, and each given to the local host.
    fn recordCommandBytes(command_bytes: []const u8) void {
        const state: *MainSideState = &main_side_state;
        const kept_bytes: []u8 = state.command_bytes[state.command_bytes_used..][0..command_bytes.len];
        @memcpy(kept_bytes, command_bytes);
        state.command_bytes_used += command_bytes.len;
        record(.{
            .kind = .commands,
            .address = @intCast(@intFromPtr(kept_bytes.ptr)),
            .byte_count = @intCast(command_bytes.len),
        });
        const command_byte_count: usize = mixer.worklet_abi.command_byte_count;
        var command_start: usize = 0;
        while (command_start < command_bytes.len) : (command_start += command_byte_count) {
            state.local_host.acceptCommandBytes(command_bytes[command_start..][0..command_byte_count]);
        }
    }

    fn recordSamples(samples_id: SamplesId, samples: []const f32) void {
        record(.{
            .kind = .samples,
            .samples_id = samples_id,
            .address = @intCast(@intFromPtr(samples.ptr)),
            .byte_count = @intCast(samples.len * @sizeOf(f32)),
        });
        main_side_state.local_host.acceptSamples(samples_id, samples) catch {
            zm.assertUnreachable(@src(), "the local host had no room for samples {d}", .{samples_id});
        };
    }

    fn recordNote(
        key: u8,
        is_down: bool,
        velocity: f32,
        requested_at_ms: f64,
        pressed_at_ms: f64,
    ) void {
        record(.{
            .kind = .note,
            .note_key = key,
            .note_is_down = @intFromBool(is_down),
            .note_velocity = velocity,
            .note_requested_at_ms = @floatCast(requested_at_ms),
            .note_pressed_at_ms = @floatCast(pressed_at_ms),
        });
        const note_event: mixer.NoteEvent = .{ .key = key, .is_down = is_down, .velocity = velocity };
        const is_queued: bool = main_side_state.local_host.acceptNote(note_event);
        zm.assert(is_queued, @src());
    }

    /// A stream's frames: where they lie in the game's ring, which the Node test copies from before the ring is
    /// written again.
    fn recordStreamFrames(
        stream_id: u8,
        channels: u8,
        frames_per_second: u32,
        frames: []const f32,
    ) void {
        record(.{
            .kind = .stream_frames,
            .samples_id = stream_id,
            .address = @intCast(@intFromPtr(frames.ptr)),
            .byte_count = @intCast(frames.len * @sizeOf(f32)),
            .note_key = channels,
            .stream_sample_rate = frames_per_second,
        });
        const stream: mixer.ForwardedStream = .{
            .id = stream_id,
            .channels = channels,
            .sample_rate = frames_per_second,
        };
        main_side_state.local_host.acceptStreamFrames(stream, frames);
    }

    /// The notices the Node test copied in and has not had read yet: as many whole ones as fit, once each.
    fn takeNoticeBytes(notice_bytes: []u8, notice_byte_count: usize) usize {
        const state: *MainSideState = &main_side_state;
        const waiting_byte_count: usize = state.notice_byte_count_waiting - state.notice_byte_count_handed;
        const room_byte_count: usize = notice_bytes.len - notice_bytes.len % notice_byte_count;
        const handed_byte_count: usize = @min(waiting_byte_count, room_byte_count);
        const handed_bytes: []const u8 = state.notice_room[state.notice_byte_count_handed..][0..handed_byte_count];
        @memcpy(notice_bytes[0..handed_byte_count], handed_bytes);
        state.notice_byte_count_handed += handed_byte_count;
        return handed_byte_count;
    }

    const output: mixer.Output = .{
        .start_pulling = &startPulling,
        .clock_ms = &clockMilliseconds,
        .latency_ms = &clockMilliseconds,
        .name = &name,
        .stop = &stop,
        .forwarding = .{
            .start = &startForwarding,
            .send_command_bytes = &recordCommandBytes,
            .send_samples = &recordSamples,
            .send_note = &recordNote,
            .take_notice_bytes = &takeNoticeBytes,
            .send_stream_frames = &recordStreamFrames,
        },
    };
};

// ---- The test entry points ----

/// Starts the mixer on the stand-in output and the local host: 1 when both could, 0 when memory ran out.
fn testStart() callconv(.c) u32 {
    const state: *MainSideState = &main_side_state;
    state.main_side.start(wasm_allocator, stand_in_output.output) catch return 0;
    state.local_host.start(wasm_allocator) catch return 0;
    return 1;
}

/// Plays the sine at `frequency`, centred; returns the voice's name.
fn testPlaySine(frequency: f32) callconv(.c) u32 {
    const sine_source: mixer.Source = .{ .generator = .{
        .generate = &generateSine,
        .initial_state = asBytes(&frequency),
    } };
    const voice: mixer.Voice = main_side_state.main_side.play(sine_source, .{});
    return @backingInt(voice);
}

/// Plays the ramp, centred; returns the voice's name. Its first play registers the samples.
fn testPlayRamp() callconv(.c) u32 {
    const ramp_source: mixer.Source = .{ .samples = .{
        .samples = &ramp,
        .channels = 1,
        .sample_rate = ramp_sample_rate,
    } };
    const voice: mixer.Voice = main_side_state.main_side.play(ramp_source, .{});
    return @backingInt(voice);
}

/// Runs the main side's frame (`Mixer.mixFrame`) - its forward, as a page's frame runs it - and takes every message
/// forwarded since the last call: this frame's, and any an earlier frame made (`testAcceptNotices` runs one). Says how
/// many; `testMessages` holds them, until the next call - the commands' bytes they point at are written over by the
/// frames after.
fn testForward() callconv(.c) u32 {
    const state: *MainSideState = &main_side_state;
    state.main_side.mixFrame();
    const taken_count: usize = state.forwarded_count;
    @memcpy(state.taken[0..taken_count], state.forwarded[0..taken_count]);
    state.forwarded_count = 0;
    state.command_bytes_used = 0;
    return @intCast(taken_count);
}

/// The address of the last forward's messages, `ForwardedMessage`s of 32 bytes each.
fn testMessages() callconv(.c) usize {
    return @intFromPtr(&main_side_state.taken);
}

/// Writes the sine generator's own `frame_count` frames at `frequency`, from frame `first_frame`, and returns their
/// address: interleaved stereo.
fn testSineFrames(frequency: f32, first_frame: u32, frame_count: u32) callconv(.c) usize {
    var sine_state: f32 = frequency;
    const sample_count: usize = @as(usize, frame_count) * mixer.channel_count;
    const sine_frames: []f32 = main_side_state.sine_frames[0..sample_count];
    generateSine(&sine_state, sine_frames, first_frame);
    return @intFromPtr(sine_frames.ptr);
}

/// Renders the next `frame_count` frames on the local host and returns their address, one channel after the other,
/// as the worklet's entry point returns them.
fn testRenderLocally(frame_count: u32) callconv(.c) usize {
    const interleaved: []const f32 = main_side_state.local_host.render(frame_count);
    const channel_samples: []f32 = main_side_state.sine_frames[0..interleaved.len];
    for (0..frame_count) |frame_index| {
        channel_samples[frame_index] = interleaved[frame_index * mixer.channel_count];
        channel_samples[frame_count + frame_index] = interleaved[frame_index * mixer.channel_count + 1];
    }
    return @intFromPtr(channel_samples.ptr);
}

/// Where the Node test copies the notices the worklet posted, before `testAcceptNotices`.
fn testNoticeRoom() callconv(.c) usize {
    return @intFromPtr(&main_side_state.notice_room);
}

/// Where page audio copies an analyser's frames in the page test (`page_audio.takeAnalysisFrames`).
fn testAnalysisRoom() callconv(.c) usize {
    return @intFromPtr(&main_side_state.analysis_room);
}

/// How many 32-bit words each record of `testMessages` takes (`record_words`).
fn testRecordWords() callconv(.c) u32 {
    return record_words;
}

/// Sets the main side's clock to `clock_ms`: the requests made from then on are stamped with it.
fn testSetClock(clock_ms: f64) callconv(.c) void {
    main_side_state.clock_ms = clock_ms;
}

/// One time of the newest start the main side holds measured (`Mixer.recentStarts`), `which` of its three; -1 when
/// none is held.
fn testNewestStart(which: StartTime) callconv(.c) f64 {
    var newest: [1]mixer.LatencySample = undefined;
    const held: []mixer.LatencySample = main_side_state.main_side.recentStarts(&newest);
    if (held.len == 0) {
        return -1;
    }
    return switch (which) {
        .requested => held[0].requested_at_ms,
        .applied => held[0].applied_at_ms,
        .first_frame_out => held[0].first_frame_out_ms,
    };
}

/// Hands the main side the `byte_count` bytes of notices copied in, as a page's platform hands those of a message:
/// at the next frame, which takes them (`take_notice_bytes`) and reads them - run here. What that frame forwards waits
/// for the next `testForward`.
fn testAcceptNotices(byte_count: u32) callconv(.c) void {
    const state: *MainSideState = &main_side_state;
    state.notice_byte_count_waiting = byte_count;
    state.notice_byte_count_handed = 0;
    state.main_side.mixFrame();
}

/// Sets the sine instrument (`mixer.sine_instrument`), for the notes that follow.
fn testSetInstrument() callconv(.c) void {
    main_side_state.main_side.setInstrument(mixer.sine_instrument);
}

/// Sets the Shepard instrument (`mixer.shepard_instrument`), for the notes that follow - the scale stars' instrument,
/// which the test's long session plays.
fn testSetShepardInstrument() callconv(.c) void {
    main_side_state.main_side.setInstrument(mixer.shepard_instrument);
}

/// Sends a key's event on the main side, as an app reading its keys at the frame does: 1 when queued.
fn testSendNote(key: u32, is_down: u32, velocity: f32) callconv(.c) u32 {
    const note_event: mixer.NoteEvent = .{ .key = @intCast(key), .is_down = is_down != 0, .velocity = velocity };
    return @intFromBool(main_side_state.main_side.sendNote(note_event));
}

/// Writes the stream's sine into its ring from where it left off, as many frames as the ring has room for - room the
/// worklet's reports give back - and says how many: as an app's stream table refills its rings each frame.
fn testFeedStream() callconv(.c) u32 {
    const state: *MainSideState = &main_side_state;
    var sine_frames: [2048]f32 = undefined;
    const room_frames: usize = @min(state.stream_ring.freeFrames(), sine_frames.len);
    const rate: f32 = float(mixer.sample_rate);
    for (sine_frames[0..room_frames], 0..) |*frame, frame_offset| {
        const frame_number: f32 = float(state.stream_frames_written + frame_offset);
        frame.* = 0.5 * sinTurns(state.stream_frequency * frame_number / rate);
    }
    const written_frames: usize = state.stream_ring.write(sine_frames[0..room_frames]);
    state.stream_frames_written += written_frames;
    return @intCast(written_frames);
}

/// Plays a stream on the main side: a mono ring of 2 048 frames at the mixer's rate, filled with a sine at
/// `frequency`. Returns the voice's name.
fn testPlayStream(frequency: f32) callconv(.c) u32 {
    const state: *MainSideState = &main_side_state;
    state.stream_frequency = frequency;
    state.stream_frames_written = 0;
    state.stream_ring = .initOver(&state.stream_ring_samples, 1, mixer.sample_rate);
    _ = testFeedStream();
    const voice: mixer.Voice = state.main_side.play(.{ .stream = .{ .ring = &state.stream_ring } }, .{});
    return @backingInt(voice);
}

/// 1 while the voice named `voice_bits` plays, as the main side knows it.
fn testIsPlaying(voice_bits: u32) callconv(.c) u32 {
    const voice: mixer.Voice = @fromBackingInt(voice_bits);
    return @intFromBool(main_side_state.main_side.isPlaying(voice));
}

/// Stops the voice `voice_bits` on the main side - forwarded, as every command, at the next `forward`.
fn testStopVoice(voice_bits: u32) callconv(.c) void {
    const voice: mixer.Voice = @fromBackingInt(voice_bits);
    main_side_state.main_side.stopVoice(voice);
}

/// A renderer notice's size in bytes, as both sides lay notices out (`worklet_abi.notice_byte_count`): the Node test
/// passes it to the page's `takeNoticeBytes`, rather than a number of its own that would go stale as the notices grow.
fn testNoticeByteCount() callconv(.c) u32 {
    return mixer.worklet_abi.notice_byte_count;
}

comptime {
    mixer.exportWorkletEntryPoints();
    @export(&testStart, .{ .name = test_abi.start });
    @export(&testPlaySine, .{ .name = test_abi.play_sine });
    @export(&testPlayRamp, .{ .name = test_abi.play_ramp });
    @export(&testForward, .{ .name = test_abi.forward });
    @export(&testMessages, .{ .name = test_abi.messages });
    @export(&testSineFrames, .{ .name = test_abi.sine_frames });
    @export(&testRenderLocally, .{ .name = test_abi.render_locally });
    @export(&testNoticeRoom, .{ .name = test_abi.notice_room });
    @export(&testAnalysisRoom, .{ .name = test_abi.analysis_room });
    @export(&testSetClock, .{ .name = test_abi.set_clock });
    @export(&testRecordWords, .{ .name = test_abi.record_words_name });
    @export(&testNewestStart, .{ .name = test_abi.newest_start });
    @export(&testAcceptNotices, .{ .name = test_abi.accept_notices });
    @export(&testIsPlaying, .{ .name = test_abi.is_playing });
    @export(&testSetInstrument, .{ .name = test_abi.set_instrument });
    @export(&testSetShepardInstrument, .{ .name = test_abi.set_shepard_instrument });
    @export(&testStopVoice, .{ .name = test_abi.stop_voice });
    @export(&testSendNote, .{ .name = test_abi.send_note });
    @export(&testPlayStream, .{ .name = test_abi.play_stream });
    @export(&testFeedStream, .{ .name = test_abi.feed_stream });
    @export(&testNoticeByteCount, .{ .name = test_abi.notice_byte_count });
}
