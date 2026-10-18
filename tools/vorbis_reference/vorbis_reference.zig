//! The engine's Vorbis decoder against stb_vorbis (`zig build vorbis-reference`): the sample both decode, compared
//! frame by frame. stb_vorbis is the reference: its decoding is the one most used outside libvorbis itself, and its
//! samples are a decoder's samples, not an encoder's - the same file, two decoders, the same frames to within the
//! order sums are taken in. A difference past that is a wrong sign, index or scale, as large as the signal.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const testing_allocator = std.testing.allocator;
const readInt = std.mem.readInt;
const codecs = @import("codecs");

/// stb_vorbis's decoder, as its header declares the four functions this test uses.
const StbVorbis = opaque {};

/// What stb_vorbis reports of a stream (`stb_vorbis_get_info`), its fields in its header's order.
const StbVorbisInfo = extern struct {
    sample_rate: c_uint,
    channels: c_int,
    setup_memory_required: c_uint,
    setup_temp_memory_required: c_uint,
    temp_memory_required: c_uint,
    max_frame_size: c_int,
};

extern fn stb_vorbis_open_memory(
    data: [*]const u8,
    len: c_int,
    error_code: *c_int,
    alloc_buffer: ?*anyopaque,
) ?*StbVorbis;
extern fn stb_vorbis_get_info(decoder: *StbVorbis) StbVorbisInfo;
extern fn stb_vorbis_get_samples_float_interleaved(
    decoder: *StbVorbis,
    channels: c_int,
    buffer: [*]f32,
    num_floats: c_int,
) c_int;
extern fn stb_vorbis_close(decoder: *StbVorbis) void;

/// How close the two decoders' samples must be: 1e-4, a hundred times the difference of sums taken in another order,
/// a thousandth of the quietest sound a listener hears at a normal level.
const tolerance: f32 = 1e-4;

/// A stream as stb_vorbis decodes it: its interleaved frames, and its channel count.
const StbFrames = struct {
    frames: []f32,
    channels: usize,
};

/// Decodes `bytes` whole with stb_vorbis.
fn decodeWithStb(allocator: Allocator, bytes: []const u8) !StbFrames {
    var error_code: c_int = 0;
    const stb: *StbVorbis = stb_vorbis_open_memory(bytes.ptr, @intCast(bytes.len), &error_code, null) orelse
        return error.StbCouldNotOpen;
    defer stb_vorbis_close(stb);
    const channels: usize = @intCast(stb_vorbis_get_info(stb).channels);
    var frames: ArrayListUnmanaged(f32) = .empty;
    errdefer frames.deinit(allocator);
    var buffer: [4096 * 8]f32 = undefined;
    const buffer_floats: usize = buffer.len / channels * channels;
    while (true) {
        const channel_count: c_int = @intCast(channels);
        const float_count: c_int = @intCast(buffer_floats);
        const frames_read: c_int = stb_vorbis_get_samples_float_interleaved(stb, channel_count, &buffer, float_count);
        if (frames_read <= 0) {
            break;
        }
        try frames.appendSlice(allocator, buffer[0 .. @as(usize, @intCast(frames_read)) * channels]);
    }
    return .{ .frames = try frames.toOwnedSlice(allocator), .channels = channels };
}

/// Decodes `bytes` whole with the engine's decoder: interleaved frames.
fn decodeWithEngine(allocator: Allocator, bytes: []const u8) ![]f32 {
    var decoder: codecs.audio.vorbis.Decoder = try .init(allocator, bytes);
    defer decoder.deinit();
    const channels: usize = decoder.channelCount();
    var frames: ArrayListUnmanaged(f32) = .empty;
    errdefer frames.deinit(allocator);
    var buffer: [4096 * 8]f32 = undefined;
    const buffer_floats: usize = buffer.len / channels * channels;
    while (true) {
        const frames_read: usize = try decoder.readFrames(buffer[0..buffer_floats]);
        if (frames_read == 0) {
            break;
        }
        try frames.appendSlice(allocator, buffer[0 .. frames_read * channels]);
    }
    return frames.toOwnedSlice(allocator);
}

