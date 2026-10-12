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
//!       play a sine, play samples  -->    Mixer: commands queued
//!       forward                    -->    forwardCommands: bytes, records
//!       the records, as messages   -------------------------------------->  the worklet's program: accepted
//!       process, 128 frames        -------------------------------------->  render: the block
//!       render the same locally    -->    a RendererHost here: the block
//!       the notices posted         -->    acceptNotices, then mixFrame reads them
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
    const accept_notices = "zimr_audio_test_accept_notices";
    const is_playing = "zimr_audio_test_is_playing";
    const set_instrument = "zimr_audio_test_set_instrument";
    const send_note = "zimr_audio_test_send_note";
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

/// One message's worth of what `forwardCommands` handed over, as the Node test reads it from this instance's memory:
/// a command's bytes, or samples to register. Its addresses are in this instance's memory.
const ForwardedMessage = extern struct {
    /// 0 for a command, 1 for samples, 2 for a note.
    kind: u32,
    /// The samples' id; unused otherwise.
    samples_id: u32,
    /// Where the command's bytes, or the samples, are; unused for a note.
    address: u32,
    byte_count: u32,
    /// A note's key, 1 for down or 0 for up, and velocity; unused otherwise.
    note_key: u32,
    note_is_down: u32,
    note_velocity: f32,
    unused: u32 = 0,
};
const forwarded_command_kind: u32 = 0;
const forwarded_samples_kind: u32 = 1;
const forwarded_note_kind: u32 = 2;
/// The most messages one forward holds: far more than the test sends at once.
const forwarded_capacity: usize = 64;

/// The stand-in output the mixer starts on: one that pulls, from a thread of its own, as the worklet does - so the
/// mixer never applies a command to its own renderer. Nothing calls the renderer it is handed: the worklet renders.
const stand_in_output = struct {
    fn startPulling(wanted: contract.AudioFormat, render_callback: contract.AudioRenderCallback) contract.AudioFormat {
        _ = render_callback;
        return wanted;
    }

    /// No clock: the test measures samples, not time; 0 stamps nothing.
    fn clockMilliseconds() f64 {
        return 0;
    }

    fn name() []const u8 {
        return "the worklet test's stand-in";
    }

    fn stop() void {}

    const output: mixer.Output = .{
        .start_pulling = &startPulling,
        .clock_ms = &clockMilliseconds,
        .latency_ms = &clockMilliseconds,
        .name = &name,
        .stop = &stop,
        .calls_renderer_from_another_thread = true,
    };
};

/// What the test entry points share - a module's exported functions can share state only through a global.
const MainSideState = struct {
    main_side: Mixer = .{},
    /// The reference: a renderer host in this instance, sent everything the worklet is sent.
    local_host: RendererHost = .{},
    forwarded: [forwarded_capacity]ForwardedMessage = undefined,
    forwarded_count: usize = 0,
    /// Each forwarded command's bytes, kept here for the Node test to read.
    command_bytes: [forwarded_capacity][mixer.worklet_abi.command_byte_count]u8 = undefined,
    /// The sine generator's own frames, for the test to compare the worklet's with.
    sine_frames: [mixer.render_block_most_frames * mixer.channel_count]f32 = undefined,
    /// Where the Node test copies the notices the worklet posted.
    notice_room: [64 * mixer.worklet_abi.notice_byte_count]u8 = undefined,
};
// lint:off module-var: the test module's one state - its exported functions can share nothing else
var main_side_state: MainSideState = .{};