test "the sample: every frame within 1e-4 of stb_vorbis's" {
    const allocator: Allocator = testing_allocator;
    const bytes: []const u8 = codecs.audio.ogg.sample_ogg;
    const stb: StbFrames = try decodeWithStb(allocator, bytes);
    defer allocator.free(stb.frames);
    const engine_frames: []f32 = try decodeWithEngine(allocator, bytes);
    defer allocator.free(engine_frames);
    const stb_frame_count: usize = stb.frames.len / stb.channels;
    const engine_frame_count: usize = engine_frames.len / stb.channels;
    const compared_count: usize = @min(stb.frames.len, engine_frames.len);
    var largest_difference: f32 = 0;
    var largest_at: usize = 0;
    var first_past_tolerance: ?usize = null;
    // The scale between the two, if one is off by a factor: the ratio of their sums of squares.
    var stb_power: f64 = 0;
    var engine_power: f64 = 0;
    var cross_power: f64 = 0;
    for (stb.frames[0..compared_count], engine_frames[0..compared_count], 0..) |reference, ours, index| {
        const difference: f32 = @abs(reference - ours);
        if (difference > largest_difference) {
            largest_difference = difference;
            largest_at = index;
        }
        if (difference > tolerance and first_past_tolerance == null) {
            first_past_tolerance = index;
        }
        stb_power += @as(f64, reference) * reference;
        engine_power += @as(f64, ours) * ours;
        cross_power += @as(f64, reference) * ours;
    }
    std.debug.print(
        "stb {d} frames, engine {d}; largest difference {e:.3} at sample {d}; first past 1e-4: {?d}; " ++
            "engine/stb amplitude {d:.6}, correlation {d:.6}\n",
        .{
            stb_frame_count,
            engine_frame_count,
            largest_difference,
            largest_at,
            first_past_tolerance,
            @sqrt(engine_power / stb_power),
            cross_power / @sqrt(stb_power * engine_power),
        },
    );
    try expectEqual(stb_frame_count, engine_frame_count);
    try expect(first_past_tolerance == null);
}

/// A stream of the corpus, and what its frames are held to: stb_vorbis's decoding of it, or for a stream stb_vorbis
/// decodes wrong, every `libvorbis_stride`th frame of libvorbis's own, kept beside it.
const CorpusStream = struct {
    name: []const u8,
    bytes: []const u8,
    /// Every `libvorbis_stride`th frame of libvorbis's decoding, interleaved little-endian f32 - libvorbis through
    /// libsndfile 1.2.2; null where stb_vorbis's decoding is the reference.
    libvorbis_strided: ?[]const u8 = null,
};

/// The stride of a stream's frames kept from libvorbis's decoding: 53, a prime, so that the frames kept fall at every
/// place within the blocks over the stream.
const libvorbis_stride: usize = 53;

/// Eight more streams, made for these comparisons by libvorbis through libsndfile 1.2.2, so that the sample's
/// settings are not the only ones the decoder is held to: mono, whose residue libvorbis lays out as type 1; a low
/// rate and a low quality; a high rate and a high quality; three, four and five channels, each its own vector; and
/// six channels, 5.1, its low-frequency channel a second submap with a floor of two points and a type 1 residue of
/// its own beside the type 2 of the other five. The first four are 2.6 seconds of a chord, a second chord, a noise
/// burst, a decaying pluck, silence and a rising sweep, each channel a little detuned; the multichannel ones shorter,
/// two tones and a burst. stb_vorbis decodes the six-channel stream wrong - its peaks reach 23 where libvorbis's and
/// ffmpeg's, which agree with each other and with the engine within 4e-7, stay under 0.9 - so it is held to
/// libvorbis's own decoding instead.
const corpus = [_]CorpusStream{
    .{ .name = "mono_44100", .bytes = @embedFile("corpus/mono_44100.ogg") },
    .{ .name = "mono_22050_low", .bytes = @embedFile("corpus/mono_22050_low.ogg") },
    .{ .name = "stereo_8000_low", .bytes = @embedFile("corpus/stereo_8000_low.ogg") },
    .{ .name = "stereo_48000_high", .bytes = @embedFile("corpus/stereo_48000_high.ogg") },
    .{ .name = "channels_3_44100", .bytes = @embedFile("corpus/channels_3_44100.ogg") },
    .{ .name = "channels_4_44100", .bytes = @embedFile("corpus/channels_4_44100.ogg") },
    .{ .name = "channels_5_44100", .bytes = @embedFile("corpus/channels_5_44100.ogg") },
    .{
        .name = "surround_6ch_48000",
        .bytes = @embedFile("corpus/surround_6ch_48000.ogg"),
        .libvorbis_strided = @embedFile("corpus/surround_6ch_48000.libvorbis_every_53.f32"),
    },
};

/// The largest difference between the engine's frames and the stream's reference - stb_vorbis's decoding, or the
/// frames kept from libvorbis's - and whether their frame counts agree.
const CorpusVerdict = struct {
    largest_difference: f32,
    is_count_equal: bool,
};

/// Holds `engine_frames` to `stream`'s reference (`CorpusStream`).
fn judgeCorpusStream(
    allocator: Allocator,
    stream: CorpusStream,
    engine_frames: []const f32,
    channels: usize,
) !CorpusVerdict {
    var largest_difference: f32 = 0;
    if (stream.libvorbis_strided) |strided_bytes| {
        const sample_count: usize = strided_bytes.len / 4;
        const kept_frames: usize = sample_count / channels;
        const engine_frame_count: usize = engine_frames.len / channels;
        for (0..kept_frames) |kept_index| {
            const frame: usize = kept_index * libvorbis_stride;
            if (frame >= engine_frame_count) {
                return .{ .largest_difference = largest_difference, .is_count_equal = false };
            }
            for (0..channels) |channel| {
                const offset: usize = (kept_index * channels + channel) * 4;
                const reference: f32 = @bitCast(readInt(u32, strided_bytes[offset..][0..4], .little));
                const engine_sample: f32 = engine_frames[frame * channels + channel];
                largest_difference = @max(largest_difference, @abs(reference - engine_sample));
            }
        }
        // The frames kept reach the stream's last stride: its frame count within one stride.
        const is_count_close: bool = engine_frame_count - (kept_frames - 1) * libvorbis_stride <= libvorbis_stride;
        return .{ .largest_difference = largest_difference, .is_count_equal = is_count_close };
    }
    const stb: StbFrames = try decodeWithStb(allocator, stream.bytes);
    defer allocator.free(stb.frames);
    const compared: usize = @min(stb.frames.len, engine_frames.len);
    for (stb.frames[0..compared], engine_frames[0..compared]) |stb_sample, engine_sample| {
        largest_difference = @max(largest_difference, @abs(stb_sample - engine_sample));
    }
    return .{ .largest_difference = largest_difference, .is_count_equal = stb.frames.len == engine_frames.len };
}

test "the corpus: every stream's frames within 1e-4 of its reference's" {
    const allocator: Allocator = testing_allocator;
    var failed_count: usize = 0;
    for (corpus) |stream| {
        const engine_frames: []f32 = try decodeWithEngine(allocator, stream.bytes);
        defer allocator.free(engine_frames);
        // What the stream's setup holds: the residue types, the most submaps, the most coupling steps.
        var reader: codecs.audio.ogg.PacketReader = .init(allocator, stream.bytes);
        defer reader.deinit();
        var headers: codecs.audio.vorbis.Headers = try codecs.audio.vorbis.readHeaders(allocator, &reader);
        defer headers.deinit();
        var residue_types: [3]bool = @splat(false);
        for (headers.setup.residues) |residue| {
            residue_types[residue.residue_type] = true;
        }
        var most_submaps: usize = 0;
        var most_coupling_steps: usize = 0;
        for (headers.setup.mappings) |mapping| {
            most_submaps = @max(most_submaps, mapping.submaps.len);
            most_coupling_steps = @max(most_coupling_steps, mapping.coupling_steps.len);
        }
        const channels: usize = headers.identification.channels;
        const verdict: CorpusVerdict = try judgeCorpusStream(allocator, stream, engine_frames, channels);
        const reference_name: []const u8 = if (stream.libvorbis_strided == null) "stb" else "libvorbis";
        std.debug.print(
            "{s}: {d} channels, {d} frames; residue types 0 {} 1 {} 2 {}; submaps {d}, coupling steps {d}; " ++
                "against {s}: largest difference {e:.3}, counts agree {}\n",
            .{
                stream.name,
                channels,
                engine_frames.len / channels,
                residue_types[0],
                residue_types[1],
                residue_types[2],
                most_submaps,
                most_coupling_steps,
                reference_name,
                verdict.largest_difference,
                verdict.is_count_equal,
            },
        );
        const is_close: bool = verdict.is_count_equal and verdict.largest_difference <= tolerance;
        failed_count += @intFromBool(!is_close);
    }
    try expectEqual(@as(usize, 0), failed_count);
}