/// The sink `forwardCommands` hands each command to: it records the command for the Node test and gives the same to
/// the local host.
const recording_sink = struct {
    fn sendCommandBytes(context: *anyopaque, command_bytes: []const u8) void {
        const state: *MainSideState = @ptrCast(@alignCast(context));
        const message_index: usize = state.forwarded_count;
        zm.assert(message_index < forwarded_capacity, @src());
        const kept_bytes: []u8 = &state.command_bytes[message_index];
        @memcpy(kept_bytes, command_bytes);
        state.forwarded[message_index] = .{
            .kind = forwarded_command_kind,
            .samples_id = 0,
            .address = @intCast(@intFromPtr(kept_bytes.ptr)),
            .byte_count = @intCast(command_bytes.len),
            .note_key = 0,
            .note_is_down = 0,
            .note_velocity = 0,
        };
        state.forwarded_count += 1;
        state.local_host.acceptCommandBytes(command_bytes);
    }

    fn sendSamples(
        context: *anyopaque,
        samples_id: SamplesId,
        samples: []const f32,
    ) void {
        const state: *MainSideState = @ptrCast(@alignCast(context));
        const message_index: usize = state.forwarded_count;
        zm.assert(message_index < forwarded_capacity, @src());
        state.forwarded[message_index] = .{
            .kind = forwarded_samples_kind,
            .samples_id = samples_id,
            .address = @intCast(@intFromPtr(samples.ptr)),
            .byte_count = @intCast(samples.len * @sizeOf(f32)),
            .note_key = 0,
            .note_is_down = 0,
            .note_velocity = 0,
        };
        state.forwarded_count += 1;
        state.local_host.acceptSamples(samples_id, samples) catch {
            zm.assertUnreachable(@src(), "the local host had no room for samples {d}", .{samples_id});
        };
    }

    fn sendNote(context: *anyopaque, note_event: mixer.NoteEvent) void {
        const state: *MainSideState = @ptrCast(@alignCast(context));
        const message_index: usize = state.forwarded_count;
        zm.assert(message_index < forwarded_capacity, @src());
        state.forwarded[message_index] = .{
            .kind = forwarded_note_kind,
            .samples_id = 0,
            .address = 0,
            .byte_count = 0,
            .note_key = note_event.key,
            .note_is_down = @intFromBool(note_event.is_down),
            .note_velocity = note_event.velocity,
        };
        state.forwarded_count += 1;
        const is_queued: bool = state.local_host.acceptNote(note_event);
        zm.assert(is_queued, @src());
    }
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

/// Forwards every command waiting, in order, and says how many messages it made (`testMessages` holds them).
fn testForward() callconv(.c) u32 {
    const state: *MainSideState = &main_side_state;
    state.forwarded_count = 0;
    const command_sink: mixer.CommandSink = .{
        .context = state,
        .send_command_bytes = &recording_sink.sendCommandBytes,
        .send_samples = &recording_sink.sendSamples,
        .send_note = &recording_sink.sendNote,
    };
    mixer.forwardCommands(&state.main_side, command_sink);
    return @intCast(state.forwarded_count);
}

/// The address of the last forward's messages, `ForwardedMessage`s of 32 bytes each.
fn testMessages() callconv(.c) usize {
    return @intFromPtr(&main_side_state.forwarded);
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

/// Hands the main side the `byte_count` bytes of notices copied in, as the main thread will hand those of a message
/// (`acceptNoticeBytes`), and reads them as the next frame does (`mixFrame`).
fn testAcceptNotices(byte_count: u32) callconv(.c) void {
    const notice_bytes: []const u8 = main_side_state.notice_room[0..byte_count];
    mixer.acceptNoticeBytes(&main_side_state.main_side, notice_bytes);
    main_side_state.main_side.mixFrame();
}

/// Sets the sine instrument (`mixer.sine_instrument`), for the notes that follow.
fn testSetInstrument() callconv(.c) void {
    main_side_state.main_side.setInstrument(mixer.sine_instrument);
}

/// Sends a key's event on the main side, as an app reading its keys at the frame does: 1 when queued.
fn testSendNote(key: u32, is_down: u32, velocity: f32) callconv(.c) u32 {
    const note_event: mixer.NoteEvent = .{ .key = @intCast(key), .is_down = is_down != 0, .velocity = velocity };
    return @intFromBool(main_side_state.main_side.sendNote(note_event));
}

/// 1 while the voice named `voice_bits` plays, as the main side knows it.
fn testIsPlaying(voice_bits: u32) callconv(.c) u32 {
    const voice: mixer.Voice = @fromBackingInt(voice_bits);
    return @intFromBool(main_side_state.main_side.isPlaying(voice));
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
    @export(&testAcceptNotices, .{ .name = test_abi.accept_notices });
    @export(&testIsPlaying, .{ .name = test_abi.is_playing });
    @export(&testSetInstrument, .{ .name = test_abi.set_instrument });
    @export(&testSendNote, .{ .name = test_abi.send_note });
}
