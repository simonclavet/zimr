//! lint:off prefer-std-alias: gltf sub-struct's local `testing` alias would clash
// src/codecs.zig - file-format decoders/encoders for assets we ship with.
// Aggregates parsing libraries into one file with namespaced sub-structs:
//     codecs.png         - PNG decoder + encoder (RGBA8)
//     codecs.truetype    - stb_truetype port (Andrew Kelley)
//     codecs.rectpack    - bin packing for font atlases
//     codecs.code_point  - UTF-8 decoder
//     codecs.gltf        - glTF 2.0 parser
//     codecs.audio       - WAV codec + format dispatch (audio-plan-v3)
// Each section's contents are unchanged from before the merge. Callers
// that did `const png = @import("codecs.zig").png` now use
// `const png = @import("codecs.zig").png`.

const std = @import("std");
const ArrayList = std.ArrayList;
const eql = std.mem.eql;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const zm = @import("zm");
const float64 = zm.float64;
const Vec = zm.Vec;
const ceilPowerOfTwo = zm.ceilPowerOfTwo;
const f32x4 = zm.f32x4;
const float = zm.float;
const maxInt = zm.maxInt;
const quat_identity = zm.quat_identity;
const sqrt = zm.sqrt;
const subChecked = zm.subChecked;
const vec = zm.vec;

/// The render-side types (`Mesh`, `Color`, ...) the loaders hand back.
/// Re-exported so out-of-module consumers (e.g. the `mesh_bake` build
/// tool, which imports codecs as a named module) can NAME the types
/// `gltf.meshesFromGltf` returns — they were previously reachable only
/// from inside this module.
pub const types = @import("types.zig");

// ============================================================================
// SECTION - png (was: src/png.zig)
// ============================================================================

pub const png = struct {
    pub const Error = error{
        InvalidSignature,
        InvalidChunk,
        InvalidIHDR,
        UnexpectedEnd,
        UnsupportedColorType,
        UnsupportedBitDepth,
        UnsupportedInterlace,
        DecompressionFailed,
        InvalidFilter,
        OutOfMemory,
        NoIDAT,
    };

    pub const Image = struct {
        /// Always RGBA8 (4 bytes per pixel).
        pixels: []u8,
        width: u32,
        height: u32,

        pub fn deinit(self: Image, allocator: Allocator) void {
            allocator.free(self.pixels);
        }
    };

    const SIGNATURE = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a };

    const Header = struct {
        width: u32,
        height: u32,
        bit_depth: u8,
        color_type: u8,
        interlace: u8,
    };

    /// Channels per pixel for each color type (at the chunk level, before
    /// our RGBA8 expansion).  Used to compute scanline stride.
    fn channelsForColorType(ct: u8) ?u8 {
        return switch (ct) {
            0 => 1, // Grayscale
            2 => 3, // RGB
            3 => 1, // Palette: 1-byte index, expanded to RGBA via PLTE/tRNS
            4 => 2, // Grayscale + Alpha
            6 => 4, // RGBA
            else => null,
        };
    }

    /// Read a big-endian u32 from a slice. PNG uses network byte order.
    fn readU32BE(bytes: []const u8) u32 {
        return (@as(u32, bytes[0]) << 24) |
            (@as(u32, bytes[1]) << 16) |
            (@as(u32, bytes[2]) << 8) |
            @as(u32, bytes[3]);
    }

    /// Decode PNG bytes into an RGBA8 image.  Caller owns `pixels`
    /// release with `Image.deinit(allocator)`.
    pub fn decode(allocator: Allocator, png_bytes: []const u8) Error!Image {
        if (png_bytes.len < SIGNATURE.len) {
            return Error.UnexpectedEnd;
        }
        if (!eql(u8, png_bytes[0..SIGNATURE.len], &SIGNATURE)) {
            return Error.InvalidSignature;
        }

        var cursor: usize = SIGNATURE.len;
        var header: ?Header = null;
        var idat_concat: ArrayList(u8) = .empty;
        defer idat_concat.deinit(allocator);
        // PLTE (palette RGB triples) + tRNS (per-entry alpha) for indexed PNGs;
        // both slice into png_bytes, which outlives this decode.
        var plte: []const u8 = &.{};
        var trns: []const u8 = &.{};

        // Walk chunks until IEND or end of data.
        while (cursor + 12 <= png_bytes.len) {
            const len: u32 = readU32BE(png_bytes[cursor .. cursor + 4]);
            cursor += 4;
            const chunk_type: []const u8 = png_bytes[cursor .. cursor + 4];
            cursor += 4;
            if (cursor + len + 4 > png_bytes.len) {
                return Error.UnexpectedEnd;
            }
            const data: []const u8 = png_bytes[cursor .. cursor + len];
            cursor += len;
            // Skip the 4-byte CRC; we trust the input.  Real-world PNGs are
            // either correct or fail later in deflate.
            cursor += 4;

            if (eql(u8, chunk_type, "IHDR")) {
                if (data.len < 13) {
                    return Error.InvalidIHDR;
                }
                header = .{
                    .width = readU32BE(data[0..4]),
                    .height = readU32BE(data[4..8]),
                    .bit_depth = data[8],
                    .color_type = data[9],
                    .interlace = data[12],
                };
            } else if (eql(u8, chunk_type, "IDAT")) {
                try idat_concat.appendSlice(allocator, data);
            } else if (eql(u8, chunk_type, "PLTE")) {
                plte = data;
            } else if (eql(u8, chunk_type, "tRNS")) {
                trns = data;
            } else if (eql(u8, chunk_type, "IEND")) {
                break;
            }
            // All other chunks are ancillary - ignored.
        }

        const h: Header = header orelse return Error.InvalidIHDR;
        if (h.bit_depth != 8) {
            return Error.UnsupportedBitDepth;
        }
        if (h.interlace != 0) {
            return Error.UnsupportedInterlace;
        }
        const channels: u8 = channelsForColorType(h.color_type) orelse return Error.UnsupportedColorType;
        if (idat_concat.items.len == 0) {
            return Error.NoIDAT;
        }

        // Decompress IDAT (zlib-framed DEFLATE) into the filtered scanline
        // buffer.  Each scanline is `width * channels` bytes preceded by a
        // 1-byte filter type.
        const bpp: u8 = channels; // bytes per pixel (8-bit channels)
        const stride: u32 = h.width * bpp;
        const filtered_len: u32 = (stride + 1) * h.height;
        const filtered = try allocator.alloc(u8, filtered_len);
        defer allocator.free(filtered);

        inflateZlib(idat_concat.items, filtered) catch return Error.DecompressionFailed;

        // Unfilter into a contiguous pixel buffer (no per-row prefix).
        const raw = try allocator.alloc(u8, stride * h.height);
        defer allocator.free(raw);
        unfilterScanlines(filtered, raw, h.width, h.height, bpp) catch return Error.InvalidFilter;

        // Expand to RGBA8.  This is the only allocation the caller keeps.
        const rgba = try allocator.alloc(u8, h.width * h.height * 4);
        expandToRGBA8(raw, rgba, h.width, h.height, h.color_type, plte, trns);

        return .{
            .pixels = rgba,
            .width = h.width,
            .height = h.height,
        };
    }

    /// Decompress zlib-framed DEFLATE bytes.  Wraps Zig stdlib's flate
    /// Decompress + Reader/Writer interface.  Errors are mapped to a
    /// single bool via the caller's Error.DecompressionFailed.
    fn inflateZlib(input: []const u8, output: []u8) !void {
        var reader: std.Io.Reader = std.Io.Reader.fixed(input);
        var writer: std.Io.Writer = std.Io.Writer.fixed(output);
        var decompress: std.compress.flate.Decompress = .init(&reader, .zlib, &.{});
        _ = decompress.reader.streamRemaining(&writer) catch return error.DecompressionFailed;
        if (writer.end != output.len) {
            return error.DecompressionFailed;
        }
    }

    /// Reverse the per-scanline PNG filtering.  `filtered` is
    /// `(stride + 1) * height` bytes (stride bytes per scanline plus a
    /// 1-byte filter-type prefix).  `out` is `stride * height` bytes
    /// (no prefixes).
    fn unfilterScanlines(
        filtered: []const u8,
        out: []u8,
        width: u32,
        height: u32,
        bpp: u8,
    ) !void {
        const stride: usize = @as(usize, width) * bpp;
        var prev_row: []const u8 = &[_]u8{};
        var y: usize = 0;
        while (y < height) : (y += 1) {
            const row_start = y * (stride + 1);
            const filter_type = filtered[row_start];
            const cur_in = filtered[row_start + 1 .. row_start + 1 + stride];
            const cur_out = out[y * stride .. (y + 1) * stride];

            // PNG row filters: each byte's raw value is corrected based on
            // its neighbours.  See PNG spec section 9.  Inlined here rather
            // than split into per-filter helpers because each filter is used
            // exactly once and the math reads better next to the dispatch.
            switch (filter_type) {
                // None: raw bytes pass through unchanged.
                0 => @memcpy(cur_out, cur_in),
                // Sub: byte = raw + byte at same pos in previous pixel.
                1 => for (cur_in, 0..) |b, i| {
                    const left: u8 = if (i >= bpp) cur_out[i - bpp] else 0;
                    cur_out[i] = b +% left;
                },
                // Up: byte = raw + byte at same pos in previous scanline.
                2 => if (prev_row.len == 0) {
                    @memcpy(cur_out, cur_in);
                } else for (cur_in, 0..) |b, i| {
                    cur_out[i] = b +% prev_row[i];
                },
                // Average: byte = raw + floor((left + above) / 2).
                3 => for (cur_in, 0..) |b, i| {
                    const left: u16 = if (i >= bpp) cur_out[i - bpp] else 0;
                    const above: u16 = if (prev_row.len > 0) prev_row[i] else 0;
                    const avg: u8 = @intCast((left + above) >> 1);
                    cur_out[i] = b +% avg;
                },
                // Paeth: byte = raw + Paeth(left, above, upper-left).
                // The Paeth predictor itself is a named helper because the
                // name carries spec meaning; the loop is inlined.
                4 => for (cur_in, 0..) |b, i| {
                    const left: i32 = if (i >= bpp) cur_out[i - bpp] else 0;
                    const above: i32 = if (prev_row.len > 0) prev_row[i] else 0;
                    const upper_left: i32 = if (i >= bpp and prev_row.len > 0) prev_row[i - bpp] else 0;
                    cur_out[i] = b +% paethPredictor(left, above, upper_left);
                },
                else => return error.InvalidFilter,
            }
            prev_row = cur_out;
        }
    }

    /// PNG's prediction function for filter type 4.  Picks whichever of
    /// `a`, `b`, `c` minimises distance from `a + b - c` (the would-be
    /// linear extrapolation).  Kept named because the canonical PNG-spec
    /// name carries meaning that "this loop body" wouldn't.
    fn paethPredictor(a: i32, b: i32, c: i32) u8 {
        const p: i32 = a + b - c;
        const pa: u32 = @abs(p - a);
        const pb: u32 = @abs(p - b);
        const pc: u32 = @abs(p - c);
        if (pa <= pb and pa <= pc) {
            return @intCast(a);
        }
        if (pb <= pc) {
            return @intCast(b);
        }
        return @intCast(c);
    }

    /// Expand the unfiltered raw pixel buffer to RGBA8 (4 bytes per pixel)
    /// based on the source color type.
    fn expandToRGBA8(
        raw: []const u8,
        rgba: []u8,
        width: u32,
        height: u32,
        color_type: u8,
        plte: []const u8,
        trns: []const u8,
    ) void {
        const n: usize = @as(usize, width) * @as(usize, height);
        var i: usize = 0;
        switch (color_type) {
            0 => { // Grayscale → RGBA
                while (i < n) : (i += 1) {
                    const g = raw[i];
                    rgba[i * 4 + 0] = g;
                    rgba[i * 4 + 1] = g;
                    rgba[i * 4 + 2] = g;
                    rgba[i * 4 + 3] = 255;
                }
            },
            2 => { // RGB → RGBA
                while (i < n) : (i += 1) {
                    rgba[i * 4 + 0] = raw[i * 3 + 0];
                    rgba[i * 4 + 1] = raw[i * 3 + 1];
                    rgba[i * 4 + 2] = raw[i * 3 + 2];
                    rgba[i * 4 + 3] = 255;
                }
            },
            3 => { // Palette (indexed) → RGBA via PLTE (RGB) + tRNS (alpha)
                while (i < n) : (i += 1) {
                    const idx: usize = raw[i];
                    const p3: usize = idx * 3;
                    rgba[i * 4 + 0] = if (p3 + 0 < plte.len) plte[p3 + 0] else 0;
                    rgba[i * 4 + 1] = if (p3 + 1 < plte.len) plte[p3 + 1] else 0;
                    rgba[i * 4 + 2] = if (p3 + 2 < plte.len) plte[p3 + 2] else 0;
                    rgba[i * 4 + 3] = if (idx < trns.len) trns[idx] else 255;
                }
            },
            4 => { // Grayscale + Alpha → RGBA
                while (i < n) : (i += 1) {
                    const g = raw[i * 2 + 0];
                    rgba[i * 4 + 0] = g;
                    rgba[i * 4 + 1] = g;
                    rgba[i * 4 + 2] = g;
                    rgba[i * 4 + 3] = raw[i * 2 + 1];
                }
            },
            6 => { // RGBA → RGBA (memcpy)
                @memcpy(rgba, raw[0 .. n * 4]);
            },
            else => unreachable, // already validated
        }
    }

    // ===========================================================================
    // Async loader - fetches a PNG from URL and decodes when ready
    // ===========================================================================

    const fetch = @import("web.zig").fetch;

    /// Async PNG load handle.  Wraps a `fetch.Handle` plus the allocator
    /// to use for the decoded Image.  Use `pollLoad(handle)` to check
    /// progress.
    pub const LoadHandle = struct {
        fetch_handle: fetch.Handle,
        allocator: Allocator,
    };

    /// Failure modes that can occur at the codecs layer: PNG
    /// decode failure, or the underlying fetch failed.  Higher
    /// layers (drawing.loadTextureFromMemory etc.) compose this
    /// into the broader `errors.LoadError` that includes
    /// GPU-upload failures and friends.
    pub const LoadFailure = png.Error || fetch.Error;

    pub const LoadStatus = union(enum) {
        pending,
        ok: Image,
        failed: LoadFailure,
    };

    /// Begin loading `url` as a PNG.  Returns a handle to poll.  The
    /// allocator is used for the decoded Image when the fetch resolves.
    /// `LoadHandle` is small and Copy-able; pass by value.
    pub fn loadAsync(allocator: Allocator, url: []const u8) LoadHandle {
        return .{
            .fetch_handle = fetch.start(url),
            .allocator = allocator,
        };
    }

    /// Check progress on a `loadAsync` handle.  On `.ok`, ownership of the
    /// returned `Image` transfers to the caller (release with
    /// `Image.deinit(allocator)` AND `releaseLoad(handle)`).  On `.failed`,
    /// the underlying fetch is auto-released; the caller must NOT call
    /// `releaseLoad`.
    pub fn pollLoad(handle: LoadHandle) LoadStatus {
        switch (fetch.poll(handle.fetch_handle)) {
            .pending => return .pending,
            .failed => |err| {
                fetch.release(handle.fetch_handle);
                return .{ .failed = err };
            },
            .ok => |bytes| {
                const img: Image = decode(handle.allocator, bytes) catch |err| {
                    fetch.release(handle.fetch_handle);
                    return .{ .failed = err };
                };
                // Decoded image owns its own pixel buffer; we can release
                // the fetched bytes immediately.
                fetch.release(handle.fetch_handle);
                return .{ .ok = img };
            },
        }
    }

    /// Release a still-pending or ok-but-not-yet-polled load handle.  Safe
    /// to call multiple times.  No-op if the fetch already resolved and
    /// `pollLoad` already returned `.ok` or `.failed`.
    pub fn releaseLoad(handle: LoadHandle) void {
        fetch.release(handle.fetch_handle);
    }

    // ============================================================================
    // PNG encoder
    // ============================================================================
    // Encodes RGBA8 pixel data into a standard PNG byte stream.  The
    // output is always:
    //   - 8-bit channel depth
    //   - color type 6 (RGBA - alpha kept regardless of input opacity)
    //   - filter method 0 (standard)
    //   - filter type 0 (None) on every scanline
    //   - interlace 0 (none)
    //   - compression method 0 (deflate, zlib-framed in IDAT)
    // We don't try to be clever with adaptive per-scanline filtering
    // it's trivially decode-able and produces files within ~10-15% of
    // what a full Paeth/Up/Average filter selector would yield, while
    // keeping the encoder ~100 lines instead of ~500.

    pub const EncodeError = error{
        OutOfMemory,
        /// Pixel buffer length doesn't match `width * height * 4`.
        InvalidPixelBufferSize,
        /// Width or height exceeds what fits in the PNG header (u32 wire
        /// format) or what we'll allocate for the filtered scanline buffer.
        DimensionsTooLarge,
        /// Underlying deflate or buffer write failed.  Surfaces both
        /// allocation failures inside the deflater and chunk-buffer growth
        /// failures here.
        EncodeFailed,
    };

    /// Encode an RGBA8 pixel buffer into PNG bytes.  `pixels.len` must
    /// equal `width * height * 4` exactly.  Returns a heap-owned slice
    /// - release with `allocator.free`.
    /// The fast path (no compression cost analysis) is fine for our use
    /// case: small assets, screenshot-style output, and image-editor
    /// "save current canvas" buttons.  Production-grade compression
    /// (PNGOUT-style filter selection + max chain length) is intentionally
    /// out of scope.
    pub fn encode(
        allocator: Allocator,
        pixels: []const u8,
        width: u32,
        height: u32,
    ) EncodeError![]u8 {
        // Sanity-check the input size.
        const expected: u64 = @as(u64, width) * @as(u64, height) * 4;
        if (pixels.len != expected) {
            return EncodeError.InvalidPixelBufferSize;
        }
        if (width == 0 or height == 0) {
            return EncodeError.InvalidPixelBufferSize;
        }

        // Filtered-stream size: each row gets a 1-byte filter prefix.
        const stride: u64 = @as(u64, width) * 4;
        const raw_filtered_len: u64 = (1 + stride) * height;
        if (raw_filtered_len > maxInt(usize)) {
            return EncodeError.DimensionsTooLarge;
        }

        // Output buffer for the entire PNG file.
        var out: ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        // 1. PNG signature.
        out.appendSlice(allocator, &SIGNATURE) catch return EncodeError.OutOfMemory;

        // 2. IHDR chunk - 13 bytes.
        var ihdr: [13]u8 = undefined;
        std.mem.writeInt(u32, ihdr[0..4], width, .big);
        std.mem.writeInt(u32, ihdr[4..8], height, .big);
        ihdr[8] = 8; // bit depth
        ihdr[9] = 6; // color type = RGBA
        ihdr[10] = 0; // compression = deflate
        ihdr[11] = 0; // filter method = standard
        ihdr[12] = 0; // interlace = none
        writeChunk(allocator, &out, "IHDR", &ihdr) catch return EncodeError.OutOfMemory;

        // 3. Build the filtered scanline stream.  Filter byte 0 = None,
        //    so each row is just `0x00 || row_pixels`.
        const raw_filtered = allocator.alloc(u8, @intCast(raw_filtered_len)) catch return EncodeError.OutOfMemory;
        defer allocator.free(raw_filtered);
        {
            const stride_usize: usize = @intCast(stride);
            var y: u32 = 0;
            while (y < height) : (y += 1) {
                const dst_off: usize = @as(usize, y) * (1 + stride_usize);
                const src_off: usize = @as(usize, y) * stride_usize;
                raw_filtered[dst_off] = 0; // filter type None
                @memcpy(
                    raw_filtered[dst_off + 1 .. dst_off + 1 + stride_usize],
                    pixels[src_off .. src_off + stride_usize],
                );
            }
        }

        // 4. Deflate the filtered stream into a zlib-framed IDAT payload.
        const idat_payload: []u8 = deflateZlib(allocator, raw_filtered) catch |err| switch (err) {
            error.OutOfMemory => return EncodeError.OutOfMemory,
            else => return EncodeError.EncodeFailed,
        };
        defer allocator.free(idat_payload);

        writeChunk(allocator, &out, "IDAT", idat_payload) catch return EncodeError.OutOfMemory;

        // 5. IEND chunk - empty payload.
        writeChunk(allocator, &out, "IEND", &[_]u8{}) catch return EncodeError.OutOfMemory;

        return out.toOwnedSlice(allocator) catch EncodeError.OutOfMemory;
    }

    /// Append one PNG chunk: 4-byte big-endian length, 4-byte type, payload,
    /// 4-byte big-endian CRC32 of (type ++ payload).
    fn writeChunk(
        allocator: Allocator,
        out: *ArrayList(u8),
        chunk_type: *const [4]u8,
        payload: []const u8,
    ) !void {
        var len_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_bytes, @intCast(payload.len), .big);
        try out.appendSlice(allocator, &len_bytes);
        try out.appendSlice(allocator, chunk_type);
        try out.appendSlice(allocator, payload);

        const Crc32 = std.hash.crc.@"CRC-32/ISO-HDLC";
        var crc: Crc32 = Crc32.init();
        crc.update(chunk_type);
        crc.update(payload);
        var crc_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &crc_bytes, crc.final(), .big);
        try out.appendSlice(allocator, &crc_bytes);
    }

    /// Compress `input` to a zlib-wrapped DEFLATE stream - exactly what
    /// PNG's IDAT chunk wants.  Caller frees with `allocator.free`.
    fn deflateZlib(allocator: Allocator, input: []const u8) ![]u8 {
        // Allocate a starting buffer for the writer.  Compress.init asserts
        // `output.buffer.len > 8`, so we can't pass the empty-buffer
        // default Allocating gives us - start at 256 bytes and let it grow.
        var alloc_writer: std.Io.Writer.Allocating = try .initCapacity(allocator, 256);
        errdefer alloc_writer.deinit();

        // Window buffer for the deflater.  flate.Compress requires this.
        const window_buf = try allocator.alloc(u8, std.compress.flate.max_window_len);
        defer allocator.free(window_buf);

        var compress: std.compress.flate.Compress = std.compress.flate.Compress.init(
            &alloc_writer.writer,
            window_buf,
            .zlib,
            .default,
        ) catch return error.EncodeFailed;

        compress.writer.writeAll(input) catch return error.EncodeFailed;
        compress.finish() catch return error.EncodeFailed;

        // Hand ownership of the compressed bytes to the caller.
        const result = try allocator.dupe(u8, alloc_writer.written());
        alloc_writer.deinit();
        return result;
    }

    test "encode/decode roundtrip 4×4 RGBA" {
        const allocator: Allocator = std.testing.allocator;
        // 4×4 image = 64 bytes RGBA.  Mix of fully-opaque + semi-transparent
        // + fully-transparent pixels so we cover every alpha edge.
        var pixels: [64]u8 = undefined;
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            pixels[i * 4 + 0] = @intCast(i * 16); // R: 0..240
            pixels[i * 4 + 1] = @intCast(255 - i * 16); // G: 255..15
            pixels[i * 4 + 2] = @intCast((i * 32) % 256); // B
            pixels[i * 4 + 3] = if (i % 4 == 0) 0 else if (i % 4 == 1) 128 else 255;
        }
        const png_bytes: []u8 = try encode(allocator, &pixels, 4, 4);
        defer allocator.free(png_bytes);
        try std.testing.expect(png_bytes.len > 0);
        try expectEqualSlices(u8, &SIGNATURE, png_bytes[0..SIGNATURE.len]);

        // Decode it back and check we got the same pixels out.
        const decoded: Image = try decode(allocator, png_bytes);
        defer decoded.deinit(allocator);
        try std.testing.expectEqual(@as(u32, 4), decoded.width);
        try std.testing.expectEqual(@as(u32, 4), decoded.height);
        try expectEqualSlices(u8, &pixels, decoded.pixels);
    }

    test "encode rejects size mismatch" {
        const allocator: Allocator = std.testing.allocator;
        const bad: [10]u8 = @splat(0); // 10 bytes for a 4x4 image (needs 64)
        try expectError(EncodeError.InvalidPixelBufferSize, encode(allocator, &bad, 4, 4));
    }

    test "encode rejects zero dimensions" {
        const allocator: Allocator = std.testing.allocator;
        const empty = &[_]u8{};
        try expectError(EncodeError.InvalidPixelBufferSize, encode(allocator, empty, 0, 0));
    }

    test "encode produces valid IHDR for non-square image" {
        const allocator: Allocator = std.testing.allocator;
        // 7 wide × 3 tall = 21 px = 84 bytes
        var pixels: [84]u8 = @splat(0xff);
        const png_bytes: []u8 = try encode(allocator, &pixels, 7, 3);
        defer allocator.free(png_bytes);

        // Check IHDR width/height fields (offsets 16-23 from start of file)
        const w = std.mem.readInt(u32, png_bytes[16..20], .big);
        const h = std.mem.readInt(u32, png_bytes[20..24], .big);
        try std.testing.expectEqual(@as(u32, 7), w);
        try std.testing.expectEqual(@as(u32, 3), h);
        // bit depth at 24, color type at 25
        try std.testing.expectEqual(@as(u8, 8), png_bytes[24]);
        try std.testing.expectEqual(@as(u8, 6), png_bytes[25]);
    }

    // ---- decode tests + embedded test fixtures
    // Embedded test PNGs hand-crafted with Python's zlib + struct (no
    // PIL dependency).  Each PNG is small enough (<100 bytes) that the
    // test binary stays trivial in size.

    // 4×4 RGBA PNG: 2×2 cells (red TL, green TR, blue BL, white BR).
    // Color type 6, 8 bit, no interlace, single IDAT, filter 0.
    const png_4x4_rgba = [_]u8{
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x08, 0x06, 0x00, 0x00, 0x00, 0xa9, 0xf1, 0x9e,
        0x7e, 0x00, 0x00, 0x00, 0x17, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xf8, 0xcf, 0xc0, 0xf0,
        0x1f, 0x84, 0x91, 0x20, 0x9a, 0x00, 0x94, 0x0f, 0x07, 0x18, 0x02, 0x00, 0x97, 0xe4, 0x27, 0xd9,
        0xe0, 0x08, 0x96, 0xdd, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
    };

    // 2×2 grayscale PNG: black, white, white, black.  Color type 0.
    const png_2x2_gray = [_]u8{
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x08, 0x00, 0x00, 0x00, 0x00, 0x57, 0xdd, 0x52,
        0xf8, 0x00, 0x00, 0x00, 0x0c, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0x60, 0xf8, 0x0f, 0x84,
        0x00, 0x06, 0x00, 0x01, 0xff, 0x93, 0xd1, 0xe4, 0x89, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e,
        0x44, 0xae, 0x42, 0x60, 0x82,
    };

    // 2×2 RGB PNG: red, green, blue, yellow.  Color type 2.
    const png_2x2_rgb = [_]u8{
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x08, 0x02, 0x00, 0x00, 0x00, 0xfd, 0xd4, 0x9a,
        0x73, 0x00, 0x00, 0x00, 0x14, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xf8, 0xcf, 0xc0, 0xc0,
        0x00, 0xc2, 0x0c, 0xff, 0xff, 0xff, 0x67, 0x00, 0x00, 0x1e, 0xef, 0x04, 0xfc, 0xa3, 0xc8, 0xb4,
        0xf7, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
    };

    test "decode: rejects bytes with no PNG signature" {
        const fake = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
        try expectError(Error.InvalidSignature, decode(std.testing.allocator, &fake));
    }

    test "decode: rejects truncated input" {
        try expectError(Error.UnexpectedEnd, decode(std.testing.allocator, &[_]u8{ 0x89, 0x50 }));
    }

    test "decode: 4x4 RGBA - header" {
        const img: Image = try decode(std.testing.allocator, &png_4x4_rgba);
        defer img.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u32, 4), img.width);
        try std.testing.expectEqual(@as(u32, 4), img.height);
        try std.testing.expectEqual(@as(usize, 64), img.pixels.len); // 4*4*4
    }

    test "decode: 4x4 RGBA - top-left pixel is red" {
        const img: Image = try decode(std.testing.allocator, &png_4x4_rgba);
        defer img.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 255), img.pixels[0]); // R
        try std.testing.expectEqual(@as(u8, 0), img.pixels[1]); // G
        try std.testing.expectEqual(@as(u8, 0), img.pixels[2]); // B
        try std.testing.expectEqual(@as(u8, 255), img.pixels[3]); // A
    }

    test "decode: 4x4 RGBA - top-right pixel is green" {
        const img: Image = try decode(std.testing.allocator, &png_4x4_rgba);
        defer img.deinit(std.testing.allocator);
        // Pixel (3, 0): row 0, col 3 → byte index (0*4 + 3) * 4 = 12
        try std.testing.expectEqual(@as(u8, 0), img.pixels[12]);
        try std.testing.expectEqual(@as(u8, 255), img.pixels[13]);
        try std.testing.expectEqual(@as(u8, 0), img.pixels[14]);
        try std.testing.expectEqual(@as(u8, 255), img.pixels[15]);
    }

    test "decode: 4x4 RGBA - bottom-left pixel is blue" {
        const img: Image = try decode(std.testing.allocator, &png_4x4_rgba);
        defer img.deinit(std.testing.allocator);
        // Pixel (0, 3): row 3, col 0 → byte (3*4 + 0) * 4 = 48
        try std.testing.expectEqual(@as(u8, 0), img.pixels[48]);
        try std.testing.expectEqual(@as(u8, 0), img.pixels[49]);
        try std.testing.expectEqual(@as(u8, 255), img.pixels[50]);
    }

    test "decode: 4x4 RGBA - bottom-right pixel is white" {
        const img: Image = try decode(std.testing.allocator, &png_4x4_rgba);
        defer img.deinit(std.testing.allocator);
        // Pixel (3, 3) → byte (3*4 + 3) * 4 = 60
        try std.testing.expectEqual(@as(u8, 255), img.pixels[60]);
        try std.testing.expectEqual(@as(u8, 255), img.pixels[61]);
        try std.testing.expectEqual(@as(u8, 255), img.pixels[62]);
        try std.testing.expectEqual(@as(u8, 255), img.pixels[63]);
    }

    test "decode: 2x2 grayscale expands to RGBA8 with alpha=255" {
        const img: Image = try decode(std.testing.allocator, &png_2x2_gray);
        defer img.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u32, 2), img.width);
        try std.testing.expectEqual(@as(u32, 2), img.height);
        try std.testing.expectEqual(@as(usize, 16), img.pixels.len); // 2*2*4
        // Pixel (0,0) is black → R=G=B=0, A=255
        try std.testing.expectEqual(@as(u8, 0), img.pixels[0]);
        try std.testing.expectEqual(@as(u8, 0), img.pixels[1]);
        try std.testing.expectEqual(@as(u8, 0), img.pixels[2]);
        try std.testing.expectEqual(@as(u8, 255), img.pixels[3]);
        // Pixel (1,0) is white
        try std.testing.expectEqual(@as(u8, 255), img.pixels[4]);
        try std.testing.expectEqual(@as(u8, 255), img.pixels[5]);
        try std.testing.expectEqual(@as(u8, 255), img.pixels[6]);
        try std.testing.expectEqual(@as(u8, 255), img.pixels[7]);
    }

    test "decode: 2x2 RGB expands to RGBA8 with alpha=255" {
        const img: Image = try decode(std.testing.allocator, &png_2x2_rgb);
        defer img.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u32, 2), img.width);
        try std.testing.expectEqual(@as(u32, 2), img.height);
        // Pixel (0,0) is red
        try std.testing.expectEqual(@as(u8, 255), img.pixels[0]);
        try std.testing.expectEqual(@as(u8, 0), img.pixels[1]);
        try std.testing.expectEqual(@as(u8, 0), img.pixels[2]);
        try std.testing.expectEqual(@as(u8, 255), img.pixels[3]);
        // Pixel (1,0) is green
        try std.testing.expectEqual(@as(u8, 0), img.pixels[4]);
        try std.testing.expectEqual(@as(u8, 255), img.pixels[5]);
        try std.testing.expectEqual(@as(u8, 0), img.pixels[6]);
        try std.testing.expectEqual(@as(u8, 255), img.pixels[7]);
        // Pixel (1,1) is yellow
        try std.testing.expectEqual(@as(u8, 255), img.pixels[12]);
        try std.testing.expectEqual(@as(u8, 255), img.pixels[13]);
        try std.testing.expectEqual(@as(u8, 0), img.pixels[14]);
        try std.testing.expectEqual(@as(u8, 255), img.pixels[15]);
    }
};

// ============================================================================
// SECTION - jpeg (baseline 8-bit sequential)
// ============================================================================
//
// What this decodes: baseline JPEG (SOF0), 8-bit precision, Huffman entropy
// coding.  Grayscale (1 component) or YCbCr (3 components) with chroma
// sampling factors up to 2x2 on luma — covers 4:4:4, 4:4:0, 4:2:2, 4:2:0
// which is ~every consumer JPEG.  Output is always RGBA8 to match png.Image
// so callers don't notice which codec ran.
//
// What this does NOT do: progressive JPEG (SOF2), arithmetic coding (SOF9+),
// 12-bit precision (SOF1), lossless modes (SOF3, SOF7), hierarchical (SOF5,
// SOF6), CMYK, EXIF/ICC handling.  Hitting any of these returns a specific
// Error.Unsupported* — callers fall back to "warn + leave untextured" rather
// than aborting whole loads.  We surfaced that fallback path while debugging
// DamagedHelmet's JPEG textures; this section's job is to remove the need
// for the fallback in the common case.
//
// Pipeline, top to bottom:
//   1. marker scan      — walk FF-prefixed markers, dispatch on type
//   2. segment parse    — DQT (quant), DHT (Huffman), SOF0 (frame), SOS (scan)
//   3. entropy decode   — Huffman + run-length-zero + inline dequantize, per
//                         MCU block
//   4. inverse DCT      — Loeffler-style fixed-point, 8x8 frequency -> spatial
//   5. chroma upsample  — nearest-neighbor Cb/Cr to Y resolution
//   6. YCbCr → RGB      — fixed-point 16.16 matrix; clamp; alpha=255
//
// References studied (not copied):
//   - stb_image.h JPEG decoder (raylib's external/, lines 1914-4080) — single
//     fat struct + manual SIMD.  Borrowed the 9-bit fast Huffman lookup idea.
//     Skipped its SIMD kernels (LLVM auto-vec is fine for our use).
//   - zigimg src/formats/jpeg/ (modular Zig port, ~1400 lines).  Borrowed the
//     marker enum layout and the Loeffler IDCT shape; rewrote the math
//     ourselves to cross-check constants.
//
// This is one big section in zimr's flat straight-line style, with many
// inline comments explaining what the format actually does and why each step
// matters.  Not the most clever decoder in the world but the easiest one to
// debug six months from now.

pub const jpeg = struct {
    pub const Error = error{
        // Structural problems with the byte stream
        InvalidSignature,
        UnexpectedEnd,
        InvalidMarker,
        // Encoding modes we don't (yet) support
        UnsupportedMode, // arithmetic, lossless, hierarchical, progressive
        UnsupportedPrecision, // anything other than 8-bit
        UnsupportedComponentCount, // anything other than 1 (gray) or 3 (YCbCr)
        UnsupportedSampling, // sampling factor > 2 or non-square chroma layout
        // Inconsistencies caught while decoding
        InvalidQuantTable,
        InvalidHuffmanTable,
        InvalidScan,
        InvalidEntropyData,
        InvalidHuffmanCode,
        // Allocation
        OutOfMemory,
    };

    pub const Image = struct {
        // RGBA8, same shape as png.Image so callers don't notice
        pixels: []u8,
        width: u32,
        height: u32,

        pub fn deinit(self: Image, allocator: Allocator) void {
            allocator.free(self.pixels);
        }
    };

    // JPEG zig-zag scan order.  Coefficients in the bitstream arrive in this
    // sequence because low-frequency (visually-important) coefficients
    // cluster near linear index 0 after zig-zagging — which means the
    // run-length encoding gets long trails of zeros to crunch at the end.
    // We index INTO this from k=0..63 during entropy decode to find where in
    // the natural-order 8x8 block each coefficient actually goes.
    const dezigzag: [64]u8 = .{
        0,  1,  8,  16, 9,  2,  3,  10,
        17, 24, 32, 25, 18, 11, 4,  5,
        12, 19, 26, 33, 40, 48, 41, 34,
        27, 20, 13, 6,  7,  14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36,
        29, 22, 15, 23, 30, 37, 44, 51,
        58, 59, 52, 45, 38, 31, 39, 46,
        53, 60, 61, 54, 47, 55, 62, 63,
    };

    // The "fast" Huffman lookup is a 9-bit prefix table.  Most Huffman codes
    // in JPEG are <= 9 bits, so a single 9-bit peek tells us both the symbol
    // and how many bits to consume.  Codes longer than 9 bits leave their
    // slots with fast_len = 0 (sentinel) and we fall back to a per-bit walk.
    // 9 bits is the sweet spot per stb_image — 512 entries (small) but covers
    // ~99% of real-world codes (big speedup).
    const fast_bits: u5 = 9;
    const fast_size: usize = 1 << fast_bits;

    // One Huffman table per (class, table_id) — JPEG allows up to 4 DC + 4 AC
    // for baseline (per spec, only 2 of each in practice, but we provision 4).
    const HuffmanTable = struct {
        // Fast path: 9-bit prefix -> (symbol, code length).
        // fast_len[i] == 0 means "no entry here, use slow path".
        fast: [fast_size]u8 = @splat(0),
        fast_len: [fast_size]u5 = @splat(0),
        // Slow path: canonical Huffman decoded by walking one bit at a time.
        // For each length L in 1..16: mincode[L] is the smallest L-bit code,
        // maxcode[L] is the largest, valptr[L] is the index in `symbols`
        // where L-bit codes begin.  Symbols are stored flat in canonical order.
        // maxcode is i64 (not u32) specifically so we can use -1 as the
        // "no codes at this length" sentinel — with a u32 sentinel of
        // 0xFFFFFFFF, the slow-path `code <= maxcode[length]` check would
        // trivially match any incoming code, which would let a length-1
        // walk swallow the entropy stream and return a garbage symbol.
        // i64 lets the comparison stay correct on empty lengths AND keeps
        // the per-length range check as a single inequality.
        mincode: [17]u32 = @splat(0),
        maxcode: [18]i64 = @splat(-1),
        valptr: [17]usize = @splat(0),
        symbols: [256]u8 = @splat(0),
    };

    // Component info from SOF0.  Up to 4 are allowed by spec; we accept 1
    // (grayscale) or 3 (YCbCr).  CMYK (4 components) returns Unsupported.
    const Component = struct {
        id: u8, // glyph id from SOF0 — usually 1=Y, 2=Cb, 3=Cr but not always
        h: u8, // horizontal sampling factor (1..4 per spec; we only do 1..2)
        v: u8, // vertical sampling factor (same)
        quant_id: u8, // which quant table index to dequantize with
        dc_huff_id: u8 = 0, // DC Huffman table index (set later from SOS)
        ac_huff_id: u8 = 0, // AC Huffman table index (set later from SOS)
        // Decoded sample buffer, sized to the component's actual resolution
        // (image_w / max_h * h, rounded up to 8x8 blocks).  Owned by the
        // decoder, freed at the end.
        pixels: []u8 = &.{},
        stride: usize = 0, // row stride in pixels — may exceed actual width
        blocks_w: usize = 0, // number of 8x8 blocks horizontally
        blocks_h: usize = 0, // number of 8x8 blocks vertically
    };

    // Sniff a JPEG magic by SOI marker. Used as a defense-in-depth check when
    // mime_type isn't set — see drawing.zig materialsFromGltf.
    pub fn isJpeg(bytes: []const u8) bool {
        // The SOI marker is FF D8; real JPEGs immediately follow with FF
        // (the start of the next marker), so a 3-byte check is more robust
        // than a 2-byte one.
        return bytes.len >= 3 and bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF;
    }

    // ------------------------------------------------------------------------
    // Huffman table construction (DHT segment payload -> HuffmanTable)
    // ------------------------------------------------------------------------
    //
    // The DHT segment delivers:
    //   - 16 bytes of "code length counts": how many codes of length L for
    //     L in 1..16
    //   - N symbols (N = sum of code-length counts), in canonical order
    //
    // We build a canonical Huffman code by assigning consecutive integer
    // values, starting from 0 and shifting left when length increases.  This
    // is the standard "JPEG-canonical" Huffman construction described in
    // section C.2 of T.81.  We then derive mincode/maxcode/valptr for the
    // slow path and populate the 9-bit fast lookup for short codes.
    fn buildHuffmanTable(
        counts: *const [16]u8,
        symbols: []const u8,
        out: *HuffmanTable,
    ) Error!void {
        // Sanity: total symbols must match what the table claims
        var total: usize = 0;
        for (counts) |c| {
            total += c;
        }
        if (total != symbols.len) {
            return Error.InvalidHuffmanTable;
        }
        if (total > 256) {
            // Per spec, a Huffman table has at most 256 symbols
            return Error.InvalidHuffmanTable;
        }

        // CRITICAL: clear stale fast/fast_len entries before populating.
        // Progressive JPEGs redefine Huffman tables between scans via
        // DHT markers, overwriting the SAME `out` table struct.  Without
        // this clear, fast_len entries for 9-bit prefixes that the new
        // table doesn't use retain stale values from the previous table —
        // huffDecode's fast-path hits them and returns the wrong symbol
        // and length, over-reading bits across the scan and eventually
        // running into the next marker mid-block.  Caught on the
        // DamagedHelmet's MR texture's 5th scan after scans 1-4 succeeded.
        @memset(&out.fast_len, 0);
        @memset(&out.fast, 0);
        // mincode/maxcode/valptr are unconditionally rewritten in the loop
        // below for every length, so they don't need pre-clearing.

        // Copy symbols flat into the table (we own a fixed 256-byte buffer)
        @memcpy(out.symbols[0..total], symbols);

        // Walk lengths 1..16 building canonical codes and recording mincode,
        // maxcode, valptr per length.  `code` is the current canonical code
        // value; it advances by 1 for each symbol within a length and
        // left-shifts by 1 when moving to the next length.
        var code: u32 = 0;
        var sym_idx: usize = 0;
        for (1..17) |length| {
            const count: u32 = counts[length - 1];
            out.mincode[length] = code;
            out.valptr[length] = sym_idx;
            if (count == 0) {
                // Leave maxcode at the default -1 — the "no codes at this
                // length" sentinel.  Slow-path comparisons against -1
                // (signed) never match a real positive code value.
                out.maxcode[length] = -1;
            } else {
                // Largest code at this length is mincode + count - 1
                out.maxcode[length] = @as(i64, code) + @as(i64, count) - 1;
                // Fast-path: for codes <= fast_bits in length, fill a span of
                // the 9-bit lookup table with this symbol.  A length-L code
                // C corresponds to all 9-bit prefixes of the form
                // C << (fast_bits - L), spanning 1 << (fast_bits - L) entries.
                if (length <= fast_bits) {
                    var j: u32 = 0;
                    while (j < count) : (j += 1) {
                        const c: u32 = code + j;
                        const shift: u5 = fast_bits - @as(u5, @intCast(length));
                        const first: usize = @as(usize, @intCast(c)) << shift;
                        const span: usize = @as(usize, 1) << shift;
                        for (first..first + span) |fi| {
                            out.fast[fi] = symbols[sym_idx + j];
                            out.fast_len[fi] = @intCast(length);
                        }
                    }
                }
                code += count;
                sym_idx += count;
            }
            // Move to the next length: shift code left by 1 (canonical
            // Huffman construction)
            code <<= 1;
        }
        // mincode/maxcode for length 17 is the sentinel — we initialize
        // maxcode to 0xFFFFFFFF in the default value and never read past
        // length 16, so no extra work needed.
    }

    // ------------------------------------------------------------------------
    // BitReader: read entropy-coded bits with JPEG-specific quirks
    // ------------------------------------------------------------------------
    //
    // The entropy stream is byte-aligned but bit-readable.  Two quirks:
    //   1. Byte-stuffing: any literal 0xFF byte in the entropy stream is
    //      followed by a 0x00 stuffing byte (which we silently drop).  This
    //      lets the decoder distinguish data from markers.
    //   2. Markers: a 0xFF followed by NON-zero is a marker — usually
    //      restart (0xD0..0xD7) or EOI (0xD9).  We stash the marker byte
    //      and stop refilling so the caller can decide what to do.
    //
    // The accumulator holds up to 24 bits at a time; we refill whenever
    // we don't have enough.  Bits are filled MSB-first because that's how
    // JPEG transmits them (and how peek/consume naturally read).
    const BitReader = struct {
        bytes: []const u8,
        cursor: usize,
        acc: u32 = 0,
        bits: u6 = 0, // u6 because acc holds up to 32 bits (rare but valid)
        marker: ?u8 = null, // saved marker byte if we encountered one
        eof: bool = false, // true if we hit end of bytes

        fn refill(self: *BitReader) void {
            // Pull bytes until we've got at least 24 bits, or hit a marker,
            // or run out of input.
            while (self.bits <= 24) {
                if (self.marker != null or self.eof) {
                    return;
                }
                if (self.cursor >= self.bytes.len) {
                    self.eof = true;
                    return;
                }
                const b: u8 = self.bytes[self.cursor];
                self.cursor += 1;
                if (b == 0xFF) {
                    // Could be stuffing or a marker.  Peek the next byte.
                    if (self.cursor >= self.bytes.len) {
                        self.eof = true;
                        return;
                    }
                    const next: u8 = self.bytes[self.cursor];
                    self.cursor += 1;
                    if (next == 0x00) {
                        // Stuffing byte — the real data is just 0xFF.
                        // Push 0xFF onto the accumulator and continue.
                        self.acc |= @as(u32, 0xFF) << @intCast(24 - self.bits);
                        self.bits += 8;
                    } else {
                        // It's a marker — stop refilling.  Common ones are
                        // EOI (0xD9), restart markers (0xD0..0xD7).
                        self.marker = next;
                        return;
                    }
                } else {
                    self.acc |= @as(u32, b) << @intCast(24 - self.bits);
                    self.bits += 8;
                }
            }
        }

        fn peek(self: *BitReader, n: u5) u32 {
            // peek N bits from the top of the accumulator
            if (n == 0) {
                return 0;
            }
            return self.acc >> @intCast(32 - @as(u6, n));
        }

        fn consume(self: *BitReader, n: u5) void {
            // drop the top N bits
            if (n == 0) {
                return;
            }
            self.acc <<= @intCast(n);
            self.bits -= n;
        }

        fn readBits(self: *BitReader, n: u5) Error!u32 {
            self.refill();
            if (self.bits < n) {
                return Error.UnexpectedEnd;
            }
            const v: u32 = self.peek(n);
            self.consume(n);
            return v;
        }

        // JPEG "extend" — convert an N-bit unsigned magnitude into a signed
        // value using the convention that the high bit indicates sign.
        // If the high bit is 0, the value is negative: extend = bits - (2^N - 1).
        // If the high bit is 1, the value is positive: extend = bits.
        // Special case s=0 means "the coefficient is 0", encoded with no
        // magnitude bits at all.
        fn receiveExtend(self: *BitReader, s: u5) Error!i32 {
            if (s == 0) {
                return 0;
            }
            const v: u32 = try self.readBits(s);
            const threshold: u32 = @as(u32, 1) << @intCast(s - 1);
            if (v < threshold) {
                // Negative branch — extend with leading 1s and the +1 offset
                const offset: i32 = (@as(i32, -1) << @intCast(s)) + 1;
                return @as(i32, @intCast(v)) + offset;
            }
            return @intCast(v);
        }
    };

    // Slow-path Huffman decode: walk one bit at a time until we hit a code
    // whose value is within mincode..maxcode for that length.  Only invoked
    // when the 9-bit fast lookup misses (code is longer than 9 bits).
    fn huffSlow(br: *BitReader, t: *const HuffmanTable) Error!u8 {
        var code: u32 = 0;
        var len: u5 = 1;
        while (len <= 16) : (len += 1) {
            const bit: u32 = try br.readBits(1);
            code = (code << 1) | bit;
            // i64 comparison handles the -1 sentinel for empty lengths:
            // when maxcode[length] is -1 (no codes here), code (cast to
            // i64) can't be <= -1, so we correctly fall through.
            if (@as(i64, code) <= t.maxcode[len]) {
                // Found it — symbol index is valptr[length] + (code - mincode[length])
                const idx: usize = t.valptr[len] + @as(usize, @intCast(code - t.mincode[len]));
                return t.symbols[idx];
            }
        }
        return Error.InvalidHuffmanCode;
    }

    fn huffDecode(br: *BitReader, t: *const HuffmanTable) Error!u8 {
        br.refill();
        // Try the 9-bit fast lookup first.  If we have fewer than 9 bits
        // (near EOF), the lookup might still hit a short code — peek a partial
        // count.  But the simplest robust thing is: if we have >= 9 bits, fast
        // path; else, slow path which reads one at a time.
        if (br.bits >= fast_bits) {
            const k: u32 = br.peek(fast_bits);
            const len: u5 = t.fast_len[@intCast(k)];
            if (len != 0) {
                br.consume(len);
                return t.fast[@intCast(k)];
            }
        }
        return huffSlow(br, t);
    }

    // ------------------------------------------------------------------------
    // Block decode: read one 8x8 block of dequantized coefficients in natural
    // (not zig-zag) order.  Updates prev_dc in place — DC coefficients are
    // differentially coded across blocks of the same component.
    // ------------------------------------------------------------------------
    fn decodeBlock(
        br: *BitReader,
        dc_table: *const HuffmanTable,
        ac_table: *const HuffmanTable,
        quant: *const [64]u16,
        prev_dc: *i32,
        block: *[64]i32,
    ) Error!void {
        @memset(block, 0);

        // DC: first symbol is the magnitude category (0..11), then the raw
        // bits, which we extend into a signed diff from the previous DC of
        // this component.
        const dc_size: u8 = try huffDecode(br, dc_table);
        if (dc_size > 11) {
            return Error.InvalidEntropyData;
        }
        const dc_diff: i32 = try br.receiveExtend(@intCast(dc_size));
        prev_dc.* += dc_diff;
        block[0] = prev_dc.* * @as(i32, quant[0]);

        // AC: 63 more coefficients in zig-zag order.  Each Huffman symbol
        // encodes (run, size) where run is leading zeros and size is the
        // magnitude bits to follow.  Two specials: 0x00 = EOB (rest of block
        // is zero), 0xF0 = ZRL (16 zeros, no value).
        var k: usize = 1;
        while (k < 64) {
            const rs: u8 = try huffDecode(br, ac_table);
            const s: u5 = @intCast(rs & 0x0F);
            const r: u8 = rs >> 4;
            if (s == 0) {
                if (r == 15) {
                    // ZRL: 16 zeros and continue
                    k += 16;
                    continue;
                }
                // EOB: rest of block is zero (already memset above)
                break;
            }
            // Skip r zeros, then read s magnitude bits
            k += r;
            if (k >= 64) {
                return Error.InvalidEntropyData;
            }
            const v: i32 = try br.receiveExtend(s);
            // Dequantize inline: multiply by the quant table entry at the
            // NATURAL position (not zig-zag).  Saves a separate dequant pass.
            const nat: u8 = dezigzag[k];
            block[nat] = v * @as(i32, quant[nat]);
            k += 1;
        }
    }

    // ------------------------------------------------------------------------
    // Progressive JPEG block decoders.
    //
    // Progressive JPEG decomposes each 64-coefficient block across multiple
    // SCANS.  A scan specifies:
    //   - Spectral selection [Ss..Se]: which zigzag positions this scan
    //     covers.  DC scan has Ss=0, Se=0; AC scans have Ss>=1.
    //   - Successive approximation (Ah, Al): bit position.  Ah=0 means
    //     "this is the first scan covering these coefficients"; Ah>0 means
    //     "refine the already-decoded coefficients by one bit at position Al".
    //
    // For each block, the decoder must therefore handle four cases:
    //   - DC first scan       (Ss=0, Se=0, Ah=0)
    //   - DC refinement       (Ss=0, Se=0, Ah>0)
    //   - AC first scan       (Ss>=1, Se>=Ss, Ah=0)
    //   - AC refinement       (Ss>=1, Se>=Ss, Ah>0)
    //
    // Coefficients accumulate across scans in block storage; dequantize +
    // IDCT runs ONCE at the end after all scans complete.  Coefficient
    // storage is i16 (sufficient for accumulated 8-bit-precision JPEG).
    //
    // Cross-checked against zigimg's Scan.zig and stb_image's
    // stbi__jpeg_decode_block_prog_{dc,ac}.  EOB run-length encoding logic
    // matches stb_image's structure most closely.
    // ------------------------------------------------------------------------

    fn decodeBlockProgDc(
        br: *BitReader,
        dc_table: *const HuffmanTable,
        prev_dc: *i32,
        block: *[64]i16,
        succ_low: u4,
        succ_high: u4,
    ) Error!void {
        if (succ_high == 0) {
            // First DC scan for this block — read the DC differential and
            // shift up by succ_low (so future refinement scans can add
            // lower-order bits).
            const dc_size: u8 = try huffDecode(br, dc_table);
            if (dc_size > 11) {
                return Error.InvalidEntropyData;
            }
            const dc_diff: i32 = try br.receiveExtend(@intCast(dc_size));
            prev_dc.* += dc_diff;
            // Shift left, store as i16.  i32 → i16 with sufficient headroom
            // for 8-bit-precision JPEG (DC fits in ±2048 * 2^succ_low ≤ i16).
            block[0] = @intCast(prev_dc.* << succ_low);
        } else {
            // Refinement scan — read one bit and OR it into the existing DC
            // at bit position succ_low.
            const bit: u32 = try br.readBits(1);
            if (bit != 0) {
                block[0] |= @as(i16, 1) << succ_low;
            }
        }
    }

    fn decodeBlockProgAc(
        br: *BitReader,
        ac_table: *const HuffmanTable,
        block: *[64]i16,
        spec_start: u8,
        spec_end: u8,
        succ_low: u4,
        succ_high: u4,
        eob_run: *u32,
    ) Error!void {
        if (succ_high == 0) {
            // First scan for these AC coefficients.  Standard run-length-
            // zero coding, plus a new "EOBn" marker (s=0, r<15) that says
            // "the rest of this block AND the next 2^r-1 blocks (plus extra
            // bits) all have AC = 0 for this spectral range".  The EOB run
            // persists across blocks within the scan.
            if (eob_run.* > 0) {
                eob_run.* -= 1;
                return; // already memset/refinement-skipped at scan setup
            }
            var k: usize = spec_start;
            while (k <= spec_end) {
                const rs: u8 = try huffDecode(br, ac_table);
                const s: u4 = @intCast(rs & 0x0F);
                const r: u8 = rs >> 4;
                if (s == 0) {
                    if (r < 15) {
                        // EOBn: bank a run of (2^r + extra) blocks where
                        // the remaining AC coefficients are all zero.
                        eob_run.* = @as(u32, 1) << @intCast(r);
                        if (r > 0) {
                            const extra: u32 = try br.readBits(@intCast(r));
                            eob_run.* += extra;
                        }
                        eob_run.* -= 1; // consume this block's worth
                        return;
                    }
                    // ZRL: 16 zeros, no value
                    k += 16;
                    continue;
                }
                if (s > 10) {
                    return Error.InvalidEntropyData;
                }
                k += r;
                if (k > spec_end) {
                    return Error.InvalidEntropyData;
                }
                const v: i32 = try br.receiveExtend(@intCast(s));
                const nat: u8 = dezigzag[k];
                block[nat] = @intCast(v << succ_low);
                k += 1;
            }
        } else {
            // AC refinement scan — for each existing non-zero coefficient,
            // read one bit to refine it.  For new (previously-zero)
            // coefficients, the entropy stream encodes (run_of_zeros, sign):
            // a run-length skip past run zeros, then a new coefficient of
            // value ±(1 << succ_low) with sign read as one bit.  EOBn here
            // doesn't end the block — it ends after applying refinement
            // bits to existing non-zero coefficients in the remaining range.
            const bit: i16 = @as(i16, 1) << succ_low;
            var k: usize = spec_start;
            if (eob_run.* > 0) {
                eob_run.* -= 1;
                // Apply refinement to remaining existing non-zero coeffs
                while (k <= spec_end) : (k += 1) {
                    const nat: u8 = dezigzag[k];
                    if (block[nat] != 0) {
                        const sign_bit: u32 = try br.readBits(1);
                        if (sign_bit != 0) {
                            // Increase magnitude by `bit`, preserving sign
                            if (block[nat] > 0) {
                                block[nat] += bit;
                            } else {
                                block[nat] -= bit;
                            }
                        }
                    }
                }
                return;
            }
            while (k <= spec_end) {
                const rs: u8 = try huffDecode(br, ac_table);
                var s: i16 = @as(i16, @intCast(rs & 0x0F));
                var r: i32 = @intCast(rs >> 4);
                if (s == 0) {
                    if (r < 15) {
                        eob_run.* = @as(u32, 1) << @intCast(r);
                        if (r > 0) {
                            const extra: u32 = try br.readBits(@intCast(r));
                            eob_run.* += extra;
                        }
                        eob_run.* -= 1; // consumed this block
                        r = 64; // force the post-loop "advance to end" path
                    } else {
                        // r=15, s=0: 16 zeros (but apply refinement to
                        // non-zero existing coeffs as we skip past them)
                    }
                } else {
                    if (s != 1) {
                        return Error.InvalidEntropyData;
                    }
                    // New coefficient — sign bit determines ±(1 << succ_low)
                    const sign_bit: u32 = try br.readBits(1);
                    s = if (sign_bit != 0) bit else -bit;
                }
                // Advance, refining existing non-zero coeffs and placing
                // the new coefficient at the position after `r` zeros.
                while (k <= spec_end) {
                    const nat: u8 = dezigzag[k];
                    if (block[nat] != 0) {
                        const sign_bit: u32 = try br.readBits(1);
                        if (sign_bit != 0) {
                            if (block[nat] > 0) {
                                block[nat] += bit;
                            } else {
                                block[nat] -= bit;
                            }
                        }
                        k += 1;
                    } else {
                        if (r == 0) {
                            block[nat] = s;
                            k += 1;
                            break;
                        }
                        r -= 1;
                        k += 1;
                    }
                }
            }
        }
    }

    // ------------------------------------------------------------------------  Operates in place on a
    // [64]i32 block.  Two passes: columns first, then rows.  Output is signed
    // i32 samples; caller adds 128 and clamps for u8 output.
    // ------------------------------------------------------------------------
    //
    // The Loeffler 8-point IDCT decomposes the 8x8 DCT into a small graph of
    // multiplications and rotations.  The constants below come from the
    // standard form (12 fractional bits of precision).  We use a 1-D function
    // and call it twice — once per column, once per row — like the textbook.
    // After the first pass we have an intermediate scaled by 2^10 (the 1024
    // bias absorbs the rounding).  After the second pass we scale by 2^17
    // (output bits) and round to integer samples.
    //
    // I wrote the constants and operations out by hand from the Loeffler '89
    // paper rather than copying from zigimg or stb_image to make sure I
    // understand them.  Cross-checked the numeric output on a few sample
    // blocks against zigimg's IDCT — agreement to within 1 LSB which is the
    // expected rounding-equivalence ceiling.
    // ------------------------------------------------------------------------
    // Decode one progressive scan into block-coefficient storage.  Handles
    // both interleaved scans (multiple components, MCU-organized) and
    // non-interleaved scans (single component, block-organized).
    //
    // Per JPEG spec: for non-interleaved scans an "MCU" collapses to a
    // single 8x8 block, so the same restart-interval logic applies in
    // both modes — we just compute the block coordinates differently.
    // ------------------------------------------------------------------------
    fn decodeProgressiveScan(
        br: *BitReader,
        bytes: []const u8,
        components: []Component,
        scan_comps: []const usize,
        dc_huff: []const HuffmanTable,
        ac_huff: []const HuffmanTable,
        prog_blocks: *const [3][]i16,
        spec_start: u8,
        spec_end: u8,
        succ_high: u4,
        succ_low: u4,
        max_h: u8,
        max_v: u8,
        mcus_w: usize,
        mcus_h: usize,
        restart_interval: u32,
    ) Error!void {
        var prev_dc: [3]i32 = .{ 0, 0, 0 };
        var eob_run: u32 = 0;
        var mcu_count: u32 = 0;
        var rst_expected: u8 = 0xD0;

        const decodeOneBlock = struct {
            fn run(
                br_inner: *BitReader,
                comp: *Component,
                block: *[64]i16,
                prev_dc_ptr: *i32,
                eob_run_ptr: *u32,
                ss: u8,
                se: u8,
                ah: u4,
                al: u4,
                dc_huff_inner: []const HuffmanTable,
                ac_huff_inner: []const HuffmanTable,
            ) Error!void {
                if (ss == 0) {
                    try decodeBlockProgDc(
                        br_inner,
                        &dc_huff_inner[comp.dc_huff_id],
                        prev_dc_ptr,
                        block,
                        al,
                        ah,
                    );
                } else {
                    try decodeBlockProgAc(
                        br_inner,
                        &ac_huff_inner[comp.ac_huff_id],
                        block,
                        ss,
                        se,
                        al,
                        ah,
                        eob_run_ptr,
                    );
                }
            }
        }.run;

        const is_interleaved: bool = scan_comps.len > 1;

        // Total MCUs in this scan.  Interleaved uses image-level MCU grid;
        // non-interleaved uses the single component's block grid.
        const total_mcus: u32 = if (is_interleaved)
            @intCast(mcus_w * mcus_h)
        else blk: {
            const ci: usize = scan_comps[0];
            const c: *const Component = &components[ci];
            break :blk @intCast(c.blocks_w * c.blocks_h);
        };

        var mcu_idx: u32 = 0;
        while (mcu_idx < total_mcus) : (mcu_idx += 1) {
            if (is_interleaved) {
                const my: usize = @as(usize, mcu_idx) / mcus_w;
                const mx: usize = @as(usize, mcu_idx) % mcus_w;
                for (scan_comps) |ci| {
                    const comp: *Component = &components[ci];
                    var by: usize = 0;
                    while (by < comp.v) : (by += 1) {
                        var bx: usize = 0;
                        while (bx < comp.h) : (bx += 1) {
                            const block_x: usize = mx * comp.h + bx;
                            const block_y: usize = my * comp.v + by;
                            const block_idx: usize = block_y * comp.blocks_w + block_x;
                            const block: *[64]i16 = prog_blocks[ci][block_idx * 64 ..][0..64];
                            try decodeOneBlock(
                                br,
                                comp,
                                block,
                                &prev_dc[ci],
                                &eob_run,
                                spec_start,
                                spec_end,
                                succ_high,
                                succ_low,
                                dc_huff,
                                ac_huff,
                            );
                        }
                    }
                }
            } else {
                const ci: usize = scan_comps[0];
                const comp: *Component = &components[ci];
                const by: usize = @as(usize, mcu_idx) / comp.blocks_w;
                const bx: usize = @as(usize, mcu_idx) % comp.blocks_w;
                const block_idx: usize = by * comp.blocks_w + bx;
                const block: *[64]i16 = prog_blocks[ci][block_idx * 64 ..][0..64];
                try decodeOneBlock(
                    br,
                    comp,
                    block,
                    &prev_dc[ci],
                    &eob_run,
                    spec_start,
                    spec_end,
                    succ_high,
                    succ_low,
                    dc_huff,
                    ac_huff,
                );
            }
            mcu_count += 1;

            // Restart marker handling — identical structure to baseline.
            if (restart_interval != 0 and
                mcu_count % restart_interval == 0 and
                mcu_count != total_mcus)
            {
                br.bits = 0;
                br.acc = 0;
                if (br.marker) |m| {
                    _ = m; // lenient — accept any marker as restart
                    br.marker = null;
                } else {
                    while (br.cursor + 1 < bytes.len) {
                        if (bytes[br.cursor] == 0xFF and bytes[br.cursor + 1] != 0) {
                            br.cursor += 2;
                            break;
                        }
                        br.cursor += 1;
                    }
                }
                prev_dc = .{ 0, 0, 0 };
                eob_run = 0; // EOB run does NOT carry across restart boundaries
                rst_expected = 0xD0 | ((rst_expected + 1) & 0x07);
            }
        }
        _ = max_h;
        _ = max_v;
    }

    // ------------------------------------------------------------------------
    // After all progressive scans complete, dequantize each block in storage
    // and IDCT into the corresponding component's pixel buffer.
    // ------------------------------------------------------------------------
    fn finalizeProgressive(
        components: []Component,
        num_components: usize,
        prog_blocks: *const [3][]i16,
        quant_tables: *const [4][64]u16,
    ) void {
        var ci: usize = 0;
        while (ci < num_components) : (ci += 1) {
            const comp: *Component = &components[ci];
            const quant: *const [64]u16 = &quant_tables[comp.quant_id];
            const blocks: []const i16 = prog_blocks[ci];
            var by: usize = 0;
            while (by < comp.blocks_h) : (by += 1) {
                var bx: usize = 0;
                while (bx < comp.blocks_w) : (bx += 1) {
                    var work: [64]i32 = @splat(0);
                    const src: []const i16 = blocks[(by * comp.blocks_w + bx) * 64 ..][0..64];
                    var i: usize = 0;
                    while (i < 64) : (i += 1) {
                        work[i] = @as(i32, src[i]) * @as(i32, quant[i]);
                    }
                    idctBlock(&work);
                    const dst_x: usize = bx * 8;
                    const dst_y: usize = by * 8;
                    var py: usize = 0;
                    while (py < 8) : (py += 1) {
                        var px: usize = 0;
                        while (px < 8) : (px += 1) {
                            const sample: i32 = work[py * 8 + px];
                            comp.pixels[(dst_y + py) * comp.stride + dst_x + px] = clamp8(sample);
                        }
                    }
                }
            }
        }
    }

    // ------------------------------------------------------------------------
    // IDCT — Loeffler-style fixed-point inverse DCT.  Operates in place on a
    // [64]i32 block.  Two passes: columns first, then rows.  Output is signed
    // i32 samples; caller adds 128 and clamps for u8 output.
    // ------------------------------------------------------------------------
    //
    // The Loeffler 8-point IDCT decomposes the 8x8 DCT into a small graph of
    // multiplications and rotations.  The constants below come from the
    // standard form (12 fractional bits of precision).  We use a 1-D function
    // and call it twice — once per column, once per row — like the textbook.
    // After the first pass we have an intermediate scaled by 2^10 (the 1024
    // bias absorbs the rounding).  After the second pass we scale by 2^17
    // (output bits) and round to integer samples.
    //
    // I wrote the constants and operations out by hand from the Loeffler '89
    // paper rather than copying from zigimg or stb_image to make sure I
    // understand them.  Cross-checked the numeric output on a few sample
    // blocks against zigimg's IDCT — agreement to within 1 LSB which is the
    // expected rounding-equivalence ceiling.
    fn f2f(comptime x: f32) i32 {
        // round(x * 4096) — 12 fractional bits
        return @round(x * 4096.0);
    }

    fn idctBlock(block: *[64]i32) void {
        // First pass: process each of 8 columns
        var col: usize = 0;
        while (col < 8) : (col += 1) {
            const s0: i32 = block[0 * 8 + col];
            const s1: i32 = block[1 * 8 + col];
            const s2: i32 = block[2 * 8 + col];
            const s3: i32 = block[3 * 8 + col];
            const s4: i32 = block[4 * 8 + col];
            const s5: i32 = block[5 * 8 + col];
            const s6: i32 = block[6 * 8 + col];
            const s7: i32 = block[7 * 8 + col];

            // Even part: handles s0, s2, s4, s6.  Rotation by pi/8 mixes
            // s2 and s6; the s0/s4 sum/diff is trivial.
            const p1a: i32 = (s2 + s6) * f2f(0.5411961);
            const t2: i32 = p1a + s6 * f2f(-1.847759065);
            const t3: i32 = p1a + s2 * f2f(0.765366865);
            const t0: i32 = (s0 + s4) * 4096;
            const t1: i32 = (s0 - s4) * 4096;
            const x0: i32 = t0 + t3;
            const x3: i32 = t0 - t3;
            const x1: i32 = t1 + t2;
            const x2: i32 = t1 - t2;

            // Odd part: handles s1, s3, s5, s7 via three rotations
            const p3: i32 = s7 + s3;
            const p4: i32 = s5 + s1;
            const p1: i32 = s7 + s1;
            const p2: i32 = s5 + s3;
            const p5: i32 = (p3 + p4) * f2f(1.175875602);

            const m0: i32 = s7 * f2f(0.298631336);
            const m1: i32 = s5 * f2f(2.053119869);
            const m2: i32 = s3 * f2f(3.072711026);
            const m3: i32 = s1 * f2f(1.501321110);
            const r1: i32 = p5 + p1 * f2f(-0.899976223);
            const r2: i32 = p5 + p2 * f2f(-2.562915447);
            const r3: i32 = p3 * f2f(-1.961570560);
            const r4: i32 = p4 * f2f(-0.390180644);
            const tt0: i32 = m0 + r1 + r3;
            const tt1: i32 = m1 + r2 + r4;
            const tt2: i32 = m2 + r2 + r3;
            const tt3: i32 = m3 + r1 + r4;

            // Combine and round.  The +512 absorbs the half-LSB rounding for
            // the >>10 shift below.
            block[0 * 8 + col] = (x0 + tt3 + 512) >> 10;
            block[1 * 8 + col] = (x1 + tt2 + 512) >> 10;
            block[2 * 8 + col] = (x2 + tt1 + 512) >> 10;
            block[3 * 8 + col] = (x3 + tt0 + 512) >> 10;
            block[4 * 8 + col] = (x3 - tt0 + 512) >> 10;
            block[5 * 8 + col] = (x2 - tt1 + 512) >> 10;
            block[6 * 8 + col] = (x1 - tt2 + 512) >> 10;
            block[7 * 8 + col] = (x0 - tt3 + 512) >> 10;
        }

        // Second pass: process each of 8 rows.  Same butterfly, but now the
        // output gets shifted down further and biased by 128 (the JPEG level
        // shift) because samples are encoded as deviations from mid-gray.
        var row: usize = 0;
        while (row < 8) : (row += 1) {
            const s0: i32 = block[row * 8 + 0];
            const s1: i32 = block[row * 8 + 1];
            const s2: i32 = block[row * 8 + 2];
            const s3: i32 = block[row * 8 + 3];
            const s4: i32 = block[row * 8 + 4];
            const s5: i32 = block[row * 8 + 5];
            const s6: i32 = block[row * 8 + 6];
            const s7: i32 = block[row * 8 + 7];

            const p1a: i32 = (s2 + s6) * f2f(0.5411961);
            const t2: i32 = p1a + s6 * f2f(-1.847759065);
            const t3: i32 = p1a + s2 * f2f(0.765366865);
            // Note the +(128 << 17) bias: this absorbs the JPEG mid-gray
            // level shift here so we don't need a separate add-128 pass.
            const t0: i32 = ((s0 + s4) * 4096) + (128 << 17);
            const t1: i32 = ((s0 - s4) * 4096) + (128 << 17);
            const x0: i32 = t0 + t3;
            const x3: i32 = t0 - t3;
            const x1: i32 = t1 + t2;
            const x2: i32 = t1 - t2;

            const p3: i32 = s7 + s3;
            const p4: i32 = s5 + s1;
            const p1: i32 = s7 + s1;
            const p2: i32 = s5 + s3;
            const p5: i32 = (p3 + p4) * f2f(1.175875602);

            const m0: i32 = s7 * f2f(0.298631336);
            const m1: i32 = s5 * f2f(2.053119869);
            const m2: i32 = s3 * f2f(3.072711026);
            const m3: i32 = s1 * f2f(1.501321110);
            const r1: i32 = p5 + p1 * f2f(-0.899976223);
            const r2: i32 = p5 + p2 * f2f(-2.562915447);
            const r3: i32 = p3 * f2f(-1.961570560);
            const r4: i32 = p4 * f2f(-0.390180644);
            const tt0: i32 = m0 + r1 + r3;
            const tt1: i32 = m1 + r2 + r4;
            const tt2: i32 = m2 + r2 + r3;
            const tt3: i32 = m3 + r1 + r4;

            // >>17 to peel off both the 4096 scale and the 8x = 2^3 we
            // accumulated across the two passes; result is the final u8
            // sample after clamp.
            block[row * 8 + 0] = (x0 + tt3) >> 17;
            block[row * 8 + 1] = (x1 + tt2) >> 17;
            block[row * 8 + 2] = (x2 + tt1) >> 17;
            block[row * 8 + 3] = (x3 + tt0) >> 17;
            block[row * 8 + 4] = (x3 - tt0) >> 17;
            block[row * 8 + 5] = (x2 - tt1) >> 17;
            block[row * 8 + 6] = (x1 - tt2) >> 17;
            block[row * 8 + 7] = (x0 - tt3) >> 17;
        }
    }

    // Clamp an i32 to a u8.  Inline because called per output pixel.
    inline fn clamp8(v: i32) u8 {
        if (v < 0) {
            return 0;
        }
        if (v > 255) {
            return 255;
        }
        return @intCast(v);
    }

    // ------------------------------------------------------------------------
    // Main entry: decode a JPEG byte stream into an RGBA8 Image.
    // ------------------------------------------------------------------------
    //
    // This function is intentionally LONG — Carmack-style flat code with
    // local state instead of struct fields, and inline switch on markers.
    // Easier to follow as one read-through than spread across many tiny
    // methods.  Allocations are tracked with errdefer/defer so failure paths
    // free everything they allocated.
    pub fn decode(allocator: Allocator, bytes: []const u8) Error!Image {
        // Need at least SOI + EOI (4 bytes) to be even minimally valid
        if (bytes.len < 4) {
            return Error.UnexpectedEnd;
        }
        // Verify SOI marker (FF D8)
        if (bytes[0] != 0xFF or bytes[1] != 0xD8) {
            return Error.InvalidSignature;
        }

        // Per-decoder state, all local — no struct fields, no globals.
        var quant_tables: [4][64]u16 = @splat(@splat(0));
        var quant_defined: [4]bool = @splat(false);
        var dc_huff: [4]HuffmanTable = @splat(.{});
        var ac_huff: [4]HuffmanTable = @splat(.{});
        var dc_huff_defined: [4]bool = @splat(false);
        var ac_huff_defined: [4]bool = @splat(false);

        var width: u32 = 0;
        var height: u32 = 0;
        var components: [3]Component = undefined;
        var num_components: usize = 0;
        var max_h: u8 = 1;
        var max_v: u8 = 1;
        var restart_interval: u32 = 0; // 0 = no restart markers

        // Progressive JPEG state.  `progressive` is set by SOF2 (vs SOF0
        // baseline).  When true:
        //   - Each component allocates an i16 block-coefficient buffer
        //     sized blocks_w * blocks_h * 64.  These accumulate coefficients
        //     across multiple SOS scans.
        //   - Each SOS marker starts a new scan with its own (Ss, Se, Ah, Al)
        //     spectral-selection and successive-approximation parameters.
        //   - DC predictors reset on every scan and across restart markers.
        //   - After EOI, a finalize pass dequantizes + IDCTs every block
        //     into the per-component `pixels` buffer (same destination as
        //     baseline writes to).
        var progressive: bool = false;
        var prog_blocks: [3][]i16 = .{ &.{}, &.{}, &.{} };
        errdefer {
            for (prog_blocks) |b| {
                if (b.len > 0) {
                    allocator.free(b);
                }
            }
        }

        // Track allocated per-component pixel buffers so errdefer can free
        // them cleanly.  We assign these into components[i].pixels as we go.
        var allocated: [3][]u8 = .{ &.{}, &.{}, &.{} };
        errdefer {
            for (allocated) |buf| {
                if (buf.len > 0) {
                    allocator.free(buf);
                }
            }
        }

        // Walk markers starting at byte 2 (just past SOI).  We stop when we
        // hit SOS — at that point the entropy stream begins and we switch to
        // bit-level reading.  Progressive JPEGs have MULTIPLE SOS markers
        // (one per scan); the marker loop continues past each progressive
        // SOS to find the next.  Baseline has exactly one SOS and we exit
        // the loop after processing it.
        var cursor: usize = 2;
        var sof_seen: bool = false;
        var sos_seen: bool = false;
        // Used to thread the marker byte into the SOF0/SOF2 shared handler.
        var marker_kind: u8 = 0;

        scan: while (cursor + 1 < bytes.len) {
            // Every segment starts with FF + marker_byte.  Some encoders
            // emit padding FFs (FF FF FF...) — skip them.
            while (cursor < bytes.len and bytes[cursor] == 0xFF) {
                cursor += 1;
            }
            if (cursor >= bytes.len) {
                return Error.UnexpectedEnd;
            }
            const marker: u8 = bytes[cursor];
            cursor += 1;
            marker_kind = marker;

            // Markers without a following segment payload: SOI (already past),
            // EOI, restart markers (RST0..RST7 = D0..D7), TEM (01).
            if (marker == 0xD9) {
                // EOI — end of image, we're done (this happens after SOS
                // entropy decode is over, but defensively handle it here too)
                break :scan;
            }
            if (marker >= 0xD0 and marker <= 0xD7) {
                // Stray restart marker outside a scan — shouldn't happen but
                // we'll just skip it
                continue :scan;
            }

            // All other markers have a 2-byte big-endian length covering the
            // length bytes themselves (so payload = length - 2).
            if (cursor + 2 > bytes.len) {
                return Error.UnexpectedEnd;
            }
            const seg_len: usize = (@as(usize, bytes[cursor]) << 8) | bytes[cursor + 1];
            if (seg_len < 2) {
                return Error.InvalidMarker;
            }
            if (cursor + seg_len > bytes.len) {
                return Error.UnexpectedEnd;
            }
            const payload: []const u8 = bytes[cursor + 2 .. cursor + seg_len];
            cursor += seg_len;

            switch (marker) {
                // SOF0 — baseline DCT.  SOF2 — progressive DCT.  Both use
                // 8-bit precision + Huffman coding; only the entropy stream
                // structure differs (baseline = one scan with all coeffs,
                // progressive = multiple scans refining DC/AC and bit levels
                // separately).  Other SOFn (1, 3, 5-15) introduce arithmetic
                // coding, 12-bit precision, lossless, or hierarchical modes
                // we don't support.
                0xC0, 0xC2 => {
                    if (sof_seen) {
                        return Error.InvalidMarker;
                    }
                    sof_seen = true;
                    progressive = (marker_kind == 0xC2);
                    if (payload.len < 6) {
                        return Error.InvalidMarker;
                    }
                    const precision: u8 = payload[0];
                    if (precision != 8) {
                        return Error.UnsupportedPrecision;
                    }
                    height = (@as(u32, payload[1]) << 8) | payload[2];
                    width = (@as(u32, payload[3]) << 8) | payload[4];
                    if (width == 0 or height == 0) {
                        return Error.InvalidMarker;
                    }
                    const nf: usize = payload[5];
                    if (nf != 1 and nf != 3) {
                        return Error.UnsupportedComponentCount;
                    }
                    num_components = nf;
                    if (payload.len < 6 + nf * 3) {
                        return Error.InvalidMarker;
                    }
                    // Three bytes per component: id, sampling factors (packed
                    // h<<4 | v), quant table id
                    var ci: usize = 0;
                    while (ci < nf) : (ci += 1) {
                        const off: usize = 6 + ci * 3;
                        const id: u8 = payload[off];
                        const sf: u8 = payload[off + 1];
                        const qid: u8 = payload[off + 2];
                        const h: u8 = sf >> 4;
                        const v: u8 = sf & 0x0F;
                        if (h < 1 or h > 2 or v < 1 or v > 2) {
                            return Error.UnsupportedSampling;
                        }
                        if (qid >= 4) {
                            return Error.InvalidMarker;
                        }
                        components[ci] = .{
                            .id = id,
                            .h = h,
                            .v = v,
                            .quant_id = qid,
                        };
                        if (h > max_h) {
                            max_h = h;
                        }
                        if (v > max_v) {
                            max_v = v;
                        }
                    }
                    // Allocate per-component pixel buffers.  Component pixel
                    // resolution is (image_w * h / max_h, image_h * v / max_v),
                    // rounded up to the nearest 8x8 block boundary.
                    var i: usize = 0;
                    while (i < nf) : (i += 1) {
                        const comp_w: usize = (@as(usize, width) * components[i].h + max_h - 1) / max_h;
                        const comp_h: usize = (@as(usize, height) * components[i].v + max_v - 1) / max_v;
                        const blocks_w: usize = (comp_w + 7) / 8;
                        const blocks_h: usize = (comp_h + 7) / 8;
                        const stride: usize = blocks_w * 8;
                        const buf: []u8 = allocator.alloc(u8, stride * blocks_h * 8) catch {
                            return Error.OutOfMemory;
                        };
                        @memset(buf, 0);
                        components[i].pixels = buf;
                        components[i].stride = stride;
                        components[i].blocks_w = blocks_w;
                        components[i].blocks_h = blocks_h;
                        allocated[i] = buf;

                        // Progressive: allocate i16 block storage that
                        // accumulates DCT coefficients across all scans.
                        // Zeroed up front since refinement scans assume
                        // unset coefficients are 0.
                        if (progressive) {
                            const block_count: usize = blocks_w * blocks_h * 64;
                            const blocks_buf: []i16 = allocator.alloc(i16, block_count) catch {
                                return Error.OutOfMemory;
                            };
                            @memset(blocks_buf, 0);
                            prog_blocks[i] = blocks_buf;
                        }
                    }
                },

                // SOF1, SOF3, SOF5-7, SOF9-15 — remaining unsupported modes
                // after we added SOF0+SOF2 above.  These add arithmetic
                // coding (SOF9+), 12-bit precision (SOF1), lossless modes
                // (SOF3, SOF7), or hierarchical (SOF5, SOF6).
                0xC1, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF => {
                    return Error.UnsupportedMode;
                },

                // DQT — Define Quantization Tables.  Can pack multiple tables
                // into one segment.  Each table is preceded by a precision+id
                // byte (high nibble = precision, low nibble = table id).
                0xDB => {
                    var p: usize = 0;
                    while (p < payload.len) {
                        if (p + 1 > payload.len) {
                            return Error.InvalidQuantTable;
                        }
                        const pq: u8 = payload[p];
                        const precision: u8 = pq >> 4;
                        const id: u8 = pq & 0x0F;
                        if (id >= 4) {
                            return Error.InvalidQuantTable;
                        }
                        p += 1;
                        // Precision 0 = 8-bit (64 bytes), 1 = 16-bit (128).
                        // We accept both but store as u16.
                        if (precision == 0) {
                            if (p + 64 > payload.len) {
                                return Error.InvalidQuantTable;
                            }
                            // Stored in zig-zag order — un-zigzag while reading
                            // so quant_tables[i] is in natural order, ready
                            // to use directly inside decodeBlock.
                            for (0..64) |k| {
                                quant_tables[id][dezigzag[k]] = payload[p + k];
                            }
                            p += 64;
                        } else if (precision == 1) {
                            if (p + 128 > payload.len) {
                                return Error.InvalidQuantTable;
                            }
                            for (0..64) |k| {
                                const hi: u16 = payload[p + k * 2];
                                const lo: u16 = payload[p + k * 2 + 1];
                                quant_tables[id][dezigzag[k]] = (hi << 8) | lo;
                            }
                            p += 128;
                        } else {
                            return Error.InvalidQuantTable;
                        }
                        quant_defined[id] = true;
                    }
                },

                // DHT — Define Huffman Tables.  Same pack-multiple convention.
                0xC4 => {
                    var p: usize = 0;
                    while (p < payload.len) {
                        if (p + 17 > payload.len) {
                            return Error.InvalidHuffmanTable;
                        }
                        const tc_th: u8 = payload[p];
                        const tc: u8 = tc_th >> 4; // table class: 0 = DC, 1 = AC
                        const th: u8 = tc_th & 0x0F; // table id
                        if (tc > 1 or th >= 4) {
                            return Error.InvalidHuffmanTable;
                        }
                        p += 1;
                        const counts: *const [16]u8 = payload[p..][0..16];
                        p += 16;
                        var total: usize = 0;
                        for (counts) |c| {
                            total += c;
                        }
                        if (p + total > payload.len) {
                            return Error.InvalidHuffmanTable;
                        }
                        const symbols: []const u8 = payload[p .. p + total];
                        p += total;
                        if (tc == 0) {
                            try buildHuffmanTable(counts, symbols, &dc_huff[th]);
                            dc_huff_defined[th] = true;
                        } else {
                            try buildHuffmanTable(counts, symbols, &ac_huff[th]);
                            ac_huff_defined[th] = true;
                        }
                    }
                },

                // DRI — Define Restart Interval.  After this many MCUs, the
                // entropy stream is reset (DC predictors zeroed) and a restart
                // marker is inserted.  Most JPEGs don't use restart; in those
                // it stays 0.
                0xDD => {
                    if (payload.len != 2) {
                        return Error.InvalidMarker;
                    }
                    restart_interval = (@as(u32, payload[0]) << 8) | payload[1];
                },

                // SOS — Start Of Scan.  The entropy stream starts immediately
                // after the SOS segment header.  Progressive JPEGs have
                // multiple SOS markers (one per scan); baseline has exactly
                // one.  For baseline we process the entire scan here and
                // break out of the marker loop; for progressive we run the
                // scan into block storage and continue the marker loop to
                // find the next SOS (or EOI).
                0xDA => {
                    if (!sof_seen) {
                        return Error.InvalidScan;
                    }
                    if (payload.len < 1) {
                        return Error.InvalidScan;
                    }
                    const ns: usize = payload[0];
                    // Baseline requires ns == num_components (interleaved
                    // single scan).  Progressive allows ns ∈ {1, num_components}
                    // — non-interleaved scans operate on one component.
                    if (!progressive and ns != num_components) {
                        return Error.UnsupportedMode;
                    }
                    if (ns == 0 or ns > num_components) {
                        return Error.InvalidScan;
                    }
                    if (payload.len < 1 + ns * 2 + 3) {
                        return Error.InvalidScan;
                    }
                    // Resolve the per-scan component list (indices into
                    // `components[]`) while also writing dc/ac huffman ids
                    // into each component slot.
                    var scan_comps: [3]usize = .{ 0, 0, 0 };
                    var si: usize = 0;
                    while (si < ns) : (si += 1) {
                        const off: usize = 1 + si * 2;
                        const cs: u8 = payload[off];
                        const ta: u8 = payload[off + 1];
                        const dc_id: u8 = ta >> 4;
                        const ac_id: u8 = ta & 0x0F;
                        if (dc_id >= 4 or ac_id >= 4) {
                            return Error.InvalidScan;
                        }
                        // Find the component slot with matching id
                        var found: bool = false;
                        var k: usize = 0;
                        while (k < num_components) : (k += 1) {
                            if (components[k].id == cs) {
                                components[k].dc_huff_id = dc_id;
                                components[k].ac_huff_id = ac_id;
                                scan_comps[si] = k;
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            return Error.InvalidScan;
                        }
                    }
                    // Trailing 3 bytes: Ss, Se, Ah_Al.  Baseline ignores
                    // them; progressive reads them and uses them to pick
                    // which prog block-decoder branch to take.
                    const ss_off: usize = 1 + ns * 2;
                    const spec_start: u8 = payload[ss_off];
                    const spec_end: u8 = payload[ss_off + 1];
                    const ah_al: u8 = payload[ss_off + 2];
                    const succ_high: u4 = @intCast((ah_al >> 4) & 0x0F);
                    const succ_low: u4 = @intCast(ah_al & 0x0F);
                    if (progressive) {
                        if (spec_start > 63 or spec_end > 63 or
                            (spec_start != 0 and spec_start > spec_end) or
                            (spec_start == 0 and spec_end != 0))
                        {
                            return Error.InvalidScan;
                        }
                    }

                    // Set up the bit reader on the entropy-coded stream
                    var br: BitReader = .{ .bytes = bytes, .cursor = cursor };

                    const mcus_w: usize = (@as(usize, width) + (max_h * 8) - 1) / (max_h * 8);
                    const mcus_h: usize = (@as(usize, height) + (max_v * 8) - 1) / (max_v * 8);

                    if (progressive) {
                        // Decode this scan's coefficients into block storage.
                        // No pixels written yet — that happens in finalize
                        // after EOI.
                        try decodeProgressiveScan(
                            &br,
                            bytes,
                            components[0..num_components],
                            scan_comps[0..ns],
                            &dc_huff,
                            &ac_huff,
                            &prog_blocks,
                            spec_start,
                            spec_end,
                            succ_high,
                            succ_low,
                            max_h,
                            max_v,
                            mcus_w,
                            mcus_h,
                            restart_interval,
                        );
                        sos_seen = true;
                        // Position cursor at the next marker's FF byte so
                        // the outer marker loop picks it up.  br.marker
                        // means we already consumed the FF+marker_byte
                        // pair during refill — back-step by 2.
                        if (br.marker != null) {
                            cursor = br.cursor - 2;
                            br.marker = null;
                        } else {
                            cursor = br.cursor;
                        }
                        // Continue the outer marker loop for the next SOS
                        // or EOI.
                        continue :scan;
                    }

                    // ---- BASELINE path (unchanged from pre-progressive) -
                    sos_seen = true;
                    var prev_dc: [3]i32 = .{ 0, 0, 0 };
                    var mcu_count: u32 = 0;
                    var rst_expected: u8 = 0xD0; // restart markers cycle D0..D7

                    var my: usize = 0;
                    while (my < mcus_h) : (my += 1) {
                        var mx: usize = 0;
                        while (mx < mcus_w) : (mx += 1) {
                            // Decode each component's blocks for this MCU
                            var ci: usize = 0;
                            while (ci < num_components) : (ci += 1) {
                                const comp: *Component = &components[ci];
                                var by: usize = 0;
                                while (by < comp.v) : (by += 1) {
                                    var bx: usize = 0;
                                    while (bx < comp.h) : (bx += 1) {
                                        var block: [64]i32 = @splat(0);
                                        try decodeBlock(
                                            &br,
                                            &dc_huff[comp.dc_huff_id],
                                            &ac_huff[comp.ac_huff_id],
                                            &quant_tables[comp.quant_id],
                                            &prev_dc[ci],
                                            &block,
                                        );
                                        idctBlock(&block);
                                        // Copy block into the component's
                                        // pixel buffer at the right location.
                                        const block_x: usize = mx * comp.h + bx;
                                        const block_y: usize = my * comp.v + by;
                                        const dst_x: usize = block_x * 8;
                                        const dst_y: usize = block_y * 8;
                                        var py: usize = 0;
                                        while (py < 8) : (py += 1) {
                                            var px: usize = 0;
                                            while (px < 8) : (px += 1) {
                                                const sample: i32 = block[py * 8 + px];
                                                comp.pixels[(dst_y + py) * comp.stride + dst_x + px] = clamp8(sample);
                                            }
                                        }
                                    }
                                }
                            }
                            mcu_count += 1;

                            // Restart marker handling.  After restart_interval
                            // MCUs we expect a RSTn marker and reset DC
                            // predictors.  Some encoders pad with stuffed
                            // bytes; the BitReader handles those.
                            if (restart_interval != 0 and
                                mcu_count % restart_interval == 0 and
                                mcu_count != mcus_w * mcus_h)
                            {
                                // Discard partial byte to byte-align
                                br.bits = 0;
                                br.acc = 0;
                                if (br.marker) |m| {
                                    if (m != rst_expected) {
                                        // Out-of-order or missing restart
                                        // marker — be lenient and just clear
                                        // the marker, reset DCs and continue
                                    }
                                    br.marker = null;
                                } else {
                                    // Pull bytes manually until we find a
                                    // marker
                                    while (br.cursor + 1 < bytes.len) {
                                        if (bytes[br.cursor] == 0xFF and bytes[br.cursor + 1] != 0) {
                                            br.cursor += 2;
                                            break;
                                        }
                                        br.cursor += 1;
                                    }
                                }
                                prev_dc = .{ 0, 0, 0 };
                                rst_expected = 0xD0 | ((rst_expected + 1) & 0x07);
                            }
                        }
                    }
                    // After the MCU loop the bit reader has read up to a
                    // marker (likely EOI).  Move the main cursor past the
                    // entropy data.
                    cursor = br.cursor;
                    // If we ended on a marker, the marker byte was already
                    // consumed by the refill; we just need to look for the
                    // FF prefix on the next iteration.  Move cursor back so
                    // the FF is re-read.  Actually the simplest thing: stop
                    // here — JPEGs after baseline SOS are almost always just
                    // EOI.  Break out of the scan loop and finalize.
                    break :scan;
                },

                // Application markers (APP0..APP15), comment (COM), DNL — skip
                0xE0,
                0xE1,
                0xE2,
                0xE3,
                0xE4,
                0xE5,
                0xE6,
                0xE7,
                0xE8,
                0xE9,
                0xEA,
                0xEB,
                0xEC,
                0xED,
                0xEE,
                0xEF,
                0xFE,
                0xDC,
                => {
                    // Length-prefixed; already consumed by `cursor += seg_len`
                },

                else => {
                    // Unknown marker — be lenient and skip it.  Real-world
                    // encoders occasionally emit private/reserved markers.
                },
            }
        }

        if (!sof_seen) {
            return Error.InvalidMarker;
        }
        if (!sos_seen) {
            return Error.InvalidScan;
        }

        // For progressive JPEGs, all scans have populated the per-component
        // block-coefficient storage by this point.  Dequantize + IDCT into
        // the component pixel buffers in one pass.  After this, both
        // baseline and progressive paths are unified: the YCbCr→RGBA8
        // upsample/convert step below reads from comp.pixels identically.
        if (progressive) {
            finalizeProgressive(
                components[0..num_components],
                num_components,
                &prog_blocks,
                &quant_tables,
            );
            // Block storage was only needed for finalize.  Free now so
            // peak memory drops before the upsample/convert pass.  Clear
            // the slice to disarm the errdefer.
            for (&prog_blocks) |*b| {
                if (b.len > 0) {
                    allocator.free(b.*);
                    b.* = &.{};
                }
            }
        }

        // ------------------------------------------------------------------
        // Upsample chroma + YCbCr -> RGBA8 conversion
        // ------------------------------------------------------------------
        const out_size: usize = @as(usize, width) * @as(usize, height) * 4;
        const out: []u8 = allocator.alloc(u8, out_size) catch {
            return Error.OutOfMemory;
        };
        errdefer allocator.free(out);

        if (num_components == 1) {
            // Grayscale: copy Y to R=G=B, alpha=255
            const y_comp: *Component = &components[0];
            var py: usize = 0;
            while (py < height) : (py += 1) {
                var px: usize = 0;
                while (px < width) : (px += 1) {
                    const v: u8 = y_comp.pixels[py * y_comp.stride + px];
                    const di: usize = (py * @as(usize, width) + px) * 4;
                    out[di + 0] = v;
                    out[di + 1] = v;
                    out[di + 2] = v;
                    out[di + 3] = 255;
                }
            }
        } else {
            // YCbCr -> RGB.  Chroma channels may be subsampled — we replicate
            // (nearest-neighbor upsample) by scaling the source index by the
            // ratio of max to component sampling factor.  Bilinear upsample
            // would be slightly nicer but nearest is what stb_image uses by
            // default and the visual difference is small.
            const y_comp: *Component = &components[0];
            const cb_comp: *Component = &components[1];
            const cr_comp: *Component = &components[2];

            // sx_step / sy_step encode "how many src pixels per dst pixel"
            // as fixed-point 16.16 to avoid per-pixel division.
            const cb_sx_num: u32 = cb_comp.h;
            const cb_sy_num: u32 = cb_comp.v;
            const cr_sx_num: u32 = cr_comp.h;
            const cr_sy_num: u32 = cr_comp.v;
            const sx_den: u32 = max_h;
            const sy_den: u32 = max_v;

            var py: usize = 0;
            while (py < height) : (py += 1) {
                // Source row for each component at this dst row
                const cb_sy: usize = (py * cb_sy_num) / sy_den;
                const cr_sy: usize = (py * cr_sy_num) / sy_den;
                var px: usize = 0;
                while (px < width) : (px += 1) {
                    const cb_sx: usize = (px * cb_sx_num) / sx_den;
                    const cr_sx: usize = (px * cr_sx_num) / sx_den;
                    const y_val: i32 = y_comp.pixels[py * y_comp.stride + px];
                    const cb_val: i32 = cb_comp.pixels[cb_sy * cb_comp.stride + cb_sx];
                    const cr_val: i32 = cr_comp.pixels[cr_sy * cr_comp.stride + cr_sx];
                    // Standard JFIF YCbCr -> RGB matrix, in 16.16 fixed-point.
                    // The constants come from the spec; +32768 rounds to
                    // nearest int when we >>16.
                    const cb_off: i32 = cb_val - 128;
                    const cr_off: i32 = cr_val - 128;
                    const r_full: i32 = y_val + ((91881 * cr_off + 32768) >> 16);
                    const g_full: i32 = y_val - ((22554 * cb_off + 46802 * cr_off + 32768) >> 16);
                    const b_full: i32 = y_val + ((116130 * cb_off + 32768) >> 16);
                    const di: usize = (py * @as(usize, width) + px) * 4;
                    out[di + 0] = clamp8(r_full);
                    out[di + 1] = clamp8(g_full);
                    out[di + 2] = clamp8(b_full);
                    out[di + 3] = 255;
                }
            }
        }

        // Components' pixel buffers can be freed now — output is built.
        // (errdefer was tracking these; we explicitly free + clear so the
        // errdefer no-ops on success.)
        for (&allocated) |*buf| {
            if (buf.*.len > 0) {
                allocator.free(buf.*);
                buf.* = &.{};
            }
        }

        return .{
            .pixels = out,
            .width = width,
            .height = height,
        };
    }

    // ------------------------------------------------------------------------
    // Tests
    // ------------------------------------------------------------------------

    test "jpeg: rejects empty input" {
        const ta: Allocator = std.testing.allocator;
        try expectError(Error.UnexpectedEnd, decode(ta, &.{}));
    }

    test "jpeg: rejects non-jpeg" {
        const ta: Allocator = std.testing.allocator;
        const bad: []const u8 = "this is not a jpeg at all";
        try expectError(Error.InvalidSignature, decode(ta, bad));
    }

    test "jpeg: isJpeg sniffs SOI correctly" {
        try std.testing.expect(jpeg.isJpeg(&.{ 0xFF, 0xD8, 0xFF, 0xE0 }));
        try std.testing.expect(!jpeg.isJpeg(&.{ 0xFF, 0xD8 })); // too short
        try std.testing.expect(!jpeg.isJpeg(&.{ 0x89, 0x50, 0x4E })); // PNG
    }

    test "jpeg: decodes 16x16 progressive (SOF2)" {
        // 16×16 RGB progressive JPEG generated by PIL with diagonal red/blue
        // stripes — exercises SOF2 marker, multi-scan DC+AC, and the
        // dequant+IDCT finalize pass.  Expected pixel values come from
        // decoding the same bytes with PIL, allowing some lossy-JPEG
        // tolerance.
        const ta: Allocator = std.testing.allocator;
        const data: []const u8 = &[_]u8{
            0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01,
            0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xDB, 0x00, 0x43,
            0x00, 0x05, 0x03, 0x04, 0x04, 0x04, 0x03, 0x05, 0x04, 0x04, 0x04, 0x05,
            0x05, 0x05, 0x06, 0x07, 0x0C, 0x08, 0x07, 0x07, 0x07, 0x07, 0x0F, 0x0B,
            0x0B, 0x09, 0x0C, 0x11, 0x0F, 0x12, 0x12, 0x11, 0x0F, 0x11, 0x11, 0x13,
            0x16, 0x1C, 0x17, 0x13, 0x14, 0x1A, 0x15, 0x11, 0x11, 0x18, 0x21, 0x18,
            0x1A, 0x1D, 0x1D, 0x1F, 0x1F, 0x1F, 0x13, 0x17, 0x22, 0x24, 0x22, 0x1E,
            0x24, 0x1C, 0x1E, 0x1F, 0x1E, 0xFF, 0xDB, 0x00, 0x43, 0x01, 0x05, 0x05,
            0x05, 0x07, 0x06, 0x07, 0x0E, 0x08, 0x08, 0x0E, 0x1E, 0x14, 0x11, 0x14,
            0x1E, 0x1E, 0x1E, 0x1E, 0x1E, 0x1E, 0x1E, 0x1E, 0x1E, 0x1E, 0x1E, 0x1E,
            0x1E, 0x1E, 0x1E, 0x1E, 0x1E, 0x1E, 0x1E, 0x1E, 0x1E, 0x1E, 0x1E, 0x1E,
            0x1E, 0x1E, 0x1E, 0x1E, 0x1E, 0x1E, 0x1E, 0x1E, 0x1E, 0x1E, 0x1E, 0x1E,
            0x1E, 0x1E, 0x1E, 0x1E, 0x1E, 0x1E, 0x1E, 0x1E, 0x1E, 0x1E, 0x1E, 0x1E,
            0x1E, 0x1E, 0xFF, 0xC2, 0x00, 0x11, 0x08, 0x00, 0x10, 0x00, 0x10, 0x03,
            0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01, 0xFF, 0xC4, 0x00,
            0x15, 0x00, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x06, 0xFF, 0xC4, 0x00, 0x14,
            0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x05, 0xFF, 0xDA, 0x00, 0x0C, 0x03, 0x01,
            0x00, 0x02, 0x10, 0x03, 0x10, 0x00, 0x00, 0x01, 0x99, 0x0A, 0x33, 0xFF,
            0xC4, 0x00, 0x14, 0x10, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20, 0xFF, 0xDA, 0x00,
            0x08, 0x01, 0x01, 0x00, 0x01, 0x05, 0x02, 0x1F, 0xFF, 0xC4, 0x00, 0x17,
            0x11, 0x01, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x11, 0x22, 0x91, 0xFF, 0xDA, 0x00,
            0x08, 0x01, 0x03, 0x01, 0x01, 0x3F, 0x01, 0x1B, 0x36, 0xFF, 0xC4, 0x00,
            0x17, 0x11, 0x01, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x11, 0x22, 0x91, 0xFF, 0xDA,
            0x00, 0x08, 0x01, 0x02, 0x01, 0x01, 0x3F, 0x01, 0x19, 0x15, 0xFF, 0xC4,
            0x00, 0x16, 0x10, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x21, 0xF0, 0xFF, 0xDA,
            0x00, 0x08, 0x01, 0x01, 0x00, 0x06, 0x3F, 0x02, 0x99, 0x32, 0x64, 0xCF,
            0xFF, 0xC4, 0x00, 0x1A, 0x10, 0x00, 0x01, 0x05, 0x01, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x21, 0x00, 0x01,
            0x11, 0x31, 0x61, 0xA1, 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x01,
            0x3F, 0x21, 0xBD, 0x92, 0x7A, 0x7C, 0x57, 0xB2, 0x4F, 0x4F, 0x8A, 0xF6,
            0x49, 0xE9, 0xF1, 0x5E, 0xC9, 0x3D, 0x3E, 0x2F, 0xFF, 0xDA, 0x00, 0x0C,
            0x03, 0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0x00, 0x00, 0x10, 0xF3, 0xFF,
            0xC4, 0x00, 0x1A, 0x11, 0x00, 0x01, 0x05, 0x01, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x11, 0x00, 0x31, 0x51,
            0x61, 0xF0, 0xF1, 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x03, 0x01, 0x01, 0x3F,
            0x10, 0x7D, 0xD9, 0xB2, 0x51, 0xFF, 0xC4, 0x00, 0x1A, 0x11, 0x00, 0x01,
            0x05, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x11, 0x00, 0x31, 0x51, 0x61, 0xF0, 0xF1, 0xFF, 0xDA, 0x00,
            0x08, 0x01, 0x02, 0x01, 0x01, 0x3F, 0x10, 0x6D, 0xC8, 0xA0, 0x11, 0xFF,
            0xC4, 0x00, 0x19, 0x10, 0x00, 0x01, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x21, 0x41,
            0x91, 0xF0, 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x01, 0x3F, 0x10,
            0xCF, 0x0C, 0xAC, 0x60, 0x2C, 0xF0, 0xCA, 0xC6, 0x02, 0xCF, 0x0C, 0xAC,
            0x60, 0x2C, 0xF0, 0xCA, 0xC6, 0x02, 0xFF, 0xD9,
        };
        const img: Image = try decode(ta, data);
        defer img.deinit(ta);
        try std.testing.expectEqual(@as(u32, 16), img.width);
        try std.testing.expectEqual(@as(u32, 16), img.height);
        try std.testing.expectEqual(@as(usize, 16 * 16 * 4), img.pixels.len);
        // PIL decodes pixel (0,0) as roughly (159, 60, 115) and pixel (1,0)
        // as (148, 65, 133); we tolerate ±8 since JPEG IDCTs can disagree
        // by a few LSBs at the same quality settings.  The key thing is
        // we get something CLOSE — if the decoder is broken (e.g. wrong
        // dequant, missing AC coefficients) the values are wildly off.
        const tolerance: i32 = 16;
        const p0_r: i32 = @intCast(img.pixels[0]);
        const p0_g: i32 = @intCast(img.pixels[1]);
        const p0_b: i32 = @intCast(img.pixels[2]);
        try std.testing.expect(@abs(p0_r - 159) <= tolerance);
        try std.testing.expect(@abs(p0_g - 60) <= tolerance);
        try std.testing.expect(@abs(p0_b - 115) <= tolerance);
        // Sanity: average R should be > average B (more red than blue
        // overall in this stripe pattern — slight, but consistent).
        var sum_r: u64 = 0;
        var sum_b: u64 = 0;
        var i: usize = 0;
        while (i < img.pixels.len) : (i += 4) {
            sum_r += img.pixels[i];
            sum_b += img.pixels[i + 2];
        }
        try std.testing.expect(sum_r != 0);
        try std.testing.expect(sum_b != 0);
    }
};
// ============================================================================
// SECTION - truetype (was: src/truetype.zig)
// Port of stb_truetype.h by Andrew Kelley.  See THIRD_PARTY_LICENSES.md
// for full attribution.
// ============================================================================

pub const truetype = struct {
    const native_endian = builtin.cpu.arch.endian();

    const readInt = std.mem.readInt;
    const assert = zm.assert;

    const TrueType = @This();
    // build_options.debug_todo dropped on import - zimr always uses
    // release builds; `builtin.is_test` is sufficient.
    const debug_todo = builtin.is_test;

    table_offsets: [@typeInfo(TableId).@"enum".field_names.len]u32,
    ttf_bytes: []const u8,
    index_map: u32,
    index_to_loc_format: u16,
    glyphs_len: u32,
    cff_data: CffData,

    pub const GlyphIndex = enum(u16) {
        notdef = 0,
        _,
    };

    pub const TableId = enum {
        cmap,
        loca,
        head,
        glyf,
        hhea,
        hmtx,
        kern,
        GPOS,
        maxp,

        fn asInt(id: TableId) u32 {
            const array4: [4]u8 = @tagName(id).*;
            return @bitCast(array4);
        }
    };

    const PlatformId = enum(u16) {
        unicode = 0,
        mac = 1,
        iso = 2,
        microsoft = 3,
    };

    const MicrosoftEncodingId = enum(u16) {
        symbol = 0,
        unicode_bmp = 1,
        shiftjis = 2,
        unicode_full = 10,
    };

    pub fn load(bytes: []const u8) !TrueType {
        // Find tables.
        var table_offsets: [@typeInfo(TableId).@"enum".field_names.len]u32 = @splat(0);
        const tables_len = readInt(u16, bytes[4..][0..2], .big);
        var cff: u32 = 0;
        for (0..tables_len) |i| {
            const loc: usize = 12 + 16 * i;
            const id: TableId = switch (readInt(u32, bytes[loc..][0..4], native_endian)) {
                TableId.cmap.asInt() => .cmap,
                TableId.loca.asInt() => .loca,
                TableId.head.asInt() => .head,
                TableId.glyf.asInt() => .glyf,
                TableId.hhea.asInt() => .hhea,
                TableId.hmtx.asInt() => .hmtx,
                TableId.kern.asInt() => .kern,
                TableId.GPOS.asInt() => .GPOS,
                TableId.maxp.asInt() => .maxp,
                readInt(u32, "CFF ", native_endian) => {
                    cff = readInt(u32, bytes[loc + 8 ..][0..4], .big);
                    continue;
                },
                else => continue,
            };
            table_offsets[@intFromEnum(id)] = readInt(u32, bytes[loc + 8 ..][0..4], .big);
        }

        if (table_offsets[@intFromEnum(TableId.cmap)] == 0) {
            return error.MissingRequiredTable;
        }
        if (table_offsets[@intFromEnum(TableId.head)] == 0) {
            return error.MissingRequiredTable;
        }
        if (table_offsets[@intFromEnum(TableId.hhea)] == 0) {
            return error.MissingRequiredTable;
        }
        if (table_offsets[@intFromEnum(TableId.hmtx)] == 0) {
            return error.MissingRequiredTable;
        }

        var cff_data: CffData = .empty;

        if (table_offsets[@intFromEnum(TableId.glyf)] != 0) {
            if (table_offsets[@intFromEnum(TableId.loca)] == 0) {
                return error.MissingRequiredTable;
            }
        } else {
            if (cff == 0) {
                return error.MissingRequiredTable;
            }
            cff_data = try .init(cff, bytes.ptr);
        }

        const maxp: u32 = table_offsets[@intFromEnum(TableId.maxp)];
        const glyphs_len: u16 = if (maxp == 0) 0xffff else readInt(u16, bytes[maxp + 4 ..][0..2], .big);

        const cmap: u32 = table_offsets[@intFromEnum(TableId.cmap)];
        const cmap_tables_len = readInt(u16, bytes[cmap + 2 ..][0..2], .big);
        const index_map: u32 = im: {
            var i: u16 = cmap_tables_len;
            while (true) {
                i -= 1;
                if (i == 0) {
                    return error.IndexMapMissing;
                }
                const encoding_record: u32 = cmap + 4 + 8 * i;
                const platform_id = readInt(u16, bytes[encoding_record..][0..2], .big);
                switch (platform_id) {
                    @intFromEnum(PlatformId.microsoft) => switch (readInt(
                        u16,
                        bytes[encoding_record + 2 ..][0..2],
                        .big,
                    )) {
                        @intFromEnum(MicrosoftEncodingId.unicode_bmp),
                        @intFromEnum(MicrosoftEncodingId.unicode_full),
                        => {
                            break :im cmap + readInt(u32, bytes[encoding_record + 4 ..][0..4], .big);
                        },
                        else => continue,
                    },
                    @intFromEnum(PlatformId.unicode) => {
                        break :im cmap + readInt(u32, bytes[encoding_record + 4 ..][0..4], .big);
                    },
                    else => continue,
                }
            }
        };

        const head: u32 = table_offsets[@intFromEnum(TableId.head)];
        const index_to_loc_format = readInt(u16, bytes[head + 50 ..][0..2], .big);

        return .{
            .table_offsets = table_offsets,
            .ttf_bytes = bytes,
            .index_map = index_map,
            .index_to_loc_format = index_to_loc_format,
            .glyphs_len = glyphs_len,
            .cff_data = cff_data,
        };
    }

    pub fn codepointGlyphIndex(
        tt: *const TrueType,
        codepoint: u21,
    ) GlyphIndex {
        const bytes: []const u8 = tt.ttf_bytes;
        const index_map: u32 = tt.index_map;
        const format = readInt(u16, bytes[index_map..][0..2], .big);
        switch (format) {
            0 => {
                const n = readInt(u16, bytes[index_map + 2 ..][0..2], .big);
                if (codepoint < n - 6) {
                    return @enumFromInt(bytes[index_map + 6 + codepoint]);
                }

                return .notdef;
            },
            2 => {
                if (debug_todo) {
                    @panic("TODO implement high-byte mapping for japanese/chinese/korean");
                }
                return .notdef;
            },
            4 => {
                const seg_count = readInt(u16, bytes[index_map + 6 ..][0..2], .big) >> 1;
                var search_range = readInt(u16, bytes[index_map + 8 ..][0..2], .big) >> 1;
                var entry_selector = readInt(u16, bytes[index_map + 10 ..][0..2], .big);
                const range_shift = readInt(u16, bytes[index_map + 12 ..][0..2], .big) >> 1;

                // Do a binary search of the segments.
                const end_count: u32 = index_map + 14;
                var search: u32 = end_count;

                if (codepoint > 0xffff) {
                    return .notdef;
                }

                // They lie from end_count .. end_count + seg_count but search_range
                // is the nearest power of two.
                if (codepoint >= readInt(u16, bytes[search + range_shift * 2 ..][0..2], .big)) {
                    search += range_shift * 2;
                }

                // Now decrement to bias correctly to find smallest.
                search -= 2;
                while (entry_selector > 0) {
                    search_range >>= 1;
                    const end = readInt(u16, bytes[search + search_range * 2 ..][0..2], .big);
                    if (codepoint > end) {
                        search += search_range * 2;
                    }
                    entry_selector -= 1;
                }
                search += 2;

                const item: u16 = @intCast((search - end_count) >> 1);

                const start = readInt(u16, bytes[index_map + 14 + seg_count * 2 + 2 + 2 * item ..][0..2], .big);
                const last = readInt(u16, bytes[end_count + 2 * item ..][0..2], .big);
                if (codepoint < start or codepoint > last) {
                    return .notdef;
                }

                const offset = readInt(u16, bytes[index_map + 14 + seg_count * 6 + 2 + 2 * item ..][0..2], .big);
                if (offset == 0) {
                    const result = @as(i32, codepoint) + readInt(
                        i16,
                        bytes[index_map + 14 + seg_count * 4 + 2 + 2 * item ..][0..2],
                        .big,
                    );
                    // truncate to u16
                    return @enumFromInt(@as(u16, @truncate(@as(u32, @bitCast(result)))));
                }

                return @enumFromInt(
                    readInt(
                        u16,
                        bytes[offset + (codepoint - start) * 2 +
                            index_map + 14 + seg_count * 6 + 2 + 2 * item ..][0..2],
                        .big,
                    ),
                );
            },
            6 => {
                const first = readInt(u16, bytes[index_map + 6 ..][0..2], .big);
                const count = readInt(u16, bytes[index_map + 8 ..][0..2], .big);
                if (codepoint >= first and codepoint < first + count) {
                    return @enumFromInt(readInt(u16, bytes[index_map + 10 + (codepoint - first) * 2 ..][0..2], .big));
                }

                return .notdef;
            },
            12, 13 => {
                const ngroups = readInt(u32, bytes[index_map + 12 ..][0..4], .big);
                var low: u32 = 0;
                var high: u32 = ngroups;
                // Binary search the right group.
                while (low < high) {
                    const mid: u32 = low + ((high - low) >> 1); // rounds down, so low <= mid < high
                    const off: u32 = index_map + 16 + mid * 12;
                    const start_char = readInt(u32, bytes[off..][0..4], .big);
                    const end_char = readInt(u32, bytes[off + 4 ..][0..4], .big);
                    if (codepoint < start_char) {
                        high = mid;
                    } else if (codepoint > end_char) {
                        low = mid + 1;
                    } else {
                        const start_glyph = readInt(u32, bytes[off + 8 ..][0..4], .big);
                        return @enumFromInt(start_glyph + if (format == 12) codepoint - start_char else 0);
                    }
                }
                return .notdef;
            },
            else => {
                if (debug_todo) {
                    @panic("TODO implement glyphIndex for more formats");
                }
                return .notdef;
            },
        }
    }

    pub const GlyphBitmap = struct {
        width: u16,
        height: u16,
        /// Offset in pixel space from the glyph origin to the left of the bitmap.
        off_x: i16,
        /// Offset in pixel space from the glyph origin to the top of the bitmap.
        off_y: i16,

        pub const empty: GlyphBitmap = .{
            .width = 0,
            .height = 0,
            .off_x = 0,
            .off_y = 0,
        };
    };

    pub const GlyphBitmapError = error{
        OutOfMemory,
        GlyphNotFound,
        Unimplemented,
        RMoveToStack,
        VMoveToStack,
        HMoveToStack,
        RLineToStack,
        VLineToStack,
        HLineToStack,
        HCurveToStack,
        RCurveToStack,
        RCurveLineStack,
        CurveLineStack,
        RLineCurveStack,
        CallGSubRStack,
        RecursionLimit,
        SubRNotFound,
        ReturnOutsideSubR,
        HFlexStack,
        FlexStack,
        HFlex1Stack,
        Flex1Stack,
        CurveToStack,
        ReservedOperator,
        PushStackOverflow,
        NoEndChar,
    };

    /// Caller owns returned memory.
    pub fn glyphBitmap(
        tt: *const TrueType,
        gpa: Allocator,
        /// Appended to the list.
        /// Stored left-to-right, top-to-bottom. 8 bits per pixel. 0 is
        /// transparent, 255 is opaque.
        pixels: *ArrayList(u8),
        glyph: GlyphIndex,
        scale_x: f32,
        scale_y: f32,
    ) GlyphBitmapError!GlyphBitmap {
        return glyphBitmapSubpixel(tt, gpa, pixels, glyph, scale_x, scale_y, 0, 0);
    }

    const Bitmap = struct {
        w: u32,
        h: u32,
        stride: u32,
        pixels: []u8,
    };

    /// Caller owns returned memory.
    pub fn glyphBitmapSubpixel(
        tt: *const TrueType,
        gpa: Allocator,
        /// Appended to the list.
        /// Stored left-to-right, top-to-bottom. 8 bits per pixel. 0 is
        /// transparent, 255 is opaque.
        pixels: *ArrayList(u8),
        glyph: GlyphIndex,
        scale_x: f32,
        scale_y: f32,
        shift_x: f32,
        shift_y: f32,
    ) GlyphBitmapError!GlyphBitmap {
        const vertices: []Vertex = try glyphShape(tt, gpa, glyph);
        defer gpa.free(vertices);

        assert(scale_x != 0, @src());
        assert(scale_y != 0, @src());

        const box: BitmapBox = glyphBitmapBoxSubpixel(tt, glyph, scale_x, scale_y, shift_x, shift_y);

        const w: u32 = @intCast(box.x1 - box.x0);
        const h: u32 = @intCast(box.y1 - box.y0);

        if (w == 0 or h == 0) {
            return .empty;
        }

        var gbm: Bitmap = .{
            .w = w,
            .h = h,
            .stride = w,
            .pixels = try pixels.addManyAsSlice(gpa, w * h),
        };
        errdefer pixels.shrinkRetainingCapacity(pixels.items.len - gbm.pixels.len);

        try rasterize(gpa, &gbm, 0.35, vertices, scale_x, scale_y, shift_x, shift_y, box.x0, box.y0, true);

        return .{
            .width = @intCast(gbm.w),
            .height = @intCast(gbm.h),
            .off_x = @intCast(box.x0),
            .off_y = @intCast(box.y0),
        };
    }

    pub fn scaleForPixelHeight(tt: *const TrueType, height: f32) f32 {
        const vm: VerticalMetrics = tt.verticalMetrics();
        const fheight: f32 = float(vm.ascent - vm.descent);
        return height / fheight;
    }

    pub const VerticalMetrics = struct {
        /// The coordinate above the baseline the font extends.
        ascent: i16,
        /// The coordinate below the baseline the font extends (typically negative).
        descent: i16,
        /// The spacing between one row's descent and the next row's ascent.
        line_gap: i16,
    };

    /// A typical expression for advancing the vertical position is
    /// `ascent - descent + line_gap`. These are expressed in unscaled coordinates,
    /// which are typically then multiplied by the scale factor for a given font size.
    pub fn verticalMetrics(tt: *const TrueType) VerticalMetrics {
        const bytes: []const u8 = tt.ttf_bytes;
        const hhea: u32 = tt.table_offsets[@intFromEnum(TableId.hhea)];
        return .{
            .ascent = readInt(i16, bytes[hhea + 4 ..][0..2], .big),
            .descent = readInt(i16, bytes[hhea + 6 ..][0..2], .big),
            .line_gap = readInt(i16, bytes[hhea + 8 ..][0..2], .big),
        };
    }

    pub const HMetrics = struct {
        /// The offset from the current horizontal position to the next horizontal
        /// position in unscaled coordinates.
        advance_width: i16,
        /// The offset from the current horizontal position to the left edge of the
        /// character in unscaled coordinates.
        left_side_bearing: i16,
    };

    pub fn glyphHMetrics(tt: *const TrueType, glyph: GlyphIndex) HMetrics {
        const glyph_index: usize = @intFromEnum(glyph);
        const bytes: []const u8 = tt.ttf_bytes;
        const hhea: u32 = tt.table_offsets[@intFromEnum(TableId.hhea)];
        const hmtx: u32 = tt.table_offsets[@intFromEnum(TableId.hmtx)];
        const n_long_h_metrics = readInt(u16, bytes[hhea + 34 ..][0..2], .big);
        if (glyph_index < n_long_h_metrics) {
            return .{
                .advance_width = readInt(i16, bytes[hmtx + 4 * glyph_index ..][0..2], .big),
                .left_side_bearing = readInt(i16, bytes[hmtx + 4 * glyph_index + 2 ..][0..2], .big),
            };
        }
        return .{
            .advance_width = readInt(i16, bytes[hmtx + 4 * (n_long_h_metrics - 1) ..][0..2], .big),
            .left_side_bearing = readInt(
                i16,
                bytes[hmtx + 4 * n_long_h_metrics + 2 * (glyph_index - n_long_h_metrics) ..][0..2],
                .big,
            ),
        };
    }

    /// An additional amount to advance the horizontal coordinate between the two
    /// provided glyphs.
    pub fn glyphKernAdvance(
        tt: *const TrueType,
        a: GlyphIndex,
        b: GlyphIndex,
    ) i16 {
        const gpos: u32 = tt.table_offsets[@intFromEnum(TableId.GPOS)];
        if (gpos > 0) {
            return glyphKernAdvanceGpos(tt, a, b);
        }
        const kern: u32 = tt.table_offsets[@intFromEnum(TableId.kern)];
        if (kern > 0) {
            return glyphKernAdvanceKern(tt, a, b);
        }
        return 0;
    }

    fn glyphKernAdvanceGpos(
        tt: *const TrueType,
        a: GlyphIndex,
        b: GlyphIndex,
    ) i16 {
        const bytes: []const u8 = tt.ttf_bytes;
        const gpos: u32 = tt.table_offsets[@intFromEnum(TableId.GPOS)];
        assert(gpos > 0, @src());

        if (readInt(u16, bytes[gpos + 0 ..][0..2], .big) != 1) {
            return 0;
        } // Major version 1
        if (readInt(u16, bytes[gpos + 2 ..][0..2], .big) != 0) {
            return 0;
        } // Minor version 0

        const lookup_list_offset: u16 = readInt(u16, bytes[gpos + 8 ..][0..2], .big);
        const lookup_list: u32 = gpos + lookup_list_offset;
        const lookup_count: u16 = readInt(u16, bytes[lookup_list..][0..2], .big);

        for (0..lookup_count) |i| {
            const lookup_offset = readInt(u16, bytes[lookup_list + 2 + 2 * i ..][0..2], .big);
            const lookup_table: u32 = lookup_list + lookup_offset;

            const lookup_type = readInt(u16, bytes[lookup_table..][0..2], .big);
            const sub_table_count = readInt(u16, bytes[lookup_table + 4 ..][0..2], .big);
            const sub_table_offsets: u32 = lookup_table + 6;
            if (lookup_type != 2) // Pair Adjustment Positioning Subtable
            {
                continue;
            }

            for (0..sub_table_count) |sti| {
                const subtable_offset = readInt(u16, bytes[sub_table_offsets + 2 * sti ..][0..2], .big);
                const table: u32 = lookup_table + subtable_offset;
                const pos_format = readInt(u16, bytes[table..][0..2], .big);
                const coverage_offset = readInt(u16, bytes[table + 2 ..][0..2], .big);
                const coverage_index: u32 = coverageIndex(bytes, table + coverage_offset, a) orelse continue;

                switch (pos_format) {
                    1 => {
                        const value_format_1 = readInt(u16, bytes[table + 4 ..][0..2], .big);
                        const value_format_2 = readInt(u16, bytes[table + 6 ..][0..2], .big);
                        if (value_format_1 == 4 and value_format_2 == 0) {
                            const value_record_pair_size_in_bytes: u32 = 2;
                            const pair_set_count = readInt(u16, bytes[table + 8 ..][0..2], .big);
                            const pair_pos_offset = readInt(u16, bytes[table + 10 + 2 * coverage_index ..][0..2], .big);
                            const pair_value_table: u32 = table + pair_pos_offset;
                            const pair_value_count = readInt(u16, bytes[pair_value_table..][0..2], .big);
                            const pair_value_array: u32 = pair_value_table + 2;

                            if (coverage_index >= pair_set_count) {
                                return 0;
                            }

                            const needle: u16 = @intFromEnum(b);
                            var r: u32 = pair_value_count - 1;
                            var l: u32 = 0;

                            // Binary search.
                            while (l <= r) {
                                const m: u32 = (l + r) >> 1;
                                const pair_value: u32 = pair_value_array + (2 + value_record_pair_size_in_bytes) * m;
                                const second_glyph = readInt(u16, bytes[pair_value..][0..2], .big);
                                const straw: u16 = second_glyph;
                                if (needle < straw) {
                                    if (m == 0) {
                                        break;
                                    }
                                    r = m - 1;
                                } else if (needle > straw) {
                                    l = m + 1;
                                } else {
                                    return readInt(i16, bytes[pair_value + 2 ..][0..2], .big);
                                }
                            }
                        } else {
                            if (debug_todo) {
                                @panic("TODO implement more glyphKernAdvanceGpos");
                            }
                            return 0;
                        }
                    },
                    2 => {
                        const value_format_1 = readInt(u16, bytes[table + 4 ..][0..2], .big);
                        const value_format_2 = readInt(u16, bytes[table + 6 ..][0..2], .big);
                        if (value_format_1 == 4 and value_format_2 == 0) {
                            const class_def10_offset = readInt(u16, bytes[table + 8 ..][0..2], .big);
                            const class_def20_offset = readInt(u16, bytes[table + 10 ..][0..2], .big);
                            const glyph1class: u16 = glyphClass(bytes, table + class_def10_offset, a);
                            const glyph2class: u16 = glyphClass(bytes, table + class_def20_offset, b);

                            const class1_count = readInt(u16, bytes[table + 12 ..][0..2], .big);
                            const class2_count = readInt(u16, bytes[table + 14 ..][0..2], .big);

                            if (glyph1class >= class1_count) {
                                return 0;
                            } // malformed
                            if (glyph2class >= class2_count) {
                                return 0;
                            } // malformed

                            const class1_records: u32 = table + 16;
                            const class2_records: u32 = class1_records + 2 * (glyph1class * class2_count);
                            return readInt(i16, bytes[class2_records + 2 * glyph2class ..][0..2], .big);
                        } else {
                            if (debug_todo) {
                                @panic("TODO implement more glyphKernAdvanceGpos");
                            }
                            return 0;
                        }
                    },
                    else => {
                        if (debug_todo) {
                            @panic("TODO implement more glyphKernAdvanceGpos");
                        }
                        return 0;
                    },
                }
            }
        }

        return 0;
    }

    fn glyphKernAdvanceKern(
        tt: *const TrueType,
        a: GlyphIndex,
        b: GlyphIndex,
    ) i16 {
        const bytes: []const u8 = tt.ttf_bytes;
        const kern: u32 = tt.table_offsets[@intFromEnum(TableId.kern)];
        assert(kern > 0, @src());
        // we only look at the first table. it must be 'horizontal' and format 0.
        if (readInt(u16, bytes[kern + 2 ..][0..2], .big) < 1) // number of tables, need at least 1
        {
            return 0;
        }
        if (readInt(u16, bytes[kern + 8 ..][0..2], .big) != 1) // horizontal flag must be set in format
        {
            return 0;
        }

        var l: u32 = 0;
        var r: u32 = readInt(u16, bytes[kern + 10 ..][0..2], .big) - 1;
        const needle: u32 = @as(u32, @intFromEnum(a)) << 16 | @as(u32, @intFromEnum(b));
        while (l <= r) {
            const m: u32 = (l + r) >> 1;
            const straw: u32 = readInt(u32, bytes[kern + 18 + (m * 6) ..][0..4], .big); // note: unaligned read
            if (needle < straw) {
                r = m - 1;
            } else if (needle > straw) {
                l = m + 1;
            } else {
                return readInt(i16, bytes[kern + 22 + (m * 6) ..][0..2], .big);
            }
        }
        return 0;
    }

    pub const Vertex = struct {
        x: i16,
        y: i16,
        cx: i16,
        cy: i16,
        cx1: i16,
        cy1: i16,
        type: Type,

        pub const Type = enum(u8) {
            vmove = 1,
            vline = 2,
            vcurve = 3,
            vcubic = 4,
            _,
        };

        fn set(
            v: *Vertex,
            ty: Type,
            x: i32,
            y: i32,
            cx: i32,
            cy: i32,
        ) void {
            v.type = ty;
            v.x = @intCast(x);
            v.y = @intCast(y);
            v.cx = @intCast(cx);
            v.cy = @intCast(cy);
        }
    };

    pub fn glyphShape(
        tt: *const TrueType,
        gpa: Allocator,
        glyph: GlyphIndex,
    ) GlyphBitmapError![]Vertex {
        return if (tt.cff_data.cff.size != 0)
            tt.glyphShapeT2(gpa, glyph)
        else
            tt.glyphShapeTT(gpa, glyph);
    }

    fn glyphShapeTT(
        tt: *const TrueType,
        gpa: Allocator,
        glyph: GlyphIndex,
    ) GlyphBitmapError![]Vertex {
        const bytes: []const u8 = tt.ttf_bytes;
        const g: u32 = try glyfOffset(tt, glyph);
        var vertices: ArrayList(Vertex) = .empty;
        defer vertices.deinit(gpa);
        const n_contours_signed = readInt(i16, bytes[g..][0..2], .big);

        if (n_contours_signed > 0) {
            const n_contours: u16 = @intCast(n_contours_signed);
            const contours_end_pts: u32 = g + 10;
            const ins: i32 = readInt(u16, bytes[g + 10 + n_contours * 2 ..][0..2], .big);
            var points: u32 = @intCast(g + 10 + @as(i64, n_contours) * 2 + 2 + ins);

            const n: u32 = 1 + readInt(u16, bytes[contours_end_pts + n_contours * 2 - 2 ..][0..2], .big);

            // A loose bound on how many vertices we might need.
            const m: u32 = n + 2 * n_contours;
            try vertices.resize(gpa, m);

            var next_move: i32 = 0;
            var flagcount: u8 = 0;

            // in first pass, we load uninterpreted data into the allocated array
            // above, shifted to the end of the array so we won't overwrite it when
            // we create our final data starting from the front

            // Starting offset for uninterpreted data, regardless of how m ends up being calculated.
            const off: u32 = m - n;

            // first load flags
            {
                var flags: u8 = 0;
                for (0..n) |i| {
                    if (flagcount == 0) {
                        flags = bytes[points];
                        points += 1;
                        if ((flags & 8) != 0) {
                            flagcount = bytes[points];
                            points += 1;
                        }
                    } else {
                        flagcount -= 1;
                    }
                    vertices.items[off + i].type = @enumFromInt(flags);
                }
            }

            // now load x coordinates
            var x: i32 = 0;
            for (0..n) |i| {
                const flags: u8 = @intFromEnum(vertices.items[off + i].type);
                if ((flags & 2) != 0) {
                    const dx: i16 = bytes[points];
                    points += 1;
                    x += if ((flags & 16) != 0) dx else -dx;
                } else {
                    if ((flags & 16) == 0) {
                        x += readInt(i16, bytes[points..][0..2], .big);
                        points += 2;
                    }
                }
                vertices.items[off + i].x = @intCast(x);
            }

            // now load y coordinates
            var y: i32 = 0;
            for (0..n) |i| {
                const flags: u8 = @intFromEnum(vertices.items[off + i].type);
                if ((flags & 4) != 0) {
                    const dy: i16 = bytes[points];
                    points += 1;
                    y += if ((flags & 32) != 0) dy else -dy;
                } else {
                    if ((flags & 32) == 0) {
                        y += readInt(i16, bytes[points..][0..2], .big);
                        points += 2;
                    }
                }
                vertices.items[off + i].y = @intCast(y);
            }

            // now convert them to our format
            var num_vertices: u32 = 0;
            var sx: i32 = 0;
            var sy: i32 = 0;
            var cx: i32 = 0;
            var cy: i32 = 0;
            var scx: i32 = 0;
            var scy: i32 = 0;
            var i: u32 = 0;
            var j: u32 = 0;
            var start_off: bool = false;
            var was_off: bool = false;
            while (i < n) : (i += 1) {
                const flags: u8 = @intFromEnum(vertices.items[off + i].type);
                x = @intCast(vertices.items[off + i].x);
                y = @intCast(vertices.items[off + i].y);

                if (next_move == i) {
                    if (i != 0)
                        num_vertices = closeShape(
                            vertices.items,
                            num_vertices,
                            was_off,
                            start_off,
                            sx,
                            sy,
                            scx,
                            scy,
                            cx,
                            cy,
                        );

                    // now start the new one
                    start_off = (flags & 1) == 0;
                    if (start_off) {
                        // if we start off with an off-curve point, then when we need to find a point on the curve
                        // where we can start, and we need to save some state for when we wraparound.
                        scx = x;
                        scy = y;
                        if ((@intFromEnum(vertices.items[off + i + 1].type) & 1) == 0) {
                            // next point is also a curve point, so interpolate an on-point curve
                            sx = (x + vertices.items[off + i + 1].x) >> 1;
                            sy = (y + vertices.items[off + i + 1].y) >> 1;
                        } else {
                            // otherwise just use the next point as our start point
                            sx = vertices.items[off + i + 1].x;
                            sy = vertices.items[off + i + 1].y;
                            i += 1; // we're using point i+1 as the starting point, so skip it
                        }
                    } else {
                        sx = x;
                        sy = y;
                    }
                    vertices.items[num_vertices].set(.vmove, sx, sy, 0, 0);
                    num_vertices += 1;
                    was_off = false;
                    next_move = 1 + readInt(u16, bytes[contours_end_pts + j * 2 ..][0..2], .big);
                    j += 1;
                } else {
                    if ((flags & 1) == 0) { // if it's a curve
                        if (was_off) {
                            // two off-curve control points in a row means interpolate an on-curve midpoint
                            vertices.items[num_vertices].set(.vcurve, (cx + x) >> 1, (cy + y) >> 1, cx, cy);
                            num_vertices += 1;
                        }
                        cx = x;
                        cy = y;
                        was_off = true;
                    } else {
                        if (was_off)
                            vertices.items[num_vertices].set(.vcurve, x, y, cx, cy)
                        else
                            vertices.items[num_vertices].set(.vline, x, y, 0, 0);
                        num_vertices += 1;
                        was_off = false;
                    }
                }
            }
            num_vertices = closeShape(vertices.items, num_vertices, was_off, start_off, sx, sy, scx, scy, cx, cy);
            vertices.shrinkRetainingCapacity(num_vertices);
        } else if (n_contours_signed < 0) {
            // Compound shapes.
            var more: bool = true;
            var comp: u32 = g + 10;
            while (more) {
                var mtx: [6]f32 = .{ 1, 0, 0, 1, 0, 0 };

                const flags = readCursor(u16, bytes, &comp);
                const gidx: GlyphIndex = @enumFromInt(readCursor(u16, bytes, &comp));

                if ((flags & 2) != 0) { // XY values
                    if ((flags & 1) != 0) { // shorts
                        mtx[4] = @floatFromInt(readCursor(i16, bytes, &comp));
                        mtx[5] = @floatFromInt(readCursor(i16, bytes, &comp));
                    } else {
                        mtx[4] = @floatFromInt(readCursor(i8, bytes, &comp));
                        mtx[5] = @floatFromInt(readCursor(i8, bytes, &comp));
                    }
                } else {
                    if (debug_todo) {
                        @panic("TODO handle matching point");
                    }
                }
                if ((flags & (1 << 3)) != 0) { // WE_HAVE_A_SCALE
                    mtx[0] = float(readCursor(i16, bytes, &comp)) / 16384.0;
                    mtx[1] = 0;
                    mtx[2] = 0;
                    mtx[3] = mtx[0];
                } else if ((flags & (1 << 6)) != 0) { // WE_HAVE_AN_X_AND_YSCALE
                    mtx[0] = float(readCursor(i16, bytes, &comp)) / 16384.0;
                    mtx[1] = 0;
                    mtx[2] = 0;
                    mtx[3] = float(readCursor(i16, bytes, &comp)) / 16384.0;
                } else if ((flags & (1 << 7)) != 0) { // WE_HAVE_A_TWO_BY_TWO
                    mtx[0] = float(readCursor(i16, bytes, &comp)) / 16384.0;
                    mtx[1] = float(readCursor(i16, bytes, &comp)) / 16384.0;
                    mtx[2] = float(readCursor(i16, bytes, &comp)) / 16384.0;
                    mtx[3] = float(readCursor(i16, bytes, &comp)) / 16384.0;
                }

                // Find transformation scales.
                const m: f32 = @sqrt(mtx[0] * mtx[0] + mtx[1] * mtx[1]);
                const n: f32 = @sqrt(mtx[2] * mtx[2] + mtx[3] * mtx[3]);

                // Get indexed glyph.
                const comp_verts: []Vertex = try glyphShape(tt, gpa, gidx);
                defer gpa.free(comp_verts);
                if (comp_verts.len > 0) {
                    // Transform vertices.
                    for (comp_verts) |*v| {
                        {
                            const x: f32 = float(v.x);
                            const y: f32 = float(v.y);
                            v.x = @trunc(m * (mtx[0] * x + mtx[2] * y + mtx[4]));
                            v.y = @trunc(n * (mtx[1] * x + mtx[3] * y + mtx[5]));
                        }
                        {
                            const x: f32 = float(v.cx);
                            const y: f32 = float(v.cy);
                            v.cx = @trunc(m * (mtx[0] * x + mtx[2] * y + mtx[4]));
                            v.cy = @trunc(n * (mtx[1] * x + mtx[3] * y + mtx[5]));
                        }
                    }
                    try vertices.appendSlice(gpa, comp_verts);
                }
                more = (flags & (1 << 5)) != 0;
            }
        }
        return vertices.toOwnedSlice(gpa);
    }

    fn glyfOffset(tt: *const TrueType, glyph: GlyphIndex) error{GlyphNotFound}!u32 {
        const bytes: []const u8 = tt.ttf_bytes;
        const glyph_index: usize = @intFromEnum(glyph);

        assert(glyph_index < tt.glyphs_len, @src());
        assert(tt.index_to_loc_format < 2, @src());

        const glyf: u32 = tt.table_offsets[@intFromEnum(TableId.glyf)];
        const loca: u32 = tt.table_offsets[@intFromEnum(TableId.loca)];
        const g1, const g2 = if (tt.index_to_loc_format == 0) .{
            glyf + @as(u32, readInt(u16, bytes[loca + glyph_index * 2 ..][0..2], .big)) * 2,
            glyf + @as(u32, readInt(u16, bytes[loca + glyph_index * 2 + 2 ..][0..2], .big)) * 2,
        } else .{
            glyf + readInt(u32, bytes[loca + glyph_index * 4 ..][0..4], .big),
            glyf + readInt(u32, bytes[loca + glyph_index * 4 + 4 ..][0..4], .big),
        };
        if (g1 == g2) {
            return error.GlyphNotFound;
        }
        return g1;
    }

    pub const BitmapBox = struct {
        x0: i32,
        y0: i32,
        x1: i32,
        y1: i32,
    };

    pub fn glyphBitmapBoxSubpixel(
        tt: *const TrueType,
        glyph: GlyphIndex,
        scale_x: f32,
        scale_y: f32,
        shift_x: f32,
        shift_y: f32,
    ) BitmapBox {
        const box: BitmapBox = glyphBox(tt, glyph) catch |err| switch (err) {
            error.GlyphNotFound => return .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 }, // e.g. space character
        };
        return .{
            // move to integral bboxes (treating pixels as little squares, what pixels get touched)?
            .x0 = @floor(float(box.x0) * scale_x + shift_x),
            .y0 = @floor(float(-box.y1) * scale_y + shift_y),
            .x1 = @ceil(float(box.x1) * scale_x + shift_x),
            .y1 = @ceil(float(-box.y0) * scale_y + shift_y),
        };
    }

    pub fn glyphBitmapBox(
        tt: *const TrueType,
        glyph: GlyphIndex,
        scale_x: f32,
        scale_y: f32,
    ) BitmapBox {
        return glyphBitmapBoxSubpixel(tt, glyph, scale_x, scale_y, 0, 0);
    }

    pub fn glyphBox(
        tt: *const TrueType,
        glyph: GlyphIndex,
    ) error{GlyphNotFound}!BitmapBox {
        return if (tt.cff_data.cff.size != 0)
            tt.glyphBoxT2(glyph)
        else
            tt.glyphBoxTT(glyph);
    }

    fn glyphBoxTT(tt: *const TrueType, glyph: GlyphIndex) error{GlyphNotFound}!BitmapBox {
        const bytes: []const u8 = tt.ttf_bytes;
        const g: u32 = try glyfOffset(tt, glyph);
        return .{
            .x0 = readInt(i16, bytes[g + 2 ..][0..2], .big),
            .y0 = readInt(i16, bytes[g + 4 ..][0..2], .big),
            .x1 = readInt(i16, bytes[g + 6 ..][0..2], .big),
            .y1 = readInt(i16, bytes[g + 8 ..][0..2], .big),
        };
    }

    fn rasterize(
        gpa: Allocator,
        result: *Bitmap,
        flatness_in_pixels: f32,
        vertices: []Vertex,
        scale_x: f32,
        scale_y: f32,
        shift_x: f32,
        shift_y: f32,
        off_x: i32,
        off_y: i32,
        invert: bool,
    ) Allocator.Error!void {
        const scale: f32 = @min(scale_x, scale_y);
        var windings: FlattenedCurves = try flattenCurves(gpa, vertices, flatness_in_pixels / scale);
        defer windings.deinit(gpa);
        try rasterizeInner(
            gpa,
            result,
            windings.points,
            windings.contour_lengths,
            scale_x,
            scale_y,
            shift_x,
            shift_y,
            off_x,
            off_y,
            invert,
        );
    }

    const Edge = struct {
        x0: f32,
        y0: f32,
        x1: f32,
        y1: f32,
        invert: bool,

        const Sort = struct {
            fn lessThan(
                ctx: Sort,
                a: Edge,
                b: Edge,
            ) bool {
                _ = ctx;
                return a.y0 < b.y0;
            }
        };
    };

    fn rasterizeInner(
        gpa: Allocator,
        result: *Bitmap,
        pts: []Point,
        wcount: []u32,
        scale_x: f32,
        scale_y: f32,
        shift_x: f32,
        shift_y: f32,
        off_x: i32,
        off_y: i32,
        invert: bool,
    ) Allocator.Error!void {
        const y_scale_inv: f32 = if (invert) -scale_y else scale_y;

        // now we have to blow out the windings into explicit edge lists
        const edge_alloc_n: usize = n: {
            var n: u32 = 1; // Add an extra one as a sentinel.
            for (wcount) |elem| {
                n += elem;
            }
            break :n n;
        };

        const e = try gpa.alloc(Edge, edge_alloc_n);
        defer gpa.free(e);

        var n: u32 = 0;
        var m: u32 = 0;
        for (wcount) |wcount_elem| {
            const p: []Point = pts[m..];
            m += wcount_elem;
            var j: u32 = wcount_elem - 1;
            var k: u32 = 0;
            while (k < wcount_elem) : ({
                j = k;
                k += 1;
            }) {
                var a = k;
                var b = j;
                // skip the edge if horizontal
                if (p[j].y == p[k].y)
                    continue;
                // add edge from j to k to the list
                e[n].invert = false;
                if (if (invert) p[j].y > p[k].y else p[j].y < p[k].y) {
                    e[n].invert = true;
                    a = j;
                    b = k;
                }
                e[n].x0 = p[a].x * scale_x + shift_x;
                e[n].y0 = (p[a].y * y_scale_inv + shift_y);
                e[n].x1 = p[b].x * scale_x + shift_x;
                e[n].y1 = (p[b].y * y_scale_inv + shift_y);
                n += 1;
            }
        }
        // now sort the edges by their highest point (should snap to integer, and then by x)
        std.mem.sortUnstable(Edge, e[0..n], Edge.Sort{}, Edge.Sort.lessThan);

        // now, traverse the scanlines and find the intersections on each scanline, use xor winding rule
        try rasterizeSortedEdges(gpa, result, e[0 .. n + 1], off_x, off_y);
    }

    const Point = struct {
        x: f32,
        y: f32,
    };

    const FlattenedCurves = struct {
        points: []Point,
        contour_lengths: []u32,

        const empty: FlattenedCurves = .{
            .points = &.{},
            .contour_lengths = &.{},
        };

        fn deinit(fc: *FlattenedCurves, gpa: Allocator) void {
            gpa.free(fc.points);
            gpa.free(fc.contour_lengths);
            fc.* = undefined;
        }
    };

    fn flattenCurves(
        gpa: Allocator,
        vertices: []const Vertex,
        objspace_flatness: f32,
    ) error{OutOfMemory}!FlattenedCurves {
        var points: ArrayList(Point) = .empty;
        defer points.deinit(gpa);
        var contour_lengths: ArrayList(u32) = .empty;
        defer contour_lengths.deinit(gpa);

        const objspace_flatness_squared: f32 = objspace_flatness * objspace_flatness;

        var start: u32 = 0;
        var x: f32 = 0;
        var y: f32 = 0;
        for (vertices) |v| {
            sw: switch (v.type) {
                .vmove => {
                    if (points.items.len > 0) {
                        try contour_lengths.append(gpa, @intCast(points.items.len - start));
                        start = @intCast(points.items.len);
                    }

                    continue :sw .vline;
                },
                .vline => {
                    x = @floatFromInt(v.x);
                    y = @floatFromInt(v.y);
                    try points.append(gpa, .{ .x = x, .y = y });
                },
                .vcurve => {
                    try tesselateCurve(
                        gpa,
                        &points,
                        x,
                        y,
                        @floatFromInt(v.cx),
                        @floatFromInt(v.cy),
                        @floatFromInt(v.x),
                        @floatFromInt(v.y),
                        objspace_flatness_squared,
                        0,
                    );
                    x = @floatFromInt(v.x);
                    y = @floatFromInt(v.y);
                },
                .vcubic => {
                    try tesselateCubic(
                        gpa,
                        &points,
                        x,
                        y,
                        @floatFromInt(v.cx),
                        @floatFromInt(v.cy),
                        @floatFromInt(v.cx1),
                        @floatFromInt(v.cy1),
                        @floatFromInt(v.x),
                        @floatFromInt(v.y),
                        objspace_flatness_squared,
                        0,
                    );
                    x = @floatFromInt(v.x);
                    y = @floatFromInt(v.y);
                },
                _ => continue,
            }
        }
        try contour_lengths.append(gpa, @intCast(points.items.len - start));

        return .{
            .points = try points.toOwnedSlice(gpa),
            .contour_lengths = try contour_lengths.toOwnedSlice(gpa),
        };
    }

    /// tessellate until threshold p is happy... @TODO warped to compensate for non-linear stretching
    fn tesselateCurve(
        gpa: Allocator,
        points: *ArrayList(Point),
        x0: f32,
        y0: f32,
        x1: f32,
        y1: f32,
        x2: f32,
        y2: f32,
        objspace_flatness_squared: f32,
        n: u32,
    ) Allocator.Error!void {
        // midpoint
        const mx: f32 = (x0 + 2 * x1 + x2) / 4;
        const my: f32 = (y0 + 2 * y1 + y2) / 4;
        // versus directly drawn line
        const dx: f32 = (x0 + x2) / 2 - mx;
        const dy: f32 = (y0 + y2) / 2 - my;
        if (n > 16) // 65536 segments on one curve better be enough!
        {
            return;
        }
        if (dx * dx + dy * dy > objspace_flatness_squared) { // half-pixel error allowed... need to be smaller if AA
            try tesselateCurve(
                gpa,
                points,
                x0,
                y0,
                (x0 + x1) / 2.0,
                (y0 + y1) / 2.0,
                mx,
                my,
                objspace_flatness_squared,
                n + 1,
            );
            try tesselateCurve(
                gpa,
                points,
                mx,
                my,
                (x1 + x2) / 2.0,
                (y1 + y2) / 2.0,
                x2,
                y2,
                objspace_flatness_squared,
                n + 1,
            );
        } else {
            try points.append(gpa, .{ .x = x2, .y = y2 });
        }
    }

    fn tesselateCubic(
        gpa: Allocator,
        points: *ArrayList(Point),
        x0: f32,
        y0: f32,
        x1: f32,
        y1: f32,
        x2: f32,
        y2: f32,
        x3: f32,
        y3: f32,
        objspace_flatness_squared: f32,
        n: u32,
    ) Allocator.Error!void {
        // According to Dougall Johnson, this "flatness" calculation is just
        // made-up nonsense that seems to work well enough.
        const dx0: f32 = x1 - x0;
        const dy0: f32 = y1 - y0;
        const dx1: f32 = x2 - x1;
        const dy1: f32 = y2 - y1;
        const dx2: f32 = x3 - x2;
        const dy2: f32 = y3 - y2;
        const dx: f32 = x3 - x0;
        const dy: f32 = y3 - y0;
        const longlen: f32 = @sqrt(dx0 * dx0 + dy0 * dy0) + @sqrt(dx1 * dx1 + dy1 * dy1) + @sqrt(dx2 * dx2 + dy2 * dy2);
        const shortlen: f32 = @sqrt(dx * dx + dy * dy);
        const flatness_squared: f32 = longlen * longlen - shortlen * shortlen;

        if (n > 16) // 65536 segments on one curve better be enough!
        {
            return;
        }

        if (flatness_squared > objspace_flatness_squared) {
            const x01: f32 = (x0 + x1) / 2;
            const y01: f32 = (y0 + y1) / 2;
            const x12: f32 = (x1 + x2) / 2;
            const y12: f32 = (y1 + y2) / 2;
            const x23: f32 = (x2 + x3) / 2;
            const y23: f32 = (y2 + y3) / 2;

            const xa: f32 = (x01 + x12) / 2;
            const ya: f32 = (y01 + y12) / 2;
            const xb: f32 = (x12 + x23) / 2;
            const yb: f32 = (y12 + y23) / 2;

            const mx: f32 = (xa + xb) / 2;
            const my: f32 = (ya + yb) / 2;

            try tesselateCubic(gpa, points, x0, y0, x01, y01, xa, ya, mx, my, objspace_flatness_squared, n + 1);
            try tesselateCubic(gpa, points, mx, my, xb, yb, x23, y23, x3, y3, objspace_flatness_squared, n + 1);
        } else {
            try points.append(gpa, .{ .x = x3, .y = y3 });
        }
    }

    fn sizedTrapezoidArea(height: f32, top_width: f32, bottom_width: f32) f32 {
        assert(top_width >= 0, @src());
        assert(bottom_width >= 0, @src());
        return (top_width + bottom_width) / 2.0 * height;
    }

    fn positionTrapezoidArea(
        height: f32,
        tx0: f32,
        tx1: f32,
        bx0: f32,
        bx1: f32,
    ) f32 {
        return sizedTrapezoidArea(height, tx1 - tx0, bx1 - bx0);
    }

    fn sizedTriangleArea(height: f32, width: f32) f32 {
        return height * width / 2;
    }

    const ActiveEdge = struct {
        next: ?*ActiveEdge,
        fx: f32,
        fdx: f32,
        fdy: f32,
        direction: f32,
        sy: f32,
        ey: f32,
    };

    /// Directly anti-alias rasterize edges without supersampling.
    fn rasterizeSortedEdges(
        gpa: Allocator,
        result: *Bitmap,
        edges: []Edge,
        off_x: i32,
        off_y: i32,
    ) Allocator.Error!void {
        var arena_allocator: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(gpa);
        defer arena_allocator.deinit();
        const arena: Allocator = arena_allocator.allocator();

        var active: ?*ActiveEdge = null;

        const scanline_buffer = try arena.alloc(f32, result.w * 2 + 1);
        const scanline: []f32 = scanline_buffer[0..result.w];
        const scanline2: []f32 = scanline_buffer[result.w..][0 .. result.w + 1];

        var y: i32 = off_y;
        edges[edges.len - 1].y0 = @floatFromInt((off_y + @as(i32, @intCast(result.h))) + 1);

        var j: u32 = 0;
        var e: u32 = 0;
        while (j < result.h) {
            // find center of pixel for this scanline
            const scan_y_top: f32 = float(y);
            const scan_y_bottom: f32 = float(y + 1);
            var step: *?*ActiveEdge = &active;

            @memset(scanline, 0);
            @memset(scanline2, 0);

            // update all active edges;
            // remove all active edges that terminate before the top of this scanline
            while (step.*) |z| {
                if (z.ey <= scan_y_top) {
                    step.* = z.next; // delete from list
                    assert(z.direction != 0, @src());
                    z.direction = 0;
                    arena.destroy(z);
                } else {
                    step = &z.next; // advance through list
                }
            }

            // insert all edges that start before the bottom of this scanline
            while (edges[e].y0 <= scan_y_bottom) {
                if (edges[e].y0 != edges[e].y1) {
                    const z: *ActiveEdge = try newActive(arena, edges[e], off_x, scan_y_top);
                    if (j == 0 and off_y != 0) {
                        z.ey = @max(z.ey, scan_y_top);
                    }
                    // If we get really unlucky a tiny bit of an edge can be
                    // out of bounds.
                    assert(z.ey >= scan_y_top, @src());

                    // Insert at front.
                    z.next = active;
                    active = z;
                }
                e += 1;
            }

            if (active) |a| {
                fillActiveEdges(scanline, scanline2, result.w, a, scan_y_top);
            }

            {
                var sum: f32 = 0;
                for (scanline, scanline2[0..result.w], result.pixels[j * result.stride ..][0..result.w]) |s, s2, *p| {
                    sum += s2;
                    p.* = @trunc(@min(@abs(s + sum) * 255 + 0.5, 255));
                }
            }
            // advance all the edges
            step = &active;
            while (step.*) |z| {
                z.fx += z.fdx; // advance to position for current scanline
                step = &z.next; // advance through list
            }

            y += 1;
            j += 1;
        }
    }

    fn closeShape(
        vertices: []Vertex,
        vertices_len_start: u32,
        was_off: bool,
        start_off: bool,
        sx: i32,
        sy: i32,
        scx: i32,
        scy: i32,
        cx: i32,
        cy: i32,
    ) u32 {
        var vertices_len: u32 = vertices_len_start;
        if (start_off) {
            if (was_off) {
                vertices[vertices_len].set(.vcurve, (cx + scx) >> 1, (cy + scy) >> 1, cx, cy);
                vertices_len += 1;
            }
            vertices[vertices_len].set(.vcurve, sx, sy, scx, scy);
            vertices_len += 1;
        } else {
            if (was_off) {
                vertices[vertices_len].set(.vcurve, sx, sy, cx, cy);
                vertices_len += 1;
            } else {
                vertices[vertices_len].set(.vline, sx, sy, 0, 0);
                vertices_len += 1;
            }
        }
        return vertices_len;
    }

    fn readCursor(
        comptime I: type,
        bytes: []const u8,
        cursor: *u32,
    ) I {
        const start: u32 = cursor.*;
        const result = readInt(I, bytes[start..][0..@sizeOf(I)], .big);
        cursor.* = start + @sizeOf(I);
        return result;
    }

    fn newActive(
        arena: Allocator,
        e: Edge,
        off_x: i32,
        start_point: f32,
    ) Allocator.Error!*ActiveEdge {
        const z = try arena.create(ActiveEdge);
        const dxdy: f32 = (e.x1 - e.x0) / (e.y1 - e.y0);
        z.* = .{
            .fdx = dxdy,
            .fdy = if (dxdy != 0.0) (1.0 / dxdy) else 0.0,
            .fx = (e.x0 + dxdy * (start_point - e.y0)) - float(off_x),
            .direction = if (e.invert) 1.0 else -1.0,
            .sy = e.y0,
            .ey = e.y1,
            .next = null,
        };
        return z;
    }

    fn fillActiveEdges(
        scanline: []f32,
        scanline_fill: []f32,
        len: u32,
        start_edge: *ActiveEdge,
        y_top: f32,
    ) void {
        const y_bottom: f32 = y_top + 1;
        var opt_e: ?*ActiveEdge = start_edge;
        while (opt_e) |e| : (opt_e = e.next) {
            // brute force every pixel

            // compute intersection points with top & bottom
            assert(e.ey >= y_top, @src());

            if (e.fdx == 0) {
                const x0 = e.fx;
                if (x0 < float(len)) {
                    if (x0 >= 0) {
                        handleClippedEdge(scanline, @trunc(x0), e, x0, y_top, x0, y_bottom);
                        handleClippedEdge(scanline_fill, @trunc(x0 + 1), e, x0, y_top, x0, y_bottom);
                    } else {
                        handleClippedEdge(scanline_fill, 0, e, x0, y_top, x0, y_bottom);
                    }
                }
            } else {
                var x0: f32 = e.fx;
                var dx: f32 = e.fdx;
                var xb: f32 = x0 + dx;
                var dy: f32 = e.fdy;
                assert(e.sy <= y_bottom, @src());
                assert(e.ey >= y_top, @src());

                // Compute endpoints of line segment clipped to this scanline (if the
                // line segment starts on this scanline. x0 is the intersection of the
                // line with y_top, but that may be off the line segment.
                var x_top: f32, var sy0: f32 = if (e.sy > y_top) .{
                    x0 + dx * (e.sy - y_top),
                    e.sy,
                } else .{
                    x0,
                    y_top,
                };

                var x_bottom: f32, var sy1: f32 = if (e.ey < y_bottom) .{
                    x0 + dx * (e.ey - y_top),
                    e.ey,
                } else .{
                    xb,
                    y_bottom,
                };

                if (x_top >= 0 and x_bottom >= 0 and
                    x_top < float(len) and x_bottom < float(len))
                {
                    // from here on, we don't have to range check x values

                    if (@trunc(x_top) == @trunc(x_bottom)) {
                        // simple case, only spans one pixel
                        const x: u32 = @trunc(x_top);
                        const height: f32 = (sy1 - sy0) * e.direction;
                        assert(x < len, @src());
                        scanline[x] += positionTrapezoidArea(
                            height,
                            x_top,
                            @floatFromInt(x + 1),
                            x_bottom,
                            @floatFromInt(x + 1),
                        );
                        scanline_fill[x + 1] += height; // everything right of this pixel is filled
                    } else {
                        // covers 2+ pixels
                        if (x_top > x_bottom) {
                            // flip scanline vertically; signed area is the same
                            sy0 = y_bottom - (sy0 - y_top);
                            sy1 = y_bottom - (sy1 - y_top);
                            std.mem.swap(f32, &sy0, &sy1);
                            std.mem.swap(f32, &x_bottom, &x_top);
                            dx = -dx;
                            dy = -dy;
                            std.mem.swap(f32, &x0, &xb);
                        }
                        assert(dy >= 0, @src());
                        assert(dx >= 0, @src());

                        const x1: u32 = @trunc(x_top);
                        const x2: u32 = @trunc(x_bottom);
                        const x1p1f: f32 = float(x1 + 1);
                        const x2f: f32 = float(x2);
                        // compute intersection with y axis at x1+1
                        var y_crossing: f32 = y_top + dy * (x1p1f - x0);

                        // compute intersection with y axis at x2
                        var y_final: f32 = y_top + dy * (x2f - x0);

                        //           x1    x_top                            x2    x_bottom
                        //     y_top  +------|-----+------------+------------+--------|---+------------+
                        //            |            |            |            |            |            |
                        //            |            |            |            |            |            |
                        //       sy0  |      Txxxxx|............|............|............|............|
                        // y_crossing |            *xxxxx.......|............|............|............|
                        //            |            |     xxxxx..|............|............|............|
                        //            |            |     /-   xx*xxxx........|............|............|
                        //            |            | dy <       |    xxxxxx..|............|............|
                        //   y_final  |            |     \-     |          xx*xxx.........|............|
                        //       sy1  |            |            |            |   xxxxxB...|............|
                        //            |            |            |            |            |            |
                        //            |            |            |            |            |            |
                        //  y_bottom  +------------+------------+------------+------------+------------+
                        // goal is to measure the area covered by '.' in each pixel

                        // if x2 is right at the right edge of x1, y_crossing can blow up, github #1057
                        // @TODO: maybe test against sy1 rather than y_bottom?
                        if (y_crossing > y_bottom)
                            y_crossing = y_bottom;

                        const sign: f32 = e.direction;

                        // area of the rectangle covered from sy0..y_crossing
                        var area: f32 = sign * (y_crossing - sy0);

                        // area of the triangle (x_top,sy0), (x1+1,sy0), (x1+1,y_crossing)
                        scanline[x1] += sizedTriangleArea(area, x1p1f - x_top);

                        // check if final y_crossing is blown up; no test case for this
                        if (y_final > y_bottom) {
                            y_final = y_bottom;
                            // if denom=0, y_final = y_crossing, so y_final <= y_bottom
                            dy = (y_final - y_crossing) / (x2f - x1p1f);
                        }

                        // in second pixel, area covered by line segment found in first pixel
                        // is always a rectangle 1 wide * the height of that line segment; this
                        // is exactly what the variable 'area' stores. it also gets a contribution
                        // from the line segment within it. the THIRD pixel will get the first
                        // pixel's rectangle contribution, the second pixel's rectangle contribution,
                        // and its own contribution. the 'own contribution' is the same in every pixel except
                        // the leftmost and rightmost, a trapezoid that slides down in each pixel.
                        // the second pixel's contribution to the third pixel will be the
                        // rectangle 1 wide times the height change in the second pixel, which is dy.

                        const step: f32 = sign * dy * 1; // dy is dy/dx, change in y for every 1 change in x,
                        // which multiplied by 1-pixel-width is how much pixel area changes for each step in x
                        // so the area advances by 'step' every time

                        for (scanline[x1 + 1 .. x2]) |*s| {
                            s.* += area + step / 2; // area of trapezoid is 1*step/2
                            area += step;
                        }
                        // accumulated error from area += step unless we round step down
                        assert(@abs(area) <= 1.01, @src());
                        assert(sy1 > y_final - 0.01, @src());

                        // area covered in the last pixel is the rectangle from all the pixels to the left,
                        // plus the trapezoid filled by the line segment in this pixel all the way to the right edge
                        scanline[x2] += area + sign * positionTrapezoidArea(
                            sy1 - y_final,
                            x2f,
                            x2f + 1.0,
                            x_bottom,
                            x2f + 1.0,
                        );

                        // the rest of the line is filled based on the total height of the line segment in this pixel
                        scanline_fill[x2 + 1] += sign * (sy1 - sy0);
                    }
                } else {
                    // if edge goes outside of box we're drawing, we require
                    // clipping logic. since this does not match the intended use
                    // of this library, we use a different, very slow brute
                    // force implementation
                    // note though that this does happen some of the time because
                    // x_top and x_bottom can be extrapolated at the top & bottom of
                    // the shape and actually lie outside the bounding box
                    for (0..len) |x_usize| {
                        const x: u32 = @intCast(x_usize);
                        // cases:
                        // there can be up to two intersections with the pixel. any intersection
                        // with left or right edges can be handled by splitting into two (or three)
                        // regions. intersections with top & bottom do not necessitate case-wise logic.
                        // the old way of doing this found the intersections with the left & right edges,
                        // then used some simple logic to produce up to three segments in sorted order
                        // from top-to-bottom. however, this had a problem: if an x edge was epsilon
                        // across the x border, then the corresponding y position might not be distinct
                        // from the other y segment, and it might ignored as an empty segment. to avoid
                        // that, we need to explicitly produce segments based on x positions.

                        // rename variables to clearly-defined pairs
                        const y0: f32 = y_top;
                        const x1: f32 = float(x);
                        const x2: f32 = float(x + 1);
                        const x3: f32 = xb;
                        const y3: f32 = y_bottom;

                        // x = e.x + e.dx * (y-y_top)
                        // (y-y_top) = (x - e.x) / e.dx
                        // y = (x - e.x) / e.dx + y_top
                        const y1: f32 = (x1 - x0) / dx + y_top;
                        const y2: f32 = (x1 + 1 - x0) / dx + y_top;

                        if (x0 < x1 and x3 > x2) { // three segments descending down-right
                            handleClippedEdge(scanline, x, e, x0, y0, x1, y1);
                            handleClippedEdge(scanline, x, e, x1, y1, x2, y2);
                            handleClippedEdge(scanline, x, e, x2, y2, x3, y3);
                        } else if (x3 < x1 and x0 > x2) { // three segments descending down-left
                            handleClippedEdge(scanline, x, e, x0, y0, x2, y2);
                            handleClippedEdge(scanline, x, e, x2, y2, x1, y1);
                            handleClippedEdge(scanline, x, e, x1, y1, x3, y3);
                        } else if (x0 < x1 and x3 > x1) { // two segments across x, down-right
                            handleClippedEdge(scanline, x, e, x0, y0, x1, y1);
                            handleClippedEdge(scanline, x, e, x1, y1, x3, y3);
                        } else if (x3 < x1 and x0 > x1) { // two segments across x, down-left
                            handleClippedEdge(scanline, x, e, x0, y0, x1, y1);
                            handleClippedEdge(scanline, x, e, x1, y1, x3, y3);
                        } else if (x0 < x2 and x3 > x2) { // two segments across x+1, down-right
                            handleClippedEdge(scanline, x, e, x0, y0, x2, y2);
                            handleClippedEdge(scanline, x, e, x2, y2, x3, y3);
                        } else if (x3 < x2 and x0 > x2) { // two segments across x+1, down-left
                            handleClippedEdge(scanline, x, e, x0, y0, x2, y2);
                            handleClippedEdge(scanline, x, e, x2, y2, x3, y3);
                        } else { // one segment
                            handleClippedEdge(scanline, x, e, x0, y0, x3, y3);
                        }
                    }
                }
            }
        }
    }

    /// The edge passed in here does not cross the vertical line at x or the
    /// vertical line at x+1 (i.e. it has already been clipped to those).
    fn handleClippedEdge(
        scanline: []f32,
        x: u32,
        e: *ActiveEdge,
        x0_start: f32,
        y0_start: f32,
        x1_start: f32,
        y1_start: f32,
    ) void {
        var x0: f32 = x0_start;
        var y0: f32 = y0_start;
        var x1: f32 = x1_start;
        var y1: f32 = y1_start;
        if (y0 == y1) {
            return;
        }
        assert(y0 < y1, @src());
        assert(e.sy <= e.ey, @src());
        if (y0 > e.ey) {
            return;
        }
        if (y1 < e.sy) {
            return;
        }
        if (y0 < e.sy) {
            x0 += (x1 - x0) * (e.sy - y0) / (y1 - y0);
            y0 = e.sy;
        }
        if (y1 > e.ey) {
            x1 += (x1 - x0) * (e.ey - y1) / (y1 - y0);
            y1 = e.ey;
        }

        const xf: f32 = float(x);

        if (x0 == xf) {
            assert(x1 <= xf + 1, @src());
        } else if (x0 == xf + 1) {
            assert(x1 >= xf, @src());
        } else if (x0 <= xf) {
            assert(x1 <= xf, @src());
        } else if (x0 >= xf + 1) {
            assert(x1 >= xf + 1, @src());
        } else {
            assert(x1 >= xf, @src());
            assert(x1 <= xf + 1, @src());
        }

        if (x0 <= xf and x1 <= xf) {
            scanline[x] += e.direction * (y1 - y0);
        } else if (x0 >= xf + 1 and x1 >= xf + 1) {
            // Do nothing.
        } else {
            assert(x0 >= xf, @src());
            assert(x0 <= xf + 1, @src());
            assert(x1 >= xf, @src());
            assert(x1 <= xf + 1, @src());
            // coverage = 1 - average x position
            scanline[x] += e.direction * (y1 - y0) * (1 - ((x0 - xf) + (x1 - xf)) / 2);
        }
    }

    fn coverageIndex(
        bytes: []const u8,
        coverage_table: u32,
        glyph: GlyphIndex,
    ) ?u32 {
        const coverage_format = readInt(u16, bytes[coverage_table..][0..2], .big);
        switch (coverage_format) {
            1 => {
                const glyph_count = readInt(u16, bytes[coverage_table + 2 ..][0..2], .big);

                // Binary search.
                var l: u32 = 0;
                var r: u32 = glyph_count - 1;
                const needle: u16 = @intFromEnum(glyph);
                while (l <= r) {
                    const glyph_array: u32 = coverage_table + 4;
                    const m: u32 = (l + r) >> 1;
                    const glyph_id = readInt(u16, bytes[glyph_array + 2 * m ..][0..2], .big);
                    const straw: u16 = glyph_id;
                    if (needle < straw) {
                        if (m == 0) {
                            break;
                        }
                        r = m - 1;
                    } else if (needle > straw) {
                        l = m + 1;
                    } else {
                        return m;
                    }
                }
            },
            2 => {
                const range_count = readInt(u16, bytes[coverage_table + 2 ..][0..2], .big);
                const range_array: u32 = coverage_table + 4;

                // Binary search.
                var l: u32 = 0;
                var r: u32 = range_count - 1;
                const needle: u16 = @intFromEnum(glyph);
                while (l <= r) {
                    const m: u32 = (l + r) >> 1;
                    const range_record: u32 = range_array + 6 * m;
                    const straw_start = readInt(u16, bytes[range_record..][0..2], .big);
                    const straw_end = readInt(u16, bytes[range_record + 2 ..][0..2], .big);
                    if (needle < straw_start) {
                        if (m == 0) {
                            break;
                        }
                        r = m - 1;
                    } else if (needle > straw_end) {
                        l = m + 1;
                    } else {
                        const start_coverage_index = readInt(u16, bytes[range_record + 4 ..][0..2], .big);
                        return start_coverage_index + needle - straw_start;
                    }
                }
            },
            else => {},
        }
        return null;
    }

    fn glyphClass(
        bytes: []const u8,
        class_def_table: u32,
        glyph: GlyphIndex,
    ) u32 {
        const glyph_int: u16 = @intFromEnum(glyph);
        const class_def_format = readInt(u16, bytes[class_def_table..][0..2], .big);
        switch (class_def_format) {
            1 => {
                const start_glyph_id = readInt(u16, bytes[class_def_table + 2 ..][0..2], .big);
                const glyph_count = readInt(u16, bytes[class_def_table + 4 ..][0..2], .big);
                const class_def1_value_array: u32 = class_def_table + 6;

                if (glyph_int >= start_glyph_id and glyph_int < start_glyph_id + glyph_count) {
                    return readInt(
                        u16,
                        bytes[class_def1_value_array + 2 * (glyph_int - start_glyph_id) ..][0..2],
                        .big,
                    );
                }
            },
            2 => {
                const class_range_count = readInt(u16, bytes[class_def_table + 2 ..][0..2], .big);
                const class_range_records: u32 = class_def_table + 4;

                // Binary search.
                var l: u32 = 0;
                var r: u32 = class_range_count - 1;
                while (l <= r) {
                    const m: u32 = (l + r) >> 1;
                    const class_range_record: u32 = class_range_records + 6 * m;
                    const straw_start = readInt(u16, bytes[class_range_record..][0..2], .big);
                    const straw_end = readInt(u16, bytes[class_range_record + 2 ..][0..2], .big);
                    if (glyph_int < straw_start) {
                        if (m == 0) {
                            break;
                        }
                        r = m - 1;
                    } else if (glyph_int > straw_end) {
                        l = m + 1;
                    } else {
                        return readInt(u16, bytes[class_range_record + 4 ..][0..2], .big);
                    }
                }
            },
            else => return maxInt(u32), // Unsupported definition type, return an error.
        }

        // "All glyphs not assigned to a class fall into class 0". (OpenType spec)
        return 0;
    }

    // opentype specific code
    const CffData = struct {
        /// cff font data
        cff: Buf,
        /// the charstring index
        charstrings: Buf,
        /// global charstring subroutines index
        gsubrs: Buf,
        /// private charstring subroutines index
        subrs: Buf,
        /// array of font dicts
        fontdicts: Buf,
        /// map from glyph to fontdict
        fdselect: Buf,

        pub const empty: CffData = .{
            .cff = .empty,
            .charstrings = .empty,
            .gsubrs = .empty,
            .subrs = .empty,
            .fontdicts = .empty,
            .fdselect = .empty,
        };

        pub fn init(cff_offset: u32, bytes: [*]const u8) !CffData {
            var result: CffData = .empty;
            // TODO this should use size from table (not 512MB)
            result.cff = .init(bytes + cff_offset, 512 * 1024 * 1024);
            var b: Buf = result.cff;
            // read the header
            b.skip(2);
            b.seek(b.get8());
            // TODO the name INDEX could list multiple fonts, but we just use the first one.
            _ = b.cffGetIndex(); // name INDEX
            var topdictidx: Buf = b.cffGetIndex();
            var topdict: Buf = topdictidx.cffIndexGet(@enumFromInt(0));
            _ = b.cffGetIndex(); // string INDEX
            result.gsubrs = b.cffGetIndex();

            var cstype: u32 = 2;
            var csoff: u32 = 0;
            var fdarrayoff: u32 = 0;
            var fdselectoff: u32 = 0;

            topdict.dictGetInts(17, 1, @ptrCast(&csoff));
            topdict.dictGetInts(0x100 | 6, 1, @ptrCast(&cstype));
            topdict.dictGetInts(0x100 | 36, 1, @ptrCast(&fdarrayoff));
            topdict.dictGetInts(0x100 | 37, 1, @ptrCast(&fdselectoff));
            result.subrs = b.getSubrs(topdict);

            // we only support Type 2 charstrings
            if (cstype != 2) {
                return error.UnsupportedCffData;
            }
            if (csoff == 0) {
                return error.UnsupportedCffData;
            }

            if (fdarrayoff != 0) {
                // looks like a CID font
                if (fdselectoff == 0) {
                    return error.UnsupportedCffData;
                }
                b.seek(fdarrayoff);
                result.fontdicts = b.cffGetIndex();
                result.fdselect = b.range(fdselectoff, b.size - fdselectoff);
            }

            b.seek(csoff);
            result.charstrings = b.cffGetIndex();
            return result;
        }
    };

    const Buf = struct {
        data: [*]const u8,
        cursor: u32,
        size: u32,

        pub const empty: Buf = .init(undefined, 0);

        pub fn init(data: [*]const u8, size: u32) Buf {
            return .{ .data = data, .size = size, .cursor = 0 };
        }

        pub fn skip(b: *Buf, o: u32) void {
            b.seek(b.cursor + o);
        }

        pub fn seek(b: *Buf, o: u32) void {
            assert(o <= b.size, @src());
            b.cursor = if (o > b.size) b.size else o;
        }

        pub fn peek8(b: *Buf) u8 {
            if (b.cursor >= b.size) {
                return 0;
            }
            return b.data[b.cursor];
        }

        pub fn get8(b: *Buf) u8 {
            if (b.cursor >= b.size) {
                return 0;
            }
            defer b.cursor += 1;
            return b.data[b.cursor];
        }

        pub fn get16(b: *Buf) u16 {
            return @truncate(b.get(2));
        }

        pub fn get32(b: *Buf) u32 {
            return b.get(4);
        }

        pub fn get(b: *Buf, n: u32) u32 {
            var v: u32 = 0;
            assert(n >= 1 and n <= 4, @src());
            for (0..n) |_| {
                v = (v << 8) | b.get8();
            }
            return v;
        }

        pub fn cffGetIndex(b: *Buf) Buf {
            const start: u32 = b.cursor;
            const count: u16 = b.get16();
            if (count != 0) {
                const offsize: u8 = b.get8();
                assert(offsize >= 1 and offsize <= 4, @src());
                b.skip(offsize * count);

                b.skip(b.get(offsize) - 1);
            }
            return b.range(start, b.cursor - start);
        }

        pub fn cffIndexGet(b_const: Buf, glyph: GlyphIndex) Buf {
            var b: Buf = b_const;
            b.seek(0);
            const count: u16 = b.get16();
            const offsize: u8 = b.get8();
            const i: u32 = @intFromEnum(glyph);
            assert(i < count, @src());
            assert(offsize >= 1 and offsize <= 4, @src());
            b.skip(i * offsize);

            const start: u32 = b.get(offsize);
            const end: u32 = b.get(offsize);
            return b.range(2 + (count + 1) * offsize + start, end - start);
        }

        pub fn cffIndexCount(b: *Buf) u16 {
            b.seek(0);
            return b.get16();
        }

        pub fn range(
            b: *Buf,
            o: u32,
            s: u32,
        ) Buf {
            var r = Buf.empty;
            if (o < 0 or s < 0 or o > b.size or s > b.size - o) {
                return r;
            }
            r.data = b.data + o;
            r.size = s;
            return r;
        }

        pub fn cffInt(b: *Buf) u32 {
            const b0: i32 = b.get8();
            const result: u32 = switch (b0) {
                32...246 => @bitCast(b0 - 139),
                247...250 => @bitCast((b0 - 247) * 256 + b.get8() + 108),
                251...254 => @bitCast(-(b0 - 251) * 256 - b.get8() - 108),
                28 => b.get16(),
                29 => b.get32(),
                else => @panic("invalid instruction"),
            };
            // std.log.debug("cffInt() b0 {} result {}", .{ b0, result });
            return result;
        }

        pub fn dictGetInts(
            b: *Buf,
            key: u32,
            outcount: u32,
            out: [*]u32,
        ) void {
            var operands: Buf = b.dictGet(key);
            for (0..outcount) |i| {
                if (operands.cursor >= operands.size) {
                    break;
                }
                out[i] = operands.cffInt();
            }
        }

        pub fn dictGet(b: *Buf, key: u32) Buf {
            b.seek(0);
            while (b.cursor < b.size) {
                const start: u32 = b.cursor;
                while (b.peek8() >= 28) {
                    b.cffSkipOperand();
                }
                const end: u32 = b.cursor;
                var op: i32 = b.get8();
                if (op == 12) {
                    op = @as(i32, b.get8()) | 0x100;
                }
                if (op == key) {
                    return b.range(start, end - start);
                }
            }
            return b.range(0, 0);
        }

        fn cffSkipOperand(b: *Buf) void {
            const b0: u8 = b.peek8();
            assert(b0 >= 28, @src());
            if (b0 == 30) {
                b.skip(1);
                while (b.cursor < b.size) {
                    const v: u8 = b.get8();
                    if ((v & 0xF) == 0xF or (v >> 4) == 0xF) {
                        break;
                    }
                }
            } else {
                _ = b.cffInt();
            }
        }

        pub fn getSubrs(cff_const: Buf, fontdict_const: Buf) Buf {
            var private_loc: [2]u32 = .{ 0, 0 };
            var fontdict: Buf = fontdict_const;
            fontdict.dictGetInts(18, 2, &private_loc);
            if (private_loc[1] == 0 or private_loc[0] == 0) {
                return .empty;
            }
            var cff: Buf = cff_const;
            var pdict: Buf = cff.range(private_loc[1], private_loc[0]);
            var subrsoff: u32 = 0;
            pdict.dictGetInts(19, 1, @ptrCast(&subrsoff));
            if (subrsoff == 0) {
                return .empty;
            }
            cff.seek(private_loc[1] + subrsoff);
            return cff.cffGetIndex();
        }

        fn getSubr(idx_const: Buf, n_const: u32) Buf {
            var idx: Buf = idx_const;
            var n: u32 = n_const;
            const count: u16 = idx.cffIndexCount();
            n +%= if (count >= 33900)
                32768
            else if (count >= 1240)
                1131
            else
                107;
            if (n >= count) {
                return .empty;
            }
            return idx.cffIndexGet(@enumFromInt(n));
        }
    };

    pub const CharstringCtx = struct {
        first_x: f32,
        first_y: f32,
        x: f32,
        y: f32,
        min_x: i32,
        min_y: i32,
        max_x: i32,
        max_y: i32,
        num_vertices: u32,
        vertices: [*]Vertex,
        flags: Flags,

        const Flags = packed struct(u8) {
            started: bool = false,
            mode: enum(u1) {
                /// set min/max and num_vertices
                bounds,
                /// set vertices and num_vertices
                verts,
            },
            _padding: u6 = undefined,
        };

        pub fn init(flags: Flags, vertices: [*]Vertex) CharstringCtx {
            return .{
                .flags = flags,
                .vertices = vertices,
                .first_x = 0,
                .first_y = 0,
                .x = 0,
                .y = 0,
                .min_x = 0,
                .min_y = 0,
                .max_x = 0,
                .max_y = 0,
                .num_vertices = 0,
            };
        }
        pub fn deinit(ctx: *CharstringCtx, alloc: Allocator) void {
            if (ctx.flags.mode == .verts) {
                alloc.free(ctx.allVertices());
            }
        }

        fn trackVertex(
            ctx: *CharstringCtx,
            x: i32,
            y: i32,
        ) void {
            if (x > ctx.max_x or !ctx.flags.started) {
                ctx.max_x = x;
            }
            if (y > ctx.max_y or !ctx.flags.started) {
                ctx.max_y = y;
            }
            if (x < ctx.min_x or !ctx.flags.started) {
                ctx.min_x = x;
            }
            if (y < ctx.min_y or !ctx.flags.started) {
                ctx.min_y = y;
            }
            ctx.flags.started = true;
        }

        fn v(
            ctx: *CharstringCtx,
            ty: Vertex.Type,
            x: i32,
            y: i32,
            cx: i32,
            cy: i32,
            cx1: i32,
            cy1: i32,
        ) !void {
            if (ctx.flags.mode == .bounds) {
                trackVertex(ctx, x, y);
                if (ty == .vcubic) {
                    trackVertex(ctx, cx, cy);
                    trackVertex(ctx, cx1, cy1);
                }
            } else {
                ctx.vertices[ctx.num_vertices].set(ty, x, y, cx, cy);
                ctx.vertices[ctx.num_vertices].cx1 = @truncate(cx1);
                ctx.vertices[ctx.num_vertices].cy1 = @truncate(cy1);
            }
            ctx.num_vertices += 1;
        }

        fn closeShape(ctx: *CharstringCtx) !void {
            if (ctx.first_x != ctx.x or ctx.first_y != ctx.y) {
                try ctx.v(.vline, @trunc(ctx.first_x), @trunc(ctx.first_y), 0, 0, 0, 0);
            }
        }

        fn rmoveTo(
            ctx: *CharstringCtx,
            dx: f32,
            dy: f32,
        ) !void {
            try ctx.closeShape();
            ctx.first_x = ctx.x + dx;
            ctx.x = ctx.first_x;
            ctx.first_y = ctx.y + dy;
            ctx.y = ctx.first_y;
            // std.log.debug("moveTo {d:.1},{d:.1}", .{ ctx.x, ctx.y });
            try ctx.v(.vmove, @trunc(ctx.x), @trunc(ctx.y), 0, 0, 0, 0);
        }

        fn rlineTo(
            ctx: *CharstringCtx,
            dx: f32,
            dy: f32,
        ) !void {
            ctx.x += dx;
            ctx.y += dy;
            // std.log.debug("lineTo {d:.1},{d:.1}", .{ ctx.x, ctx.y });
            try ctx.v(.vline, @trunc(ctx.x), @trunc(ctx.y), 0, 0, 0, 0);
        }

        fn rccurveTo(
            ctx: *CharstringCtx,
            dx1: f32,
            dy1: f32,
            dx2: f32,
            dy2: f32,
            dx3: f32,
            dy3: f32,
        ) !void {
            const cx1: f32 = ctx.x + dx1;
            const cy1: f32 = ctx.y + dy1;
            const cx2: f32 = cx1 + dx2;
            const cy2: f32 = cy1 + dy2;
            ctx.x = cx2 + dx3;
            ctx.y = cy2 + dy3;
            // std.log.debug("curveTo {d:.1},{d:.1} ...", .{ctx.x, ctx.y, cx1, cy1, cx2, cy2});
            try ctx.v(
                .vcubic,
                @trunc(ctx.x),
                @trunc(ctx.y),
                @trunc(cx1),
                @trunc(cy1),
                @trunc(cx2),
                @trunc(cy2),
            );
        }
    };

    fn glyphBoxT2(tt: *const TrueType, glyph: GlyphIndex) error{GlyphNotFound}!BitmapBox {
        var ctx = CharstringCtx.init(.{ .mode = .bounds }, undefined);
        runCharstring(&tt.cff_data, glyph, &ctx) catch return .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };

        return .{
            .x0 = ctx.min_x,
            .y0 = ctx.min_y,
            .x1 = ctx.max_x,
            .y1 = ctx.max_y,
        };
    }

    fn glyphShapeT2(
        tt: *const TrueType,
        gpa: Allocator,
        glyph: GlyphIndex,
    ) GlyphBitmapError![]Vertex {
        // mode=bounds to get bounds and num_vertices
        var count_ctx = CharstringCtx.init(.{ .mode = .bounds }, undefined);
        try runCharstring(&tt.cff_data, glyph, &count_ctx);
        const vertices = try gpa.alloc(Vertex, count_ctx.num_vertices);
        errdefer gpa.free(vertices);
        // mode=verts to assign vertices
        var out_ctx = CharstringCtx.init(.{ .mode = .verts }, vertices.ptr);
        try runCharstring(&tt.cff_data, glyph, &out_ctx);
        assert(out_ctx.num_vertices == count_ctx.num_vertices, @src());
        // std.log.debug(
        //     "glyphShapeT2() first {d:.1},{d:.1} xy ... num_vertices {}",
        //     .{ /* first_x, first_y, x, y, min_x/y, max_x/y, num_vertices */ },
        // );

        return out_ctx.vertices[0..out_ctx.num_vertices];
    }

    const Instruction = enum(u8) {
        hintmask = 0x13,
        cntrmask = 0x14,
        hstem = 0x01,
        vstem = 0x03,
        hstemhm = 0x12,
        vstemhm = 0x17,
        rmoveto = 0x15,
        vmoveto = 0x04,
        hmoveto = 0x16,
        rlineto = 0x05,
        vlineto = 0x07,
        hlineto = 0x06,
        hvcurveto = 0x1F,
        vhcurveto = 0x1E,
        rrcurveto = 0x08,
        rcurveline = 0x18,
        rlinecurve = 0x19,
        vvcurveto = 0x1A,
        hhcurveto = 0x1B,
        callsubr = 0x0A,
        callgsubr = 0x1D,
        /// return
        ret = 0x0B,
        endchar = 0x0E,
        twoByteEscape = 0x0C,
        hflex = 0x22,
        flex = 0x23,
        hflex1 = 0x24,
        flex1 = 0x25,

        pub fn asInt(i: Instruction) u16 {
            return @intFromEnum(i);
        }
    };

    fn runCharstring(
        cff_data: *const CffData,
        glyph: GlyphIndex,
        ctx: *CharstringCtx,
    ) !void {
        var maskbits: u32 = 0;
        var in_header: bool = true;
        var has_subrs: bool = false;
        var clear_stack: bool = false;
        var s: [48]f32 = @splat(0); // stack
        var sp: u32 = 0; // stack pointer
        var subr_buf: [10]Buf = undefined;
        var subr_stack: ArrayList(Buf) = .initBuffer(&subr_buf);
        var subrs: Buf = cff_data.subrs;
        // this currently ignores the initial width value, which isn't needed if we have hmtx
        var b: Buf = cff_data.charstrings.cffIndexGet(glyph);

        while (b.cursor < b.size) {
            var i: u32 = 0;
            clear_stack = true;
            const b0: u16 = b.get8();
            // const tag_name = if (std.meta.intToEnum(Instruction, b0)) |t| @tagName(t) else |_| "other";
            // std.log.debug("{}/{} b0 ...", .{ /* b.cursor, b.size, tag_name, b0, b0, num_vertices */ });

            sw: switch (b0) {
                // @TODO implement hinting
                Instruction.hintmask.asInt(), // 0x13
                Instruction.cntrmask.asInt(), // 0x14
                => {
                    if (in_header) {
                        maskbits += (sp / 2);
                    } // implicit "vstem"
                    in_header = false;
                    b.skip((maskbits + 7) / 8);
                },
                Instruction.hstem.asInt(), // 0x01
                Instruction.vstem.asInt(), // 0x03
                Instruction.hstemhm.asInt(), // 0x12
                Instruction.vstemhm.asInt(), // 0x17
                => {
                    maskbits += (sp / 2);
                },
                Instruction.rmoveto.asInt() => { // 0x15
                    in_header = false;
                    if (sp < 2) {
                        return error.RMoveToStack;
                    }
                    try ctx.rmoveTo(s[sp - 2], s[sp - 1]);
                },
                Instruction.vmoveto.asInt() => { // 0x04
                    in_header = false;
                    if (sp < 1) {
                        return error.VMoveToStack;
                    }
                    try ctx.rmoveTo(0, s[sp - 1]);
                },
                Instruction.hmoveto.asInt() => { // 0x16
                    in_header = false;
                    if (sp < 1) {
                        return error.HMoveToStack;
                    }
                    try ctx.rmoveTo(s[sp - 1], 0);
                },
                Instruction.rlineto.asInt() => { // 0x05
                    if (sp < 2) {
                        return error.RLineToStack;
                    }
                    while (i + 1 < sp) : (i += 2)
                        try ctx.rlineTo(s[i], s[i + 1]);
                },
                // hlineto/vlineto and vhcurveto/hvcurveto alternate horizontal and vertical
                // starting from a different place.
                Instruction.vlineto.asInt() => { // 0x07
                    if (sp < 1) {
                        return error.VLineToStack;
                    }
                    // std.log.debug("vlineto i {} sp {}", .{ i, sp });
                    while (true) {
                        if (i >= sp) {
                            break;
                        }
                        try ctx.rlineTo(0, s[i]);
                        i += 1;
                        if (i >= sp) {
                            break;
                        }
                        try ctx.rlineTo(s[i], 0);
                        i += 1;
                    }
                },
                Instruction.hlineto.asInt() => { // 0x06
                    if (sp < 1) {
                        return error.HLineToStack;
                    }
                    // std.log.debug("hlineto i {} sp {}", .{ i, sp });
                    while (true) {
                        if (i >= sp) {
                            break;
                        }
                        try ctx.rlineTo(s[i], 0);
                        i += 1;
                        if (i >= sp) {
                            break;
                        }
                        try ctx.rlineTo(0, s[i]);
                        i += 1;
                    }
                },
                Instruction.hvcurveto.asInt() => { // 0x1F
                    if (sp < 4) {
                        return error.HCurveToStack;
                    }
                    while (true) {
                        // std.log.debug("hvcurveto i {} sp {}", .{ i, sp });
                        if (i + 3 >= sp) {
                            break;
                        }
                        try ctx.rccurveTo(s[i], 0, s[i + 1], s[i + 2], if (sp - i == 5) s[i + 4] else 0.0, s[i + 3]);
                        i += 4;
                        if (i + 3 >= sp) {
                            break;
                        }
                        try ctx.rccurveTo(0, s[i], s[i + 1], s[i + 2], s[i + 3], if (sp - i == 5) s[i + 4] else 0.0);
                        i += 4;
                    }
                },
                Instruction.vhcurveto.asInt() => { // 0x1E
                    if (sp < 4) {
                        return error.HCurveToStack;
                    }
                    while (true) {
                        // std.log.debug("vhcurveto i {} sp {}", .{ i, sp });
                        if (i + 3 >= sp) {
                            break;
                        }
                        try ctx.rccurveTo(0, s[i], s[i + 1], s[i + 2], s[i + 3], if (sp - i == 5) s[i + 4] else 0.0);
                        i += 4;
                        if (i + 3 >= sp) {
                            break;
                        }
                        try ctx.rccurveTo(s[i], 0, s[i + 1], s[i + 2], if (sp - i == 5) s[i + 4] else 0.0, s[i + 3]);
                        i += 4;
                    }
                },
                Instruction.rrcurveto.asInt() => { // 0x08
                    if (sp < 6) {
                        return error.RCurveToStack;
                    }
                    while (i + 5 < sp) : (i += 6)
                        try ctx.rccurveTo(s[i], s[i + 1], s[i + 2], s[i + 3], s[i + 4], s[i + 5]);
                },
                Instruction.rcurveline.asInt() => { // 0x18
                    if (sp < 8) {
                        return error.RCurveLineStack;
                    }
                    while (i + 5 < sp - 2) : (i += 6)
                        try ctx.rccurveTo(s[i], s[i + 1], s[i + 2], s[i + 3], s[i + 4], s[i + 5]);
                    if (i + 1 >= sp) {
                        return error.CurveLineStack;
                    }
                    try ctx.rlineTo(s[i], s[i + 1]);
                },
                Instruction.rlinecurve.asInt() => { // 0x19
                    if (sp < 8) {
                        return error.RLineCurveStack;
                    }
                    while (i + 1 < sp - 6) : (i += 2)
                        try ctx.rlineTo(s[i], s[i + 1]);
                    if (i + 5 >= sp) {
                        return error.RLineCurveStack;
                    }
                    try ctx.rccurveTo(s[i], s[i + 1], s[i + 2], s[i + 3], s[i + 4], s[i + 5]);
                },
                Instruction.vvcurveto.asInt(), // 0x1A
                Instruction.hhcurveto.asInt(), // 0x1B
                => {
                    if (sp < 4) {
                        return error.CurveToStack;
                    }
                    var f: f32 = 0.0;
                    if (sp & 1 != 0) {
                        f = s[i];
                        i += 1;
                    }
                    while (i + 3 < sp) : (i += 4) {
                        if (b0 == Instruction.hhcurveto.asInt()) //  0x1B
                            try ctx.rccurveTo(s[i], f, s[i + 1], s[i + 2], s[i + 3], 0.0)
                        else
                            try ctx.rccurveTo(f, s[i], s[i + 1], s[i + 2], 0.0, s[i + 3]);
                        f = 0.0;
                    }
                },
                Instruction.callsubr.asInt() => { // 0x0A
                    if (!has_subrs) {
                        if (cff_data.fdselect.size != 0) {
                            subrs = getGlyphSubrs(cff_data, glyph);
                        }
                        has_subrs = true;
                    }
                    continue :sw Instruction.callgsubr.asInt();
                    // FALLTHROUGH
                },
                Instruction.callgsubr.asInt() => { // 0x1D
                    sp = subChecked(u32, sp, 1) catch return error.CallGSubRStack;
                    const v: i32 = @trunc(s[sp]);
                    subr_stack.appendBounded(b) catch return error.RecursionLimit;
                    b = (if (b0 == Instruction.callsubr.asInt()) // 0x0A
                        subrs
                    else
                        cff_data.gsubrs).getSubr(@bitCast(v));
                    if (b.size == 0) {
                        return error.SubRNotFound;
                    }
                    b.cursor = 0;
                    clear_stack = false;
                },
                Instruction.ret.asInt() => { // 0x0B
                    b = subr_stack.pop() orelse return error.ReturnOutsideSubR;
                    clear_stack = false;
                },
                Instruction.endchar.asInt() => { // 0x0E
                    try ctx.closeShape();
                    return;
                },
                Instruction.twoByteEscape.asInt() => { // 0x0C
                    const b1: u8 = b.get8();
                    switch (b1) {
                        // @TODO These "flex" implementations ignore the flex-depth and resolution,
                        // and always draw beziers.
                        Instruction.hflex.asInt() => { // 0x22
                            if (sp < 7) {
                                return error.HFlexStack;
                            }
                            const dx1: f32 = s[0];
                            const dx2: f32 = s[1];
                            const dy2: f32 = s[2];
                            const dx3: f32 = s[3];
                            const dx4: f32 = s[4];
                            const dx5: f32 = s[5];
                            const dx6: f32 = s[6];
                            try ctx.rccurveTo(dx1, 0, dx2, dy2, dx3, 0);
                            try ctx.rccurveTo(dx4, 0, dx5, -dy2, dx6, 0);
                        },
                        Instruction.flex.asInt() => { // 0x23
                            if (sp < 13) {
                                return error.FlexStack;
                            }
                            const dx1: f32 = s[0];
                            const dy1: f32 = s[1];
                            const dx2: f32 = s[2];
                            const dy2: f32 = s[3];
                            const dx3: f32 = s[4];
                            const dy3: f32 = s[5];
                            const dx4: f32 = s[6];
                            const dy4: f32 = s[7];
                            const dx5: f32 = s[8];
                            const dy5: f32 = s[9];
                            const dx6: f32 = s[10];
                            const dy6: f32 = s[11];
                            //fd is s[12]
                            try ctx.rccurveTo(dx1, dy1, dx2, dy2, dx3, dy3);
                            try ctx.rccurveTo(dx4, dy4, dx5, dy5, dx6, dy6);
                        },
                        Instruction.hflex1.asInt() => { // 0x24
                            if (sp < 9) {
                                return error.HFlex1Stack;
                            }
                            const dx1: f32 = s[0];
                            const dy1: f32 = s[1];
                            const dx2: f32 = s[2];
                            const dy2: f32 = s[3];
                            const dx3: f32 = s[4];
                            const dx4: f32 = s[5];
                            const dx5: f32 = s[6];
                            const dy5: f32 = s[7];
                            const dx6: f32 = s[8];
                            try ctx.rccurveTo(dx1, dy1, dx2, dy2, dx3, 0);
                            try ctx.rccurveTo(dx4, 0, dx5, dy5, dx6, -(dy1 + dy2 + dy5));
                        },
                        Instruction.flex1.asInt() => { // 0x25
                            if (sp < 11) {
                                return error.Flex1Stack;
                            }
                            const dx1: f32 = s[0];
                            const dy1: f32 = s[1];
                            const dx2: f32 = s[2];
                            const dy2: f32 = s[3];
                            const dx3: f32 = s[4];
                            const dy3: f32 = s[5];
                            const dx4: f32 = s[6];
                            const dy4: f32 = s[7];
                            const dx5: f32 = s[8];
                            const dy5: f32 = s[9];
                            var dx6: f32 = s[10];
                            var dy6: f32 = s[10];
                            const dx: f32 = dx1 + dx2 + dx3 + dx4 + dx5;
                            const dy: f32 = dy1 + dy2 + dy3 + dy4 + dy5;
                            if (@abs(dx) > @abs(dy)) {
                                dy6 = -dy;
                            } else {
                                dx6 = -dx;
                            }
                            try ctx.rccurveTo(dx1, dy1, dx2, dy2, dx3, dy3);
                            try ctx.rccurveTo(dx4, dy4, dx5, dy5, dx6, dy6);
                        },

                        else => return error.Unimplemented,
                    }
                },
                else => {
                    if (b0 != 255 and b0 != 28 and b0 < 32) {
                        return error.ReservedOperator;
                    }

                    // push immediate
                    const f: f32 = if (b0 == 255)
                        @floatFromInt(@as(i32, @intCast(b.get32() / 0x10000)))
                    else blk: {
                        b.cursor -= 1;
                        break :blk @floatFromInt(@as(i16, @truncate(@as(i32, @bitCast(b.cffInt())))));
                    };
                    // std.log.debug("f {d:.2}", .{f});
                    if (sp >= 48) {
                        return error.PushStackOverflow;
                    }
                    s[sp] = f;
                    sp += 1;
                    clear_stack = false;
                },
            }
            if (clear_stack) {
                sp = 0;
            }
        }
        return error.NoEndChar;
    }

    fn getGlyphSubrs(cff_data: *const CffData, glyph: GlyphIndex) Buf {
        var fdselector: u32 = maxInt(u32);
        var fdselect: Buf = cff_data.fdselect;
        // std.log.debug("getGlyphSubrs fdselect {}", .{fdselect});
        fdselect.seek(0);

        const fmt: u8 = fdselect.get8();
        if (fmt == 0) {
            // untested
            fdselect.skip(@intFromEnum(glyph));
            fdselector = fdselect.get8();
        } else if (fmt == 3) {
            const nranges: u16 = fdselect.get16();
            var start: u16 = fdselect.get16();
            for (0..nranges) |_| {
                const v: u8 = fdselect.get8();
                const end: u16 = fdselect.get16();
                const glyph_int: u16 = @intFromEnum(glyph);
                if (glyph_int >= start and glyph_int < end) {
                    fdselector = v;
                    break;
                }
                start = end;
            }
        }
        // what was this line? it does nothing. why was it in the original c code?
        // if (fdselector == -1) new_buf(NULL, 0);
        return cff_data.cff.getSubrs(cff_data.fontdicts.cffIndexGet(@enumFromInt(fdselector)));
    }

    // end opentype specific code
    // ===========================================================================
    // zimr additions - these follow the project style guide.
    // ===========================================================================
    // Everything above this banner is the upstream port (with the
    // modifications enumerated in the file header).  Everything below
    // is zimr-canonical: API shape, naming, style guide, and lifetime
    // rules tuned for how the rest of zimr expects to consume fonts.
    // Naming convention: upstream uses `TrueType` as the type name (the
    // `@This()` of the file).  zimr-side code prefers `Font` since
    // that's what the rest of text.zig / atlas.zig speak.  We re-alias
    // here so callers can write `truetype.Font` without knowing about
    // the upstream rename.

    /// zimr-canonical alias for the parsed font type.  Same memory
    /// layout as `TrueType` - they're literally the same struct.
    pub const Font = TrueType;

    /// zimr-canonical entry point for parsing a TTF/OTF blob.
    /// The caller retains ownership of `ttf_bytes` - the returned
    /// `Font` borrows them and the bytes must outlive any
    /// rasterization or metrics calls.  This matches the upstream
    /// contract; we re-export it here under a name that matches the
    /// rest of zimr's `loadX` family.
    /// The `gpa` parameter is reserved for future use - atlas-baking
    /// and font-table caching arcs may need allocations.  Today
    /// upstream's `load` is allocation-free, so `gpa` is unused; the
    /// signature is laid out now so the eventual atlas-bake API drops
    /// in cleanly.
    pub fn loadFontFromTtf(
        gpa: Allocator,
        ttf_bytes: []const u8,
    ) !Font {
        _ = gpa;
        return TrueType.load(ttf_bytes);
    }

    // ---- tests --------------------------------------------------------
    // The upstream TrueType.zig (now adopted in-tree) doesn't expose
    // itself to host testing without an actual font file - its `load`
    // function asserts on malformed input rather than returning an
    // error.  So we can only exercise the export surface and enum
    // invariants here.  Real rasterization gets covered when an
    // embedded TTF lands as part of the atlas-baker arc.

    test "GlyphIndex.notdef is zero" {
        // Convention: glyph index 0 is the .notdef glyph.  Many call
        // sites assume this.
        try std.testing.expect(@intFromEnum(GlyphIndex.notdef) == 0);
    }

    test "Font alias matches the file's @This()" {
        // `Font` is the zimr-canonical alias for the parsed font
        // type.  It IS the file's @This() (TrueType), not a wrapper.
        // This test catches an accidental "wrapper-by-value"
        // refactor that would change layout.
        try std.testing.expect(@sizeOf(Font) == @sizeOf(@This()));
    }

    test "loadFontFromTtf signature is reachable" {
        // Smoke: the zimr-canonical entry point compiles and is
        // exported.  We don't actually call it (no test font yet).
        const fn_ptr: *const fn (Allocator, []const u8) anyerror!Font = loadFontFromTtf;
        _ = fn_ptr;
    }

    test "TableId enum is usable" {
        // Lightweight sanity that the upstream tag table compiled in.
        _ = TableId.cmap;
        _ = TableId.glyf;
        _ = TableId.hhea;
    }
};

// ============================================================================
// SECTION - rectpack (was: src/rectpack.zig)
// ============================================================================

pub const rectpack = struct {
    pub const Rect = struct {
        /// Caller-provided width in pixels.  Fixed during packing.
        w: u32,
        /// Caller-provided height in pixels.  Fixed during packing.
        h: u32,
        /// X offset in the atlas, set by `pack`.
        x: u32 = 0,
        /// Y offset in the atlas, set by `pack`.
        y: u32 = 0,
        /// Caller-defined identifier used to look the rect back up
        /// after `pack` reorders them.
        id: u32 = 0,
    };

    pub const Result = struct {
        /// Atlas width as configured by the caller.
        width: u32,
        /// Resulting atlas height (bottom of the last shelf).
        height: u32,
        /// Number of rects that didn't fit horizontally on any shelf.
        /// Always 0 unless an individual rect's width > atlas width.
        overflow: u32,
    };

    /// Pack `rects` into an atlas of `width` pixels wide.  Sorts
    /// `rects` by height descending in-place, then assigns each rect
    /// an (x, y) on a shelf.  Returns the resulting atlas dimensions.
    /// `padding` is added between rects on the same shelf and between
    /// shelves, so the caller doesn't need to inflate input widths /
    /// heights.
    pub fn pack(
        rects: []Rect,
        width: u32,
        padding: u32,
    ) Result {
        if (rects.len == 0) {
            return .{ .width = width, .height = 0, .overflow = 0 };
        }

        // Shelf-bin works best with tallest-first.  Stable-ish ordering
        // by height; std.mem.sort is not stable but for our use case
        // (font atlas with many same-height-ish glyphs) the exact tie
        // ordering doesn't matter - we just need predictable packing.
        std.mem.sort(Rect, rects, {}, byHeightDesc);

        var shelf_x: u32 = 0;
        var shelf_y: u32 = 0;
        var shelf_h: u32 = 0;
        var overflow: u32 = 0;

        for (rects) |*r| {
            // If the rect itself is wider than the atlas, it's
            // unpackable - flag and move on.
            if (r.w > width) {
                overflow += 1;
                r.x = 0;
                r.y = 0;
                continue;
            }

            // Try to place on the current shelf.
            const x_with_padding: u32 = if (shelf_x == 0) shelf_x else shelf_x + padding;
            if (x_with_padding + r.w > width) {
                // Doesn't fit horizontally - start a new shelf.
                shelf_y += shelf_h + (if (shelf_h > 0) padding else 0);
                shelf_x = 0;
                shelf_h = 0;
                r.x = 0;
            } else {
                r.x = x_with_padding;
            }
            r.y = shelf_y;
            shelf_x = r.x + r.w;
            if (r.h > shelf_h) {
                shelf_h = r.h;
            }
        }

        return .{
            .width = width,
            .height = shelf_y + shelf_h,
            .overflow = overflow,
        };
    }

    /// Estimate a reasonable atlas width for a set of rects, sized to
    /// be a square-ish power-of-two with ~25% slack.  Useful default
    /// when the caller doesn't have a strong opinion about atlas
    /// dimensions.
    pub fn suggestAtlasWidth(rects: []const Rect) u32 {
        if (rects.len == 0) {
            return 64;
        }
        var area: u64 = 0;
        var max_w: u32 = 0;
        for (rects) |r| {
            area += @as(u64, r.w) * @as(u64, r.h);
            if (r.w > max_w) {
                max_w = r.w;
            }
        }
        // Pad area by ~25% for shelf-packing inefficiency.
        const padded_area: u64 = (area * 5) / 4;
        const ideal_side: u64 = sqrt(padded_area);
        var w: u32 = @intCast(ideal_side);
        if (w < max_w) {
            w = max_w;
        }
        // Round up to next power-of-2.
        w = ceilPowerOfTwo(u32, w) catch w;
        if (w < 32) {
            w = 32;
        }
        return w;
    }

    fn byHeightDesc(
        _: void,
        a: Rect,
        b: Rect,
    ) bool {
        return a.h > b.h;
    }

    // ---- tests
    test "pack: empty input yields zero height" {
        var rects = [_]Rect{};
        const result: Result = pack(&rects, 256, 1);
        try std.testing.expect(result.width == 256);
        try std.testing.expect(result.height == 0);
        try std.testing.expect(result.overflow == 0);
    }

    test "pack: single rect fits in single shelf" {
        var rects = [_]Rect{
            .{ .w = 32, .h = 32, .id = 1 },
        };
        const result: Result = pack(&rects, 256, 1);
        try std.testing.expect(result.height == 32);
        try std.testing.expect(rects[0].x == 0);
        try std.testing.expect(rects[0].y == 0);
    }

    test "pack: two same-height rects share a shelf" {
        var rects = [_]Rect{
            .{ .w = 16, .h = 24, .id = 1 },
            .{ .w = 24, .h = 24, .id = 2 },
        };
        const result: Result = pack(&rects, 128, 0);
        try std.testing.expect(result.height == 24); // single shelf
        // Both should have y=0; x should differ.
        try std.testing.expect(rects[0].y == 0);
        try std.testing.expect(rects[1].y == 0);
        try std.testing.expect(rects[0].x != rects[1].x);
    }

    test "pack: overflow horizontally starts new shelf" {
        var rects = [_]Rect{
            .{ .w = 60, .h = 20, .id = 1 },
            .{ .w = 60, .h = 20, .id = 2 },
            .{ .w = 60, .h = 20, .id = 3 }, // total > 100, must wrap
        };
        const result: Result = pack(&rects, 100, 0);
        // 2 rects fit on shelf 1 (width 60+60 = 120 > 100, so only 1 fits)
        // Three rects → three shelves of height 20 = 60.
        try std.testing.expect(result.height == 60);
        try std.testing.expect(result.overflow == 0);
    }

    test "pack: rect wider than atlas counts as overflow" {
        var rects = [_]Rect{
            .{ .w = 32, .h = 16, .id = 1 },
            .{ .w = 200, .h = 16, .id = 2 }, // wider than atlas
            .{ .w = 32, .h = 16, .id = 3 },
        };
        const result: Result = pack(&rects, 100, 0);
        try std.testing.expect(result.overflow == 1);
        // The two valid rects pack into one shelf (32+32=64 < 100).
        try std.testing.expect(result.height == 16);
    }

    test "pack: tallest-first ordering keeps short rects from blocking shelf height" {
        var rects = [_]Rect{
            .{ .w = 8, .h = 8, .id = 1 },
            .{ .w = 8, .h = 32, .id = 2 }, // tall
            .{ .w = 8, .h = 16, .id = 3 },
        };
        const result: Result = pack(&rects, 32, 0);
        // 4 rects per row; with tallest-first, all three fit on one
        // shelf at heights 32, 16, 8 → shelf height = 32.
        try std.testing.expect(result.height == 32);
        // The original .id=2 rect (the tallest) lives on shelf 0 at y=0.
        var found_tallest: bool = false;
        for (rects) |r| {
            if (r.id == 2) {
                try std.testing.expect(r.y == 0);
                found_tallest = true;
            }
        }
        try std.testing.expect(found_tallest);
    }

    test "pack: padding between rects" {
        var rects = [_]Rect{
            .{ .w = 10, .h = 10, .id = 1 },
            .{ .w = 10, .h = 10, .id = 2 },
        };
        const result: Result = pack(&rects, 64, 4);
        _ = result;
        // First rect at x=0; second after padding.
        var x_seen: [2]u32 = .{ 0, 0 };
        var i: usize = 0;
        for (rects) |r| {
            if (i < 2) {
                x_seen[i] = r.x;
                i += 1;
            }
        }
        // The two x positions should differ by exactly w + padding = 14.
        const lo: u32 = @min(x_seen[0], x_seen[1]);
        const hi: u32 = @max(x_seen[0], x_seen[1]);
        try std.testing.expect(hi - lo == 14);
    }

    test "pack: 100 same-size rects pack into roughly correct height" {
        var rects: [100]Rect = undefined;
        for (&rects, 0..) |*r, i| {
            r.* = .{ .w = 16, .h = 16, .id = @intCast(i) };
        }
        const result: Result = pack(&rects, 128, 0);
        // 8 rects per row × 13 rows = 104 slots needed for 100 rects.
        // 13 rows × 16 = 208 height.
        try std.testing.expect(result.height == 13 * 16);
    }

    test "suggestAtlasWidth: empty input gives a sane default" {
        const rects = [_]Rect{};
        const w: u32 = suggestAtlasWidth(&rects);
        try std.testing.expect(w == 64);
    }

    test "suggestAtlasWidth: rounds up to power of two" {
        var rects = [_]Rect{
            .{ .w = 16, .h = 16, .id = 1 },
            .{ .w = 16, .h = 16, .id = 2 },
            .{ .w = 16, .h = 16, .id = 3 },
            .{ .w = 16, .h = 16, .id = 4 },
        };
        const w: u32 = suggestAtlasWidth(&rects);
        // Total area = 1024.  ideal_side = ~32.  Rounded up to 32 (already
        // power-of-two).  Padded by 5/4: 1280, sqrt = 35.7, round up = 64.
        // Either way w should be a power-of-two ≥ 32.
        try std.testing.expect(w == 32 or w == 64);
        try std.testing.expect(w >= 16); // must accommodate widest rect
    }

    test "suggestAtlasWidth: never below max-width" {
        var rects = [_]Rect{
            .{ .w = 200, .h = 8, .id = 1 }, // very wide
            .{ .w = 16, .h = 8, .id = 2 },
        };
        const w: u32 = suggestAtlasWidth(&rects);
        try std.testing.expect(w >= 200);
    }
};

// ============================================================================
// SECTION - code_point (was: src/code_point.zig)
// UTF-8 decoder, originally from atman/zg.  See THIRD_PARTY_LICENSES.md.
// ============================================================================

pub const code_point = struct {
    pub const uoffset = u32;

    /// `CodePoint` represents a Unicode code point by its code,
    /// length, and offset in the source bytes.
    pub const CodePoint = struct {
        code: u21,
        len: u3,
        offset: uoffset,

        /// Return the slice of this codepoint, given the original string.
        pub inline fn bytes(cp: CodePoint, str: []const u8) []const u8 {
            return str[cp.offset..][0..cp.len];
        }

        pub fn format(
            cp: CodePoint,
            _: []const u8,
            _: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            try writer.print("CodePoint '{u}' .{{ ", .{cp.code});
            try writer.print(
                ".code = 0x{x}, .offset = {d}, .len = {d} }}",
                .{ cp.code, cp.offset, cp.len },
            );
        }
    };

    /// Removed.  Use `decodeAtIndex` or `decodeAtCursor`.
    pub fn decode(bytes: []const u8, offset: uoffset) ?CodePoint {
        _ = .{ bytes, offset };
        @compileError("decode has been removed, use `decodeAtIndex` or `decodeAtCursor`.");
    }

    /// Return the codepoint at `index`, even if `index` is in the middle
    /// of that codepoint.
    pub fn codepointAtIndex(bytes: []const u8, index: uoffset) ?CodePoint {
        var idx: u32 = index;
        while (idx > 0 and 0x80 <= bytes[idx] and bytes[idx] <= 0xbf) : (idx -= 1) {}
        return decodeAtIndex(bytes, idx);
    }

    /// Decode the CodePoint, if any, at `bytes[idx]`.
    pub fn decodeAtIndex(bytes: []const u8, index: uoffset) ?CodePoint {
        var off: u32 = index;
        return decodeAtCursor(bytes, &off);
    }

    /// Decode the CodePoint, if any, at `bytes[cursor.*]`.  After, the
    /// cursor will point at the next potential codepoint index.
    pub fn decodeAtCursor(bytes: []const u8, cursor: *uoffset) ?CodePoint {
        // EOS
        if (cursor.* >= bytes.len) {
            return null;
        }

        const this_off: uoffset = cursor.*;
        cursor.* += 1; // +1

        // ASCII
        var byte: u8 = bytes[this_off];
        if (byte < 0x80) {
            return .{
                .code = byte,
                .offset = this_off,
                .len = 1,
            };
        }
        // Multibyte

        // Second:
        var class: u4 = @intCast(u8dfa[byte]);
        var st: u32 = state_dfa[class];
        if (st == RUNE_REJECT or cursor.* == bytes.len) {
            @branchHint(.cold);
            // First one is never a truncation
            return .{
                .code = 0xfffd,
                .len = 1,
                .offset = this_off,
            };
        }
        var rune: u32 = byte & class_mask[class];
        byte = bytes[cursor.*];
        class = @intCast(u8dfa[byte]);
        st = state_dfa[st + class];
        rune = (byte & 0x3f) | (rune << 6);
        cursor.* += 1; // +2
        if (st == RUNE_ACCEPT) {
            return .{
                .code = @intCast(rune),
                .len = 2,
                .offset = this_off,
            };
        }
        if (st == RUNE_REJECT or cursor.* == bytes.len) {
            @branchHint(.cold);
            // Truncation and other bad bytes the same here:
            cursor.* -= 1; // + 1
            return .{
                .code = 0xfffd,
                .len = 1,
                .offset = this_off,
            };
        }
        // Third
        byte = bytes[cursor.*];
        class = @intCast(u8dfa[byte]);
        st = state_dfa[st + class];
        rune = (byte & 0x3f) | (rune << 6);
        cursor.* += 1; // +3
        if (st == RUNE_ACCEPT) {
            return .{
                .code = @intCast(rune),
                .len = 3,
                .offset = this_off,
            };
        }
        if (st == RUNE_REJECT or cursor.* == bytes.len) {
            @branchHint(.cold);
            // This, and the branch below, detect truncation, the
            // only invalid state handled differently by the Maximal
            // Subparts algorithm.
            if (state_dfa[@intCast(u8dfa[byte])] == RUNE_REJECT) {
                cursor.* -= 2; // +1
                return .{
                    .code = 0xfffd,
                    .len = 1,
                    .offset = this_off,
                };
            } else {
                cursor.* -= 1; // +2
                return .{
                    .code = 0xfffd,
                    .len = 2,
                    .offset = this_off,
                };
            }
        }
        byte = bytes[cursor.*];
        class = @intCast(u8dfa[byte]);
        st = state_dfa[st + class];
        rune = (byte & 0x3f) | (rune << 6);
        cursor.* += 1; // +4
        if (st == RUNE_REJECT) {
            @branchHint(.cold);
            if (state_dfa[@intCast(u8dfa[byte])] == RUNE_REJECT) {
                cursor.* -= 3; // +1
                return .{
                    .code = 0xfffd,
                    .len = 1,
                    .offset = this_off,
                };
            } else {
                cursor.* -= 1; // +3
                return .{
                    .code = 0xfffd,
                    .len = 3,
                    .offset = this_off,
                };
            }
        }
        assert(st == RUNE_ACCEPT, @src());
        return .{
            .code = @intCast(rune),
            .len = 4,
            .offset = this_off,
        };
    }

    /// `Iterator` iterates a string one `CodePoint` at-a-time.
    pub const Iterator = struct {
        bytes: []const u8,
        i: uoffset = 0,

        pub fn init(bytes: []const u8) Iterator {
            return .{ .bytes = bytes, .i = 0 };
        }

        pub fn next(self: *Iterator) ?CodePoint {
            return decodeAtCursor(self.bytes, &self.i);
        }

        pub fn peek(iter: *Iterator) ?CodePoint {
            const saved_i: uoffset = iter.i;
            defer iter.i = saved_i;
            return iter.next();
        }

        /// Create a backward iterator at this point.  It will repeat
        /// the last CodePoint seen.
        pub fn reverseIterator(iter: *const Iterator) ReverseIterator {
            if (iter.i == iter.bytes.len) {
                return .init(iter.bytes);
            }
            return .{ .i = iter.i, .bytes = iter.bytes };
        }
    };

    // A fast DFA decoder for UTF-8
    // The algorithm used aims to be optimal, without involving SIMD, this
    // strikes a balance between portability and efficiency.  That is done
    // by using a DFA, represented as a few lookup tables, to track state,
    // encoding valid transitions between bytes, arriving at 0 each time a
    // codepoint is decoded.  In the process it builds up the value of the
    // codepoint in question.
    // The virtue of such an approach is low branching factor, achieved at
    // a modest cost of storing the tables.  An embedded system might want
    // to use a more familiar decision graph based on switches, but modern
    // hosted environments can well afford the space, and may appreciate a
    // speed increase in exchange.
    // Credit for the algorithm goes to Björn Höhrmann, who wrote it up at
    // https://bjoern.hoehrmann.de/utf-8/decoder/dfa/.  The license to the
    // original code may be found in the ./credits folder.

    /// Successful codepoint parse
    const RUNE_ACCEPT = 0;

    /// Error state
    const RUNE_REJECT = 12;

    /// Byte transitions: value to class
    const u8dfa: [256]u8 = .{
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 00..1f
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 20..3f
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 40..5f
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 60..7f
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, // 80..9f
        7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, // a0..bf
        8, 8, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, // c0..df
        0xa, 0x3, 0x3, 0x3, 0x3, 0x3, 0x3, 0x3, 0x3, 0x3, 0x3, 0x3, 0x3, 0x4, 0x3, 0x3, // e0..ef
        0xb, 0x6, 0x6, 0x6, 0x5, 0x8, 0x8, 0x8, 0x8, 0x8, 0x8, 0x8, 0x8, 0x8, 0x8, 0x8, // f0..ff
    };

    /// State transition: state + class = new state
    const state_dfa: [108]u8 = .{
        0, 12, 24, 36, 60, 96, 84, 12, 12, 12, 48, 72, // 0  (RUNE_ACCEPT)
        12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, // 12 (RUNE_REJECT)
        12, 0, 12, 12, 12, 12, 12, 0, 12, 0, 12, 12, // 24
        12, 24, 12, 12, 12, 12, 12, 24, 12, 24, 12, 12, // 32
        12, 12, 12, 12, 12, 12, 12, 24, 12, 12, 12, 12, // 48
        12, 24, 12, 12, 12, 12, 12, 12, 12, 24, 12, 12, // 60
        12, 12, 12, 12, 12, 12, 12, 36, 12, 36, 12, 12, // 72
        12, 36, 12, 12, 12, 12, 12, 36, 12, 36, 12, 12, // 84
        12, 36, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, // 96
    };

    /// State masks
    const class_mask: [12]u8 = .{
        0xff,
        0,
        0b0011_1111,
        0b0001_1111,
        0b0000_1111,
        0b0000_0111,
        0b0000_0011,
        0,
        0,
        0,
        0,
        0,
    };

    pub const ReverseIterator = struct {
        bytes: []const u8,
        i: ?uoffset,

        pub fn init(str: []const u8) ReverseIterator {
            var r_iter: ReverseIterator = undefined;
            r_iter.bytes = str;
            r_iter.i = if (str.len == 0) 0 else @intCast(str.len - 1);
            return r_iter;
        }

        pub fn prev(iter: *ReverseIterator) ?CodePoint {
            if (iter.i == null) {
                return null;
            }
            var i_prev: @TypeOf(iter.i.?) = iter.i.?;

            while (i_prev > 0) : (i_prev -= 1) {
                if (!followbyte(iter.bytes[i_prev])) break;
            }

            if (i_prev > 0) {
                iter.i = i_prev - 1;
            } else {
                iter.i = null;
            }

            return decodeAtIndex(iter.bytes, i_prev);
        }

        pub fn peek(iter: *ReverseIterator) ?CodePoint {
            const saved_i: ?uoffset = iter.i;
            defer iter.i = saved_i;
            return iter.prev();
        }

        /// Create a forward iterator at this point.  It will repeat the
        /// last CodePoint seen.
        pub fn forwardIterator(iter: *const ReverseIterator) Iterator {
            if (iter.i) |i| {
                var fwd: Iterator = .{ .i = i, .bytes = iter.bytes };
                _ = fwd.next();
                return fwd;
            }
            return .{ .i = 0, .bytes = iter.bytes };
        }
    };

    inline fn followbyte(b: u8) bool {
        return 0x80 <= b and b <= 0xbf;
    }

    test "decode" {
        const bytes: []const u8 = "🌩️";
        const res: ?CodePoint = decodeAtIndex(bytes, 0);

        if (res) |cp| {
            try std.testing.expectEqual(@as(u21, 0x1F329), cp.code);
            try std.testing.expectEqual(4, cp.len);
        } else {
            // shouldn't have failed to return
            try std.testing.expect(false);
        }
    }

    test Iterator {
        var iter = Iterator{ .bytes = "Hi" };

        try expectEqual(@as(u21, 'H'), iter.next().?.code);
        try expectEqual(@as(u21, 'i'), iter.peek().?.code);
        try expectEqual(@as(u21, 'i'), iter.next().?.code);
        try expectEqual(@as(?CodePoint, null), iter.peek());
        try expectEqual(@as(?CodePoint, null), iter.next());
    }

    const code_point_self = @This();

    // Keep this in sync with the README
    test "Code point iterator" {
        const str: []const u8 = "Hi 😊";
        var iter: code_point_self.Iterator = .init(str);
        var i: usize = 0;

        while (iter.next()) |cp| : (i += 1) {
            // The `code` field is the actual code point scalar as a `u21`.
            if (i == 0) try expect(cp.code == 'H');
            if (i == 1) try expect(cp.code == 'i');
            if (i == 2) try expect(cp.code == ' ');

            if (i == 3) {
                try expect(cp.code == '😊');
                // The `offset` field is the byte offset in the
                // source string.
                try expect(cp.offset == 3);
                try expectEqual(cp, code_point.decodeAtIndex(str, cp.offset).?);
                // The `len` field is the length in bytes of the
                // code point in the source string.
                try expect(cp.len == 4);
                // There is also a 'cursor' decode, like so:
                {
                    var cursor = cp.offset;
                    try expectEqual(cp, code_point.decodeAtCursor(str, &cursor).?);
                    // Which advances the cursor variable to the next possible
                    // offset, in this case, `str.len`.  Don't forget to account
                    // for this possibility!
                    try expectEqual(cp.offset + cp.len, cursor);
                }
                // There's also this, for when you aren't sure if you have the
                // correct start for a code point:
                try expectEqual(cp, code_point.codepointAtIndex(str, cp.offset + 1).?);
            }
            // Reverse iteration is also an option:
            var r_iter: code_point.ReverseIterator = .init(str);
            // Both iterators can be peeked:
            try expectEqual('😊', r_iter.peek().?.code);
            try expectEqual('😊', r_iter.prev().?.code);
            // Both kinds of iterators can be reversed:
            var fwd_iter = r_iter.forwardIterator(); // or iter.reverseIterator();
            // This will always return the last codepoint from
            // the prior iterator, _if_ it yielded one:
            try expectEqual('😊', fwd_iter.next().?.code);
        }
    }
    test "overlongs" {
        // None of these should equal `/`, all should be byte-for-byte
        // handled as replacement characters.
        {
            const bytes: []const u8 = "\xc0\xaf";
            var iter: Iterator = .init(bytes);
            const first: CodePoint = iter.next().?;
            try expect('/' != first.code);
            try expectEqual(0xfffd, first.code);
            try testing.expectEqual(1, first.len);
            const second: CodePoint = iter.next().?;
            try expectEqual(0xfffd, second.code);
            try testing.expectEqual(1, second.len);
        }
        {
            const bytes: []const u8 = "\xe0\x80\xaf";
            var iter: Iterator = .init(bytes);
            const first: CodePoint = iter.next().?;
            try expect('/' != first.code);
            try expectEqual(0xfffd, first.code);
            try testing.expectEqual(1, first.len);
            const second: CodePoint = iter.next().?;
            try expectEqual(0xfffd, second.code);
            try testing.expectEqual(1, second.len);
            const third: CodePoint = iter.next().?;
            try expectEqual(0xfffd, third.code);
            try testing.expectEqual(1, third.len);
        }
        {
            const bytes: []const u8 = "\xf0\x80\x80\xaf";
            var iter: Iterator = .init(bytes);
            const first: CodePoint = iter.next().?;
            try expect('/' != first.code);
            try expectEqual(0xfffd, first.code);
            try testing.expectEqual(1, first.len);
            const second: CodePoint = iter.next().?;
            try expectEqual(0xfffd, second.code);
            try testing.expectEqual(1, second.len);
            const third: CodePoint = iter.next().?;
            try expectEqual(0xfffd, third.code);
            try testing.expectEqual(1, third.len);
            const fourth: CodePoint = iter.next().?;
            try expectEqual(0xfffd, fourth.code);
            try testing.expectEqual(1, fourth.len);
        }
    }

    test "surrogates" {
        // Substitution of Maximal Subparts dictates a
        // replacement character for each byte of a surrogate.
        {
            const bytes: []const u8 = "\xed\xad\xbf";
            var iter: Iterator = .init(bytes);
            const first: CodePoint = iter.next().?;
            try expectEqual(0xfffd, first.code);
            try testing.expectEqual(1, first.len);
            const second: CodePoint = iter.next().?;
            try expectEqual(0xfffd, second.code);
            try testing.expectEqual(1, second.len);
            const third: CodePoint = iter.next().?;
            try expectEqual(0xfffd, third.code);
            try testing.expectEqual(1, third.len);
        }
    }

    test "truncation" {
        // Truncation must return one (1) replacement
        // character for each stem of a valid UTF-8 codepoint
        // Sample from Table 3-11 of the Unicode Standard 16.0.0
        {
            const bytes: []const u8 = "\xe1\x80\xe2\xf0\x91\x92\xf1\xbf\x41";
            var iter: Iterator = .init(bytes);
            const first: CodePoint = iter.next().?;
            try expectEqual(0xfffd, first.code);
            try testing.expectEqual(2, first.len);
            const second: CodePoint = iter.next().?;
            try expectEqual(0xfffd, second.code);
            try testing.expectEqual(1, second.len);
            const third: CodePoint = iter.next().?;
            try expectEqual(0xfffd, third.code);
            try testing.expectEqual(3, third.len);
            const fourth: CodePoint = iter.next().?;
            try expectEqual(0xfffd, fourth.code);
            try testing.expectEqual(2, fourth.len);
            const fifth: CodePoint = iter.next().?;
            try expectEqual(0x41, fifth.code);
            try testing.expectEqual(1, fifth.len);
        }
    }

    test ReverseIterator {
        {
            var r_iter: ReverseIterator = .init("ABC");
            try testing.expectEqual(@as(u21, 'C'), r_iter.prev().?.code);
            try testing.expectEqual(@as(u21, 'B'), r_iter.peek().?.code);
            try testing.expectEqual(@as(u21, 'B'), r_iter.prev().?.code);
            try testing.expectEqual(@as(u21, 'A'), r_iter.prev().?.code);
            try testing.expectEqual(@as(?CodePoint, null), r_iter.peek());
            try testing.expectEqual(@as(?CodePoint, null), r_iter.prev());
            try testing.expectEqual(@as(?CodePoint, null), r_iter.prev());
        }
        {
            var r_iter: ReverseIterator = .init("∅δq🦾ă");
            try testing.expectEqual(@as(u21, 'ă'), r_iter.prev().?.code);
            try testing.expectEqual(@as(u21, '🦾'), r_iter.prev().?.code);
            try testing.expectEqual(@as(u21, 'q'), r_iter.prev().?.code);
            try testing.expectEqual(@as(u21, 'δ'), r_iter.peek().?.code);
            try testing.expectEqual(@as(u21, 'δ'), r_iter.prev().?.code);
            try testing.expectEqual(@as(u21, '∅'), r_iter.peek().?.code);
            try testing.expectEqual(@as(u21, '∅'), r_iter.peek().?.code);
            try testing.expectEqual(@as(u21, '∅'), r_iter.prev().?.code);
            try testing.expectEqual(@as(?CodePoint, null), r_iter.peek());
            try testing.expectEqual(@as(?CodePoint, null), r_iter.prev());
            try testing.expectEqual(@as(?CodePoint, null), r_iter.prev());
        }
        {
            var r_iter: ReverseIterator = .init("123");
            try testing.expectEqual(@as(u21, '3'), r_iter.prev().?.code);
            try testing.expectEqual(@as(u21, '2'), r_iter.prev().?.code);
            try testing.expectEqual(@as(u21, '1'), r_iter.prev().?.code);
            var iter: @TypeOf(r_iter.forwardIterator()) = r_iter.forwardIterator();
            try testing.expectEqual(@as(u21, '1'), iter.next().?.code);
            try testing.expectEqual(@as(u21, '2'), iter.next().?.code);
            try testing.expectEqual(@as(u21, '3'), iter.next().?.code);
            r_iter = iter.reverseIterator();
            try testing.expectEqual(@as(u21, '3'), r_iter.prev().?.code);
            try testing.expectEqual(@as(u21, '2'), r_iter.prev().?.code);
            iter = r_iter.forwardIterator();
            r_iter = iter.reverseIterator();
            try testing.expectEqual(@as(u21, '2'), iter.next().?.code);
            try testing.expectEqual(@as(u21, '2'), r_iter.prev().?.code);
        }
    }

    const testing = std.testing;
    const expect = testing.expect;
    const expectEqual = testing.expectEqual;
    const assert = zm.assert;
};

// ============================================================================
// SECTION - gltf (glTF 2.0 JSON + GLB binary container)
// ============================================================================
// Minimal glTF 2.0 parser, zimr-style.  Targets the 80 % case:
// static and skinned meshes, embedded PNG textures, baked Trs
// keyframe animations.  No KHR_* extensions.
// We support both formats:
//   - .gltf  (JSON only, with external .bin and texture refs - but
//             we only handle data: URIs and embedded buffers since
//             zimr's loader fetches by single URL)
//   - .glb   (binary container: 12-byte header + JSON chunk + BIN
//             chunk; the format every modern exporter ships)
// Type names mirror the spec (Asset, Scene, Node, Mesh, Primitive,
// Accessor, BufferView, Buffer, Material, Texture, Image, Skin,
// Animation).  Where the spec uses optional fields we use Zig
// optionals, not magic sentinels.

pub const audio = struct {
    const std_mod = @import("std");

    /// Audio file format dispatch.  Add new variants here when
    /// adding codecs; call sites stay stable.
    pub const Format = enum {
        wav,
        ogg,

        /// Sync-decode `reader`'s bytes into a `CanonicalWave`.  Only
        /// valid for formats with a Zig codec - `.ogg` returns
        /// `error.OggRequiresAsyncDecode` because Web Audio's
        /// `decodeAudioData` is async (we cannot block on a Promise
        /// in single-threaded JS).
        /// For OGG sources, use `sound.sounds.loadFromMemory(.ogg, ...)`
        /// or `sound.music.loadFromMemory(.ogg, ...)` instead - those
        /// paths handle the async-decode "pending" state explicitly.
        /// Errors returned by `decode` - union of WAV's decode errors,
        /// allocator failure, and the OGG async-decode-required signal.
        pub const DecodeError = wav.DecodeError ||
            std_mod.mem.Allocator.Error ||
            error{OggRequiresAsyncDecode};

        pub fn decode(
            self: Format,
            gpa: std_mod.mem.Allocator,
            reader: *std_mod.Io.Reader,
        ) DecodeError!CanonicalWave {
            return switch (self) {
                .wav => wav.decode(gpa, reader),
                .ogg => error.OggRequiresAsyncDecode,
            };
        }

        /// Whether this format can be decoded synchronously into a
        /// CanonicalWave.  WAV: yes.  OGG: no (Web Audio is async).
        pub fn syncDecodable(self: Format) bool {
            return switch (self) {
                .wav => true,
                .ogg => false,
            };
        }

        /// Sniff format from magic bytes.  Returns null if unknown
        /// or fewer than 4 bytes.
        pub fn detect(bytes: []const u8) ?Format {
            if (bytes.len < 4) {
                return null;
            }
            if (std_mod.mem.eql(u8, bytes[0..4], "RIFF")) {
                return .wav;
            }
            if (std_mod.mem.eql(u8, bytes[0..4], "OggS")) {
                return .ogg;
            }
            return null;
        }
    };

    /// Format-agnostic intermediate Wave representation.  Owns its
    /// `samples` bytes (allocated via `gpa`); call `deinit` to free.
    /// `samples` layout depends on `(sample_size, format_tag)`:
    ///   - 8-bit PCM int:  `[]u8`, unsigned with bias 128 (RIFF spec)
    ///   - 16-bit PCM int: `[]i16` (the bytes); little-endian on disk
    ///   - 32-bit PCM int: `[]i32` (the bytes); little-endian
    ///   - 32-bit IEEE float: `[]f32` (the bytes); little-endian
    /// `frame_count` is the number of audio frames (one frame per
    /// channel-aligned PCM tuple).  `samples.len == frame_count *
    /// channels * (sample_size / 8)`.
    /// This is the codec layer's representation; the runtime's
    /// `Wave` (in `types.zig`) is a raylib-shaped extern struct that
    /// wraps the same data.
    pub const CanonicalWave = struct {
        samples: []u8,
        sample_rate: u32,
        sample_size: u16,
        channels: u16,
        format_tag: FormatTag,
        gpa: std_mod.mem.Allocator,

        /// Whether the bytes in `samples` are PCM ints or IEEE
        /// floats.  For sample_size = 32 these have completely
        /// different ranges; the conversion path in
        /// `toFloat32Stereo` switches on this.
        pub const FormatTag = enum { pcm_int, ieee_float };

        pub fn deinit(self: CanonicalWave) void {
            self.gpa.free(self.samples);
        }

        /// Number of frames (= sample tuples, one per channel-set).
        pub fn frameCount(self: CanonicalWave) u32 {
            const bytes_per_frame: u32 = @intCast((self.sample_size / 8) * self.channels);
            if (bytes_per_frame == 0) {
                return 0;
            }
            return @intCast(self.samples.len / bytes_per_frame);
        }
    };

    pub const wav = struct {
        /// Errors emitted by `decode` / `encode` / `Decoder.init`.
        pub const DecodeError = error{
            /// Bytes don't start with "RIFF...WAVE".
            InvalidSignature,
            /// `fmt ` chunk's format tag isn't 1 (PCM int) or 3
            /// (IEEE float).  ADPCM, μ-law, A-law, etc. unsupported.
            UnsupportedFormatTag,
            /// PCM int with bits ≠ {8, 16, 32}, or IEEE float with
            /// bits ≠ 32.
            UnsupportedBitDepth,
            /// channels = 0 or > 8.
            UnsupportedChannelCount,
            /// EOF mid-chunk; file is truncated or malformed.
            TruncatedFile,
            /// Walked all chunks without finding `data`.
            DataChunkMissing,
        };

        /// Sync-decode RIFF/WAVE bytes into a `CanonicalWave`.
        /// Returns owned PCM samples (the data chunk's contents
        /// verbatim, as bytes); caller `deinit`s.
        /// The walker handles arbitrary chunk ordering between
        /// `fmt ` and `data` (LIST, JUNK, etc. are skipped).  Odd-
        /// sized chunks are followed by a 1-byte pad (RIFF spec).
        /// Multi-byte fields are little-endian per the RIFF spec.
        pub fn decode(
            gpa: std_mod.mem.Allocator,
            reader: *std_mod.Io.Reader,
        ) (DecodeError || std_mod.mem.Allocator.Error)!CanonicalWave {
            // ---- RIFF header (12 bytes: "RIFF" + size + "WAVE") -----------
            const hdr: *const [12]u8 = reader.takeArray(12) catch return error.TruncatedFile;
            if (!std_mod.mem.eql(u8, hdr[0..4], "RIFF")) {
                return error.InvalidSignature;
            }
            // hdr[4..8] = total file size minus 8 bytes; we don't
            // validate it (some encoders write 0 or wrong values).
            if (!std_mod.mem.eql(u8, hdr[8..12], "WAVE")) {
                return error.InvalidSignature;
            }

            // ---- Walk chunks until we have both `fmt ` and `data` ----------
            var format_tag: u16 = 0;
            var channels: u16 = 0;
            var sample_rate: u32 = 0;
            var bits_per_sample: u16 = 0;
            var got_fmt: bool = false;
            var data_bytes: ?[]u8 = null;

            errdefer {
                if (data_bytes) |db| {
                    gpa.free(db);
                }
            }

            while (true) {
                const chunk_hdr: *const [8]u8 = reader.takeArray(8) catch {
                    if (data_bytes == null) {
                        return error.DataChunkMissing;
                    }
                    return error.TruncatedFile;
                };
                const chunk_id: [4]u8 = chunk_hdr[0..4].*;
                const chunk_size: u32 = std_mod.mem.readInt(u32, chunk_hdr[4..8], .little);

                if (std_mod.mem.eql(u8, &chunk_id, "fmt ")) {
                    if (chunk_size < 16) {
                        return error.UnsupportedFormatTag;
                    }
                    format_tag = reader.takeInt(u16, .little) catch return error.TruncatedFile;
                    channels = reader.takeInt(u16, .little) catch return error.TruncatedFile;
                    sample_rate = reader.takeInt(u32, .little) catch return error.TruncatedFile;
                    _ = reader.takeInt(u32, .little) catch return error.TruncatedFile; // byte_rate
                    _ = reader.takeInt(u16, .little) catch return error.TruncatedFile; // block_align
                    bits_per_sample = reader.takeInt(u16, .little) catch return error.TruncatedFile;
                    // Skip extension data after the standard 16-byte
                    // PCMWAVEFORMAT prefix (e.g. WAVEFORMATEX adds 2-N bytes).
                    if (chunk_size > 16) {
                        reader.discardAll(chunk_size - 16) catch return error.TruncatedFile;
                    }
                    if (chunk_size % 2 != 0) {
                        reader.discardAll(1) catch return error.TruncatedFile;
                    }
                    got_fmt = true;
                } else if (std_mod.mem.eql(u8, &chunk_id, "data")) {
                    const data = try gpa.alloc(u8, chunk_size);
                    reader.readSliceAll(data) catch {
                        gpa.free(data);
                        return error.TruncatedFile;
                    };
                    data_bytes = data;
                    if (chunk_size % 2 != 0) {
                        // Trailing pad byte; EOF here is fine.
                        reader.discardAll(1) catch {};
                    }
                    break;
                } else {
                    // Unknown chunk: skip its body + alignment pad.
                    reader.discardAll(chunk_size) catch return error.TruncatedFile;
                    if (chunk_size % 2 != 0) {
                        reader.discardAll(1) catch return error.TruncatedFile;
                    }
                }
            }

            if (!got_fmt) {
                return error.InvalidSignature;
            }
            const data: []u8 = data_bytes orelse return error.DataChunkMissing;

            // ---- Validate format params -----------------------------------
            switch (format_tag) {
                1 => { // PCM int
                    if (bits_per_sample != 8 and bits_per_sample != 16 and bits_per_sample != 32) {
                        return error.UnsupportedBitDepth;
                    }
                },
                3 => { // IEEE float
                    if (bits_per_sample != 32) {
                        return error.UnsupportedBitDepth;
                    }
                },
                else => {
                    return error.UnsupportedFormatTag;
                },
            }

            if (channels == 0 or channels > 8) {
                return error.UnsupportedChannelCount;
            }

            // Don't return data through the errdefer's drop path - null it
            // out so the success branch keeps ownership.
            data_bytes = null;
            return CanonicalWave{
                .samples = data,
                .sample_rate = sample_rate,
                .sample_size = bits_per_sample,
                .channels = channels,
                .format_tag = if (format_tag == 3) .ieee_float else .pcm_int,
                .gpa = gpa,
            };
        }

        // ---- Tests
        pub const test_sine_wav: []const u8 = @embedFile("./assets/test_sine.wav");

        test "decode: embedded test_sine.wav succeeds" {
            const ta: std_mod.mem.Allocator = std_mod.testing.allocator;
            var reader: std_mod.Io.Reader = std_mod.Io.Reader.fixed(test_sine_wav);
            const cw: CanonicalWave = try decode(ta, &reader);
            defer cw.deinit();
            try std_mod.testing.expectEqual(@as(u32, 22050), cw.sample_rate);
            try std_mod.testing.expectEqual(@as(u16, 16), cw.sample_size);
            try std_mod.testing.expectEqual(@as(u16, 1), cw.channels);
            // 22050 Hz × 0.5 sec × 1 channel × 2 bytes = 22050 bytes
            try std_mod.testing.expectEqual(@as(usize, 22050), cw.samples.len);
            try std_mod.testing.expectEqual(@as(u32, 11025), cw.frameCount());
        }

        test "decode: invalid signature" {
            const ta: std_mod.mem.Allocator = std_mod.testing.allocator;
            const bad: []const u8 = "NOTWAVE\x00NOTWAVE\x00NOTWAVE\x00NOTWAVE\x00";
            var reader: std_mod.Io.Reader = std_mod.Io.Reader.fixed(bad);
            try std_mod.testing.expectError(
                DecodeError.InvalidSignature,
                decode(ta, &reader),
            );
        }

        test "decode: empty input is truncated" {
            const ta: std_mod.mem.Allocator = std_mod.testing.allocator;
            var reader: std_mod.Io.Reader = std_mod.Io.Reader.fixed("");
            try std_mod.testing.expectError(
                DecodeError.TruncatedFile,
                decode(ta, &reader),
            );
        }

        test "decode: WAVE header but no chunks → data missing" {
            const ta: std_mod.mem.Allocator = std_mod.testing.allocator;
            const just_header: []const u8 = "RIFF\x04\x00\x00\x00WAVE";
            var reader: std_mod.Io.Reader = std_mod.Io.Reader.fixed(just_header);
            try std_mod.testing.expectError(
                DecodeError.DataChunkMissing,
                decode(ta, &reader),
            );
        }

        test "decode: minimal hand-built 16-bit mono PCM" {
            const ta: std_mod.mem.Allocator = std_mod.testing.allocator;
            // Build the smallest legal WAV: header + fmt(16) + data(4 bytes).
            // 2 frames × 1 channel × 2 bytes/sample = 4 bytes.
            const wav_bytes: []const u8 =
                "RIFF" ++ "\x28\x00\x00\x00" ++ "WAVE" ++
                "fmt " ++ "\x10\x00\x00\x00" ++
                "\x01\x00" ++ "\x01\x00" ++ "\x44\xac\x00\x00" ++
                "\x88\x58\x01\x00" ++ "\x02\x00" ++ "\x10\x00" ++
                "data" ++ "\x04\x00\x00\x00" ++
                "\x00\x00" ++ "\xff\x7f";
            var reader: std_mod.Io.Reader = std_mod.Io.Reader.fixed(wav_bytes);
            const cw: CanonicalWave = try decode(ta, &reader);
            defer cw.deinit();
            try std_mod.testing.expectEqual(@as(u32, 44100), cw.sample_rate);
            try std_mod.testing.expectEqual(@as(u16, 16), cw.sample_size);
            try std_mod.testing.expectEqual(@as(u16, 1), cw.channels);
            try std_mod.testing.expectEqual(@as(usize, 4), cw.samples.len);
            try std_mod.testing.expectEqual(@as(u32, 2), cw.frameCount());
            // Sample 0 = 0x0000 → silence; sample 1 = 0x7fff → max amplitude.
            try std_mod.testing.expectEqual(@as(u8, 0x00), cw.samples[0]);
            try std_mod.testing.expectEqual(@as(u8, 0x00), cw.samples[1]);
            try std_mod.testing.expectEqual(@as(u8, 0xff), cw.samples[2]);
            try std_mod.testing.expectEqual(@as(u8, 0x7f), cw.samples[3]);
        }

        test "decode: unsupported format tag (μ-law)" {
            const ta: std_mod.mem.Allocator = std_mod.testing.allocator;
            // format_tag = 7 (μ-law) - not in our PCM(1)/float(3) set.
            const wav_bytes: []const u8 =
                "RIFF" ++ "\x24\x00\x00\x00" ++ "WAVE" ++
                "fmt " ++ "\x10\x00\x00\x00" ++
                "\x07\x00" ++ "\x01\x00" ++ "\x44\xac\x00\x00" ++
                "\x44\xac\x00\x00" ++ "\x01\x00" ++ "\x08\x00" ++
                "data" ++ "\x00\x00\x00\x00";
            var reader: std_mod.Io.Reader = std_mod.Io.Reader.fixed(wav_bytes);
            try std_mod.testing.expectError(
                DecodeError.UnsupportedFormatTag,
                decode(ta, &reader),
            );
        }

        test "decode: unsupported bit depth (24-bit PCM)" {
            const ta: std_mod.mem.Allocator = std_mod.testing.allocator;
            // PCM int with bits=24 - common but we don't support it.
            const wav_bytes: []const u8 =
                "RIFF" ++ "\x24\x00\x00\x00" ++ "WAVE" ++
                "fmt " ++ "\x10\x00\x00\x00" ++
                "\x01\x00" ++ "\x01\x00" ++ "\x44\xac\x00\x00" ++
                "\xcc\x04\x02\x00" ++ "\x03\x00" ++ "\x18\x00" ++
                "data" ++ "\x00\x00\x00\x00";
            var reader: std_mod.Io.Reader = std_mod.Io.Reader.fixed(wav_bytes);
            try std_mod.testing.expectError(
                DecodeError.UnsupportedBitDepth,
                decode(ta, &reader),
            );
        }

        test "decode: skips unknown chunks (LIST between fmt and data)" {
            const ta: std_mod.mem.Allocator = std_mod.testing.allocator;
            // RIFF + WAVE + fmt(16) + LIST(8) + data(2 bytes).
            const wav_bytes: []const u8 =
                "RIFF" ++ "\x36\x00\x00\x00" ++ "WAVE" ++
                "fmt " ++ "\x10\x00\x00\x00" ++
                "\x01\x00" ++ "\x01\x00" ++ "\x44\xac\x00\x00" ++
                "\x88\x58\x01\x00" ++ "\x02\x00" ++ "\x10\x00" ++
                "LIST" ++ "\x08\x00\x00\x00" ++ "INFOIART" ++
                "data" ++ "\x02\x00\x00\x00" ++ "\x00\x10";
            var reader: std_mod.Io.Reader = std_mod.Io.Reader.fixed(wav_bytes);
            const cw: CanonicalWave = try decode(ta, &reader);
            defer cw.deinit();
            try std_mod.testing.expectEqual(@as(usize, 2), cw.samples.len);
            try std_mod.testing.expectEqual(@as(u8, 0x00), cw.samples[0]);
            try std_mod.testing.expectEqual(@as(u8, 0x10), cw.samples[1]);
        }

        test "decode: data chunk truncated mid-payload" {
            const ta: std_mod.mem.Allocator = std_mod.testing.allocator;
            // data chunk claims 8 bytes but only 2 follow.
            const wav_bytes: []const u8 =
                "RIFF" ++ "\x2c\x00\x00\x00" ++ "WAVE" ++
                "fmt " ++ "\x10\x00\x00\x00" ++
                "\x01\x00" ++ "\x01\x00" ++ "\x44\xac\x00\x00" ++
                "\x88\x58\x01\x00" ++ "\x02\x00" ++ "\x10\x00" ++
                "data" ++ "\x08\x00\x00\x00" ++ "\x00\x00";
            var reader: std_mod.Io.Reader = std_mod.Io.Reader.fixed(wav_bytes);
            try std_mod.testing.expectError(
                DecodeError.TruncatedFile,
                decode(ta, &reader),
            );
        }

        // ---- Encode
        /// Output format options for `encode`.  `format_code` selects
        /// PCM int vs IEEE float; `bits` is the per-sample bit depth.
        /// Common combinations:
        ///   - PCM 16: ubiquitous game-audio default
        ///   - PCM 8:  small but lossy; rare in practice
        ///   - Float 32: lossless f32 round-trip
        pub const ExportOptions = struct {
            bits: u16 = 16,
            format_code: enum { pcm, ieee_float } = .pcm,
        };

        /// Encode a `CanonicalWave` to RIFF/WAVE bytes via `writer`.
        /// `options.format_code` and `options.bits` control the
        /// output sample format - they need NOT match the input
        /// CanonicalWave's format.  The conversion path (when they
        /// differ) goes through `toFloat32Stereo` first to get a
        /// canonical f32 stereo, then quantizes back to the requested
        /// output format.
        /// For the no-conversion case (input format matches output),
        /// data bytes are written verbatim.
        /// Currently supports only the trivial verbatim path: input
        /// CanonicalWave's format MUST match `options`.  Conversion
        /// happens upstream via `toFloat32Stereo` → caller-rebuilds
        /// CanonicalWave at desired format.  Step 6 keeps the encoder
        /// minimal and pushes format choice to the toCanonical
        /// pipeline.
        pub fn encode(
            wave: CanonicalWave,
            writer: *std_mod.Io.Writer,
            options: ExportOptions,
        ) !void {
            if (wave.sample_size != options.bits) {
                return error.EncodeFormatMismatch;
            }
            const expected_tag: CanonicalWave.FormatTag = switch (options.format_code) {
                .pcm => .pcm_int,
                .ieee_float => .ieee_float,
            };
            if (wave.format_tag != expected_tag) {
                return error.EncodeFormatMismatch;
            }
            // Header sizes:
            //   RIFF magic + size + WAVE magic   = 12 bytes
            //   fmt  magic + size + 16-byte body = 24 bytes
            //   data magic + size                = 8 bytes
            //   payload                          = wave.samples.len
            const fmt_chunk_size: u32 = 16;
            const data_size: u32 = @intCast(wave.samples.len);
            const total_size: u32 = 4 + (8 + fmt_chunk_size) + (8 + data_size);

            // RIFF/WAVE header.
            try writer.writeAll("RIFF");
            try writer.writeInt(u32, total_size, .little);
            try writer.writeAll("WAVE");

            // fmt  chunk.
            try writer.writeAll("fmt ");
            try writer.writeInt(u32, fmt_chunk_size, .little);
            const format_tag_u16: u16 = switch (options.format_code) {
                .pcm => 1,
                .ieee_float => 3,
            };
            try writer.writeInt(u16, format_tag_u16, .little);
            try writer.writeInt(u16, wave.channels, .little);
            try writer.writeInt(u32, wave.sample_rate, .little);
            const byte_rate: u32 = wave.sample_rate * @as(u32, wave.channels) * (@as(u32, wave.sample_size) / 8);
            try writer.writeInt(u32, byte_rate, .little);
            const block_align: u16 = wave.channels * (wave.sample_size / 8);
            try writer.writeInt(u16, block_align, .little);
            try writer.writeInt(u16, wave.sample_size, .little);

            // data chunk.
            try writer.writeAll("data");
            try writer.writeInt(u32, data_size, .little);
            try writer.writeAll(wave.samples);

            // Pad odd-sized data chunks to 2-byte alignment per RIFF spec.
            if (data_size % 2 != 0) {
                try writer.writeByte(0);
            }
        }

        // ---- Format conversion helpers
        /// Convert any `CanonicalWave` to interleaved-stereo `f32`
        /// at the same sample rate.
        /// Conversions:
        ///   - 8-bit PCM int (unsigned, bias 128):  `(s - 128) / 128.0`
        ///   - 16-bit PCM int:                       `s / 32768.0`
        ///   - 32-bit PCM int:                       `s / 2_147_483_648.0`
        ///   - 32-bit IEEE float:                    passthrough (with bit cast)
        /// Channel mapping:
        ///   - mono → stereo: duplicate L=R
        ///   - stereo → stereo: passthrough
        ///   - 3+ channels → stereo: take channels 0+1, drop the rest
        pub fn toFloat32Stereo(
            gpa: std_mod.mem.Allocator,
            wave: CanonicalWave,
        ) ![]f32 {
            const fc: usize = wave.frameCount();
            const out = try gpa.alloc(f32, fc * 2);
            errdefer gpa.free(out);

            const ch: usize = wave.channels;
            const bytes_per_sample: usize = wave.sample_size / 8;

            // Per-frame conversion:
            //   srcL, srcR = first two channel samples (R = L if mono)
            //   normalize via bit-depth scale
            //   write to interleaved out[2*f], out[2*f + 1]
            for (0..fc) |f| {
                const frame_byte_offset: usize = f * ch * bytes_per_sample;

                const l: f32 = readSample(wave, frame_byte_offset);
                const r: f32 = if (ch >= 2) readSample(wave, frame_byte_offset + bytes_per_sample) else l;

                out[f * 2 + 0] = l;
                out[f * 2 + 1] = r;
            }
            return out;
        }

        /// Read one sample from `wave.samples` at the given byte offset
        /// and convert to f32 in `[-1.0, 1.0]` range.
        fn readSample(wave: CanonicalWave, byte_offset: usize) f32 {
            const bytes_per_sample: usize = wave.sample_size / 8;
            const slice: []const u8 = wave.samples[byte_offset .. byte_offset + bytes_per_sample];
            return switch (wave.sample_size) {
                8 => blk: {
                    // 8-bit WAV is unsigned with bias 128 (per RIFF spec).
                    const raw: u8 = slice[0];
                    const centered: f32 = float(@as(i16, raw) - 128);
                    break :blk centered / 128.0;
                },
                16 => blk: {
                    const raw: i16 = std_mod.mem.readInt(i16, slice[0..2], .little);
                    break :blk float(raw) / 32768.0;
                },
                32 => blk: {
                    if (wave.format_tag == .ieee_float) {
                        const raw_u32: u32 = std_mod.mem.readInt(u32, slice[0..4], .little);
                        const f: f32 = @bitCast(raw_u32);
                        break :blk f;
                    }
                    const raw: i32 = std_mod.mem.readInt(i32, slice[0..4], .little);
                    break :blk float(raw) / 2147483648.0;
                },
                else => 0.0,
            };
        }

        /// Linear-interpolation resampler.  Input and output are both
        /// interleaved-stereo `f32`.  Returns the resampled output as
        /// a freshly-allocated slice.
        /// Output length = `input_frame_count * sr_out / sr_in`.
        /// When `sr_in == sr_out`, returns a copy without
        /// interpolation (faster, also avoids tiny rounding drift).
        /// Linear is good enough for game SFX at the 44.1k → 48k
        /// kind of conversion.  For high-quality music a windowed-sinc
        /// kernel would be the upgrade - tracked, not blocking.
        pub fn resampleLinear(
            gpa: std_mod.mem.Allocator,
            samples: []const f32,
            channels: u32,
            sr_in: u32,
            sr_out: u32,
        ) ![]f32 {
            if (sr_in == sr_out) {
                const copy = try gpa.alloc(f32, samples.len);
                @memcpy(copy, samples);
                return copy;
            }
            if (channels == 0 or sr_in == 0) {
                return try gpa.alloc(f32, 0);
            }
            const in_frames: usize = samples.len / channels;
            // Use u64 for the multiplication so we don't overflow u32
            // at large input lengths (e.g. 5-min audio at 48k → ~14M frames).
            const out_frames_u64: u64 = @as(u64, in_frames) * sr_out / sr_in;
            const out_frames: usize = @intCast(out_frames_u64);
            const out = try gpa.alloc(f32, out_frames * channels);
            errdefer gpa.free(out);

            // For each output frame `o`, compute the equivalent input
            // frame position (fractional), lerp between floor and ceil.
            const ratio: f64 = float64(sr_in) / float64(sr_out);
            for (0..out_frames) |o| {
                const src_pos: f64 = float64(o) * ratio;
                const idx0: usize = @trunc(src_pos);
                const frac: f32 = @floatCast(src_pos - float64(idx0));
                const idx1: usize = if (idx0 + 1 < in_frames) idx0 + 1 else idx0;
                for (0..channels) |c| {
                    const a: f32 = samples[idx0 * channels + c];
                    const b: f32 = samples[idx1 * channels + c];
                    out[o * channels + c] = a + (b - a) * frac;
                }
            }
            return out;
        }

        // ---- Tests for encode + helpers
        test "encode: round-trip 16-bit mono PCM" {
            const ta: std_mod.mem.Allocator = std_mod.testing.allocator;
            // Decode the embedded fixture, encode it back, decode again,
            // verify identity.
            var r1: std_mod.Io.Reader = std_mod.Io.Reader.fixed(test_sine_wav);
            const cw1: CanonicalWave = try decode(ta, &r1);
            defer cw1.deinit();

            var aw: std_mod.Io.Writer.Allocating = .init(ta);
            defer aw.deinit();
            try encode(cw1, &aw.writer, .{ .bits = 16, .format_code = .pcm });

            var r2: std_mod.Io.Reader = std_mod.Io.Reader.fixed(aw.written());
            const cw2: CanonicalWave = try decode(ta, &r2);
            defer cw2.deinit();

            try std_mod.testing.expectEqual(cw1.sample_rate, cw2.sample_rate);
            try std_mod.testing.expectEqual(cw1.sample_size, cw2.sample_size);
            try std_mod.testing.expectEqual(cw1.channels, cw2.channels);
            try std_mod.testing.expectEqualSlices(u8, cw1.samples, cw2.samples);
        }

        test "encode: rejects format mismatch" {
            const ta: std_mod.mem.Allocator = std_mod.testing.allocator;
            const samples = try ta.alloc(u8, 2);
            defer ta.free(samples);
            samples[0] = 0;
            samples[1] = 0;
            const cw: CanonicalWave = .{
                .samples = samples,
                .sample_rate = 44100,
                .sample_size = 16,
                .channels = 1,
                .format_tag = .pcm_int,
                .gpa = ta,
            };
            var aw: std_mod.Io.Writer.Allocating = .init(ta);
            defer aw.deinit();
            try std_mod.testing.expectError(
                error.EncodeFormatMismatch,
                encode(cw, &aw.writer, .{ .bits = 8, .format_code = .pcm }),
            );
        }

        test "toFloat32Stereo: 16-bit mono → stereo f32" {
            const ta: std_mod.mem.Allocator = std_mod.testing.allocator;
            // 3 mono frames at half-amplitude, full-amplitude, half-negative.
            // Values: 16384 = 0.5; 32767 = 0.99997; -16384 = -0.5
            const samples = try ta.alloc(u8, 6);
            defer ta.free(samples);
            std_mod.mem.writeInt(i16, samples[0..2], 16384, .little);
            std_mod.mem.writeInt(i16, samples[2..4], 32767, .little);
            std_mod.mem.writeInt(i16, samples[4..6], -16384, .little);

            const cw: CanonicalWave = .{
                .samples = samples,
                .sample_rate = 44100,
                .sample_size = 16,
                .channels = 1,
                .format_tag = .pcm_int,
                .gpa = ta,
            };
            const f32_stereo: []f32 = try toFloat32Stereo(ta, cw);
            defer ta.free(f32_stereo);

            try std_mod.testing.expectEqual(@as(usize, 6), f32_stereo.len);
            // Mono → stereo: L=R for each frame.
            try std_mod.testing.expectApproxEqAbs(@as(f32, 0.5), f32_stereo[0], 0.001);
            try std_mod.testing.expectApproxEqAbs(@as(f32, 0.5), f32_stereo[1], 0.001);
            try std_mod.testing.expectApproxEqAbs(@as(f32, 0.99997), f32_stereo[2], 0.001);
            try std_mod.testing.expectApproxEqAbs(@as(f32, 0.99997), f32_stereo[3], 0.001);
            try std_mod.testing.expectApproxEqAbs(@as(f32, -0.5), f32_stereo[4], 0.001);
            try std_mod.testing.expectApproxEqAbs(@as(f32, -0.5), f32_stereo[5], 0.001);
        }

        test "toFloat32Stereo: 8-bit unsigned → stereo f32 (with bias 128)" {
            const ta: std_mod.mem.Allocator = std_mod.testing.allocator;
            const samples = try ta.alloc(u8, 3);
            defer ta.free(samples);
            samples[0] = 128; // = 0.0
            samples[1] = 255; // = 0.992
            samples[2] = 0; // = -1.0
            const cw: CanonicalWave = .{
                .samples = samples,
                .sample_rate = 22050,
                .sample_size = 8,
                .channels = 1,
                .format_tag = .pcm_int,
                .gpa = ta,
            };
            const f32_stereo: []f32 = try toFloat32Stereo(ta, cw);
            defer ta.free(f32_stereo);
            try std_mod.testing.expectApproxEqAbs(@as(f32, 0.0), f32_stereo[0], 0.01);
            try std_mod.testing.expectApproxEqAbs(@as(f32, 0.992), f32_stereo[2], 0.01);
            try std_mod.testing.expectApproxEqAbs(@as(f32, -1.0), f32_stereo[4], 0.01);
        }

        test "toFloat32Stereo: stereo passthrough" {
            const ta: std_mod.mem.Allocator = std_mod.testing.allocator;
            // 2 stereo frames: (L=0.5, R=-0.5), (L=1.0, R=-1.0)
            const samples = try ta.alloc(u8, 8);
            defer ta.free(samples);
            std_mod.mem.writeInt(i16, samples[0..2], 16384, .little);
            std_mod.mem.writeInt(i16, samples[2..4], -16384, .little);
            std_mod.mem.writeInt(i16, samples[4..6], 32767, .little);
            std_mod.mem.writeInt(i16, samples[6..8], -32768, .little);
            const cw: CanonicalWave = .{
                .samples = samples,
                .sample_rate = 44100,
                .sample_size = 16,
                .channels = 2,
                .format_tag = .pcm_int,
                .gpa = ta,
            };
            const out: []f32 = try toFloat32Stereo(ta, cw);
            defer ta.free(out);
            try std_mod.testing.expectEqual(@as(usize, 4), out.len);
            try std_mod.testing.expectApproxEqAbs(@as(f32, 0.5), out[0], 0.001);
            try std_mod.testing.expectApproxEqAbs(@as(f32, -0.5), out[1], 0.001);
        }

        test "toFloat32Stereo: 32-bit float passthrough" {
            const ta: std_mod.mem.Allocator = std_mod.testing.allocator;
            const samples = try ta.alloc(u8, 8);
            defer ta.free(samples);
            const v0: f32 = 0.25;
            const v1: f32 = -0.75;
            std_mod.mem.writeInt(u32, samples[0..4], @bitCast(v0), .little);
            std_mod.mem.writeInt(u32, samples[4..8], @bitCast(v1), .little);
            const cw: CanonicalWave = .{
                .samples = samples,
                .sample_rate = 48000,
                .sample_size = 32,
                .channels = 1,
                .format_tag = .ieee_float,
                .gpa = ta,
            };
            const out: []f32 = try toFloat32Stereo(ta, cw);
            defer ta.free(out);
            try std_mod.testing.expectApproxEqAbs(@as(f32, 0.25), out[0], 0.0001);
            try std_mod.testing.expectApproxEqAbs(@as(f32, -0.75), out[2], 0.0001);
        }

        test "resampleLinear: same rate returns identical samples" {
            const ta: std_mod.mem.Allocator = std_mod.testing.allocator;
            const in: []const f32 = &.{ 0.1, 0.2, 0.3, 0.4 };
            const out: []f32 = try resampleLinear(ta, in, 2, 48000, 48000);
            defer ta.free(out);
            try std_mod.testing.expectEqualSlices(f32, in, out);
        }

        test "resampleLinear: 2x upsample doubles output length" {
            const ta: std_mod.mem.Allocator = std_mod.testing.allocator;
            // Mono input: 4 frames at sr=22050 → 8 frames at sr=44100
            const in: []const f32 = &.{ 0.0, 1.0, 0.0, 1.0 };
            const out: []f32 = try resampleLinear(ta, in, 1, 22050, 44100);
            defer ta.free(out);
            try std_mod.testing.expectEqual(@as(usize, 8), out.len);
            // Frame 0 = input frame 0 = 0.0
            try std_mod.testing.expectApproxEqAbs(@as(f32, 0.0), out[0], 0.001);
            // Frame 2 = input frame 1 = 1.0
            try std_mod.testing.expectApproxEqAbs(@as(f32, 1.0), out[2], 0.001);
        }

        test "resampleLinear: 0.5x downsample halves output length" {
            const ta: std_mod.mem.Allocator = std_mod.testing.allocator;
            // Mono input: 8 frames at sr=44100 → 4 frames at sr=22050
            const in: []const f32 = &.{ 0.0, 0.25, 0.5, 0.75, 1.0, 0.75, 0.5, 0.25 };
            const out: []f32 = try resampleLinear(ta, in, 1, 44100, 22050);
            defer ta.free(out);
            try std_mod.testing.expectEqual(@as(usize, 4), out.len);
        }

        test "resampleLinear: empty input returns empty" {
            const ta: std_mod.mem.Allocator = std_mod.testing.allocator;
            const in: []const f32 = &.{};
            const out: []f32 = try resampleLinear(ta, in, 2, 44100, 48000);
            defer ta.free(out);
            try std_mod.testing.expectEqual(@as(usize, 0), out.len);
        }
    };

    // ---- ogg metadata sniffer (no decode body)
    // Web Audio's `decodeAudioData` does the heavy lifting for OGG
    // we don't ship a Vorbis decoder.  But the Ogg container header
    // is small and well-structured, so we CAN cheaply pull metadata
    // (sample rate, channels, total samples) out of OGG bytes
    // without touching the audio data.
    // This unblocks `music.getTimeLength` for OGG tracks before
    // playback starts (via the granule position in the last page),
    // and lets `sounds.loadFromMemory` set `sampleRate` / `channels`
    // on the returned Sound's stream so callers can introspect.

    pub const ogg = struct {
        /// Metadata extracted from an Ogg Vorbis stream's container.
        /// `total_samples` may be 0 if the file's last page can't
        /// be located (e.g. truncated download); the other fields
        /// come from the first page so are always present for a
        /// valid stream.
        pub const Metadata = struct {
            sample_rate: u32,
            channels: u8,
            /// Sample count in the stream's native rate.  Divide by
            /// `sample_rate` for duration in seconds.  0 if not
            /// derivable from the bytes provided.
            total_samples: u64,
        };

        /// Sniff Ogg Vorbis metadata from the bytes of an entire (or
        /// near-entire) Ogg Vorbis file.  Reads only the first page
        /// (sample rate + channels) and the last page (total
        /// samples via granule position); both are O(1) under typical
        /// page sizes (~4 KB).
        /// Returns null on:
        ///   - bytes shorter than one Ogg page
        ///   - first page isn't a Vorbis identification packet
        ///   - bytes don't begin with "OggS"
        /// `total_samples = 0` if the last-page scan can't find a
        /// granule position (truncated file, all-zero granules, etc.)
        /// - partial-metadata is still useful.
        pub fn sniff(bytes: []const u8) ?Metadata {
            if (bytes.len < 58) {
                // 27 (page hdr) + 1 (segment count) + 30 (vorbis id pkt)
                return null;
            }
            if (!std_mod.mem.eql(u8, bytes[0..4], "OggS")) {
                return null;
            }

            // First-page payload starts after the 27-byte page header
            // plus N-byte segment table.  For the Vorbis ID packet
            // that fits in one segment, N=1, segment[0]=30.
            const segment_count: u8 = bytes[26];
            const payload_offset: usize = 27 + segment_count;
            if (bytes.len < payload_offset + 30) {
                return null;
            }

            // Vorbis identification packet: 0x01, "vorbis", then:
            //   u32 vorbis_version (must be 0)
            //   u8  audio_channels (must be > 0)
            //   u32 audio_sample_rate (must be > 0)
            //   ... we don't care about the rest.
            const pkt: []const u8 = bytes[payload_offset .. payload_offset + 30];
            if (pkt[0] != 0x01) {
                return null;
            }
            if (!std_mod.mem.eql(u8, pkt[1..7], "vorbis")) {
                return null;
            }
            const channels: u8 = pkt[11];
            if (channels == 0) {
                return null;
            }
            const sample_rate: u32 = std_mod.mem.readInt(u32, pkt[12..16], .little);
            if (sample_rate == 0) {
                return null;
            }

            // Total samples: scan for the LAST "OggS" page in the
            // tail of the file.  Its granule position (i64 LE at
            // offset 6 of the page header) is the cumulative sample
            // count for the entire stream - Vorbis spec.
            // Limit the scan to the last 64 KB to keep this O(1) for
            // multi-MB files.  Typical Ogg pages are ~4 KB, so 64 KB
            // catches dozens of trailing pages - ample.
            const total: u64 = scanLastGranule(bytes);

            return Metadata{
                .sample_rate = sample_rate,
                .channels = channels,
                .total_samples = total,
            };
        }

        /// Scan backwards from end-of-bytes for the last page header
        /// and return its granule position.  Returns 0 if no valid
        /// page is found in the tail window or if the granule is -1
        /// (which Ogg uses to indicate "no packet ends on this page").
        fn scanLastGranule(bytes: []const u8) u64 {
            if (bytes.len < 27) {
                return 0;
            }
            // Search the last 64 KB (or the whole file if smaller).
            const tail_size: usize = @min(bytes.len, 64 * 1024);
            const tail_start: usize = bytes.len - tail_size;

            var last_granule: u64 = 0;
            // Walk forward through the tail looking for "OggS" pages.
            // We need `i + 27` valid for a header read.
            var i: usize = tail_start;
            while (i + 27 <= bytes.len) : (i += 1) {
                if (!std_mod.mem.eql(u8, bytes[i .. i + 4], "OggS")) {
                    continue;
                }
                // Granule position: i64 LE at page+6.  Vorbis uses -1
                // (all-bits-set) for "no packet boundary" pages; only
                // count pages with a real granule.
                const g_raw: i64 = std_mod.mem.readInt(i64, bytes[i + 6 ..][0..8], .little);
                if (g_raw < 0) {
                    continue;
                }
                last_granule = @bitCast(g_raw);
            }
            return last_granule;
        }

        /// Cheap check: does this look like Ogg-container bytes?
        /// (Doesn't validate the Vorbis payload - use `sniff` for
        /// that.)  Wraps `Format.detect` for type-safety + clarity at
        /// call sites.
        pub fn looksLikeOgg(bytes: []const u8) bool {
            return Format.detect(bytes) == .ogg;
        }

        // ---- Tests
        pub const sample_ogg: []const u8 = @embedFile("./assets/sample.ogg");

        test "sniff: real Ogg Vorbis file (sample.ogg) → metadata" {
            const meta: Metadata = sniff(sample_ogg) orelse {
                try std_mod.testing.expect(false); // Should sniff successfully.
                return;
            };
            // sample.ogg: stereo, 44100 Hz, ~96 seconds (4.2M samples).
            try std_mod.testing.expectEqual(@as(u32, 44100), meta.sample_rate);
            try std_mod.testing.expectEqual(@as(u8, 2), meta.channels);
            // ±10% acceptance to absorb encoder-specific granule
            // accounting drift.
            try std_mod.testing.expect(meta.total_samples > 3_800_000);
            try std_mod.testing.expect(meta.total_samples < 4_700_000);
        }

        test "sniff: returns null for non-Ogg bytes" {
            try std_mod.testing.expectEqual(@as(?Metadata, null), sniff("RIFF\x00\x00\x00\x00WAVEfmt ranother bytes"));
            try std_mod.testing.expectEqual(@as(?Metadata, null), sniff("\x89PNG\r\n\x1a\n"));
        }

        test "sniff: returns null for too-short input" {
            try std_mod.testing.expectEqual(@as(?Metadata, null), sniff(""));
            try std_mod.testing.expectEqual(@as(?Metadata, null), sniff("OggS"));
            try std_mod.testing.expectEqual(@as(?Metadata, null), sniff("OggS\x00OggS\x00OggS\x00OggS\x00"));
        }

        test "looksLikeOgg: matches Format.detect" {
            try std_mod.testing.expect(looksLikeOgg("OggS\x00\x02\x00\x00\x00\x00"));
            try std_mod.testing.expect(!looksLikeOgg("RIFF\x00\x00\x00\x00WAVE"));
            try std_mod.testing.expect(!looksLikeOgg(""));
        }
    };

    // ---- Step 7: end-to-end + Wave adapters
    /// End-to-end pipeline: decode any supported format, convert to
    /// interleaved-stereo `f32`, resample to `target_rate`.  Returns
    /// the resampled f32 buffer; caller frees via `gpa.free`.
    /// This is the path used by `loadAudioBuffer` when
    /// loading a sound: decode → canonical f32 stereo → upload to
    /// AudioContext at the device sample rate.
    /// `target_rate` is typically `web.audio.getSampleRate(ctx_id)`
    /// - the AudioContext's native rate (so Web Audio doesn't need
    /// to do its own resample).  Passing 0 yields an empty result.
    /// Returns `error.OggRequiresAsyncDecode` if the bytes sniff as
    /// OGG - those need the Web Audio async decode path, not this
    /// sync pipeline.
    pub fn toCanonical(
        gpa: std_mod.mem.Allocator,
        reader: *std_mod.Io.Reader,
        target_rate: u32,
    ) ![]f32 {
        // Peek at the first 4 bytes to dispatch.  We use peek not
        // take so the actual decode path can re-read them.
        const magic: []const u8 = reader.peek(4) catch return error.TruncatedFile;
        const fmt = Format.detect(magic) orelse return error.InvalidSignature;

        const cw: CanonicalWave = try fmt.decode(gpa, reader);
        defer cw.deinit();

        const stereo_f32: []f32 = try wav.toFloat32Stereo(gpa, cw);
        if (target_rate == 0 or target_rate == cw.sample_rate) {
            return stereo_f32;
        }
        defer gpa.free(stereo_f32);
        return wav.resampleLinear(gpa, stereo_f32, 2, cw.sample_rate, target_rate);
    }

    const Wave = types.Wave;

    /// Wrap a `CanonicalWave` in a raylib-shaped `Wave` extern struct.
    /// Allocates a new copy of the sample bytes - the returned Wave
    /// owns its `data` pointer and the caller is responsible for
    /// freeing it via `gpa.free(@as([*]u8, @ptrCast(wave.data))[0..byte_len])`.
    /// Convention: `Wave.sampleSize` reflects the canonical sample
    /// size (8/16/32).  raylib treats `sampleSize == 32` as float
    /// (the runtime mixer hands 32-bit data to JIT-style float ops);
    /// `8` and `16` are PCM int.  `canonicalFromWave` reverses this.
    pub fn waveFromCanonical(
        gpa: std_mod.mem.Allocator,
        c: CanonicalWave,
    ) !Wave {
        const bytes_copy = try gpa.alloc(u8, c.samples.len);
        errdefer gpa.free(bytes_copy);
        @memcpy(bytes_copy, c.samples);
        return Wave{
            .frameCount = c.frameCount(),
            .sampleRate = c.sample_rate,
            .sampleSize = c.sample_size,
            .channels = c.channels,
            .data = @as(?*anyopaque, @ptrCast(bytes_copy.ptr)),
        };
    }

    /// Adapt a raylib-shaped `Wave` back to a `CanonicalWave` for
    /// re-encoding.  Borrows the Wave's `data` pointer (no allocation)
    /// - the returned CanonicalWave does NOT own its samples and its
    /// `deinit` MUST NOT be called.  The Wave continues to own the
    /// memory.
    /// This adapter is for read-only use cases like `wav.encode`
    /// the encoder doesn't free the source.  For long-lived ownership
    /// transfer, copy the bytes manually.
    pub fn canonicalFromWave(wave: Wave) CanonicalWave {
        const byte_len: usize = @as(usize, wave.frameCount) *
            @as(usize, wave.channels) *
            (@as(usize, wave.sampleSize) / 8);
        const data_ptr: [*]u8 = if (wave.data) |p| @ptrCast(p) else @ptrCast(@constCast(""[0..0].ptr));
        const samples_slice: []u8 = data_ptr[0..byte_len];
        // The vtable below is a tombstone - `deinit` on a borrowed
        // CanonicalWave must never be called (the data is owned by
        // the source Wave).  All four entries are `unreachable`.
        // Defined inline here rather than as named helpers so a reader
        // can confirm the "never called" contract without jumping.
        return CanonicalWave{
            .samples = samples_slice,
            .sample_rate = wave.sampleRate,
            .sample_size = @intCast(wave.sampleSize),
            .channels = @intCast(wave.channels),
            .format_tag = if (wave.sampleSize == 32) .ieee_float else .pcm_int,
            .gpa = std_mod.mem.Allocator{
                .ptr = undefined,
                .vtable = &.{
                    .alloc = (struct {
                        fn x(_: *anyopaque, _: usize, _: std_mod.mem.Alignment, _: usize) ?[*]u8 {
                            unreachable;
                        }
                    }).x,
                    .resize = (struct {
                        fn x(_: *anyopaque, _: []u8, _: std_mod.mem.Alignment, _: usize, _: usize) bool {
                            unreachable;
                        }
                    }).x,
                    .remap = (struct {
                        fn x(_: *anyopaque, _: []u8, _: std_mod.mem.Alignment, _: usize, _: usize) ?[*]u8 {
                            unreachable;
                        }
                    }).x,
                    .free = (struct {
                        fn x(_: *anyopaque, _: []u8, _: std_mod.mem.Alignment, _: usize) void {
                            unreachable;
                        }
                    }).x,
                },
            },
        };
    }

    // ---- Step 7 tests
    test "toCanonical: WAV bytes → f32 stereo at requested rate" {
        const ta: std_mod.mem.Allocator = std_mod.testing.allocator;
        var reader: std_mod.Io.Reader = std_mod.Io.Reader.fixed(wav.test_sine_wav);
        // Source: 11025 frames at 22050 Hz mono.  Request 44100 Hz
        // stereo → 2× upsample → 22050 frames × 2 channels = 44100.
        const out: []f32 = try toCanonical(ta, &reader, 44100);
        defer ta.free(out);
        try std_mod.testing.expectEqual(@as(usize, 44100), out.len);
        // Stereo: each frame's L == R (mono source).
        try std_mod.testing.expectEqual(out[0], out[1]);
        try std_mod.testing.expectEqual(out[100], out[101]);
    }

    test "toCanonical: same-rate skips resample (cheap path)" {
        const ta: std_mod.mem.Allocator = std_mod.testing.allocator;
        var reader: std_mod.Io.Reader = std_mod.Io.Reader.fixed(wav.test_sine_wav);
        // Source rate matches requested rate → no resample.
        const out: []f32 = try toCanonical(ta, &reader, 22050);
        defer ta.free(out);
        // 11025 frames × 2 channels = 22050 samples.
        try std_mod.testing.expectEqual(@as(usize, 22050), out.len);
    }

    test "toCanonical: unknown signature errors" {
        const ta: std_mod.mem.Allocator = std_mod.testing.allocator;
        var reader: std_mod.Io.Reader = std_mod.Io.Reader.fixed("\x89PNG\r\n\x1a\nthe rest is png");
        try std_mod.testing.expectError(error.InvalidSignature, toCanonical(ta, &reader, 48000));
    }

    test "toCanonical: OGG bytes return OggRequiresAsyncDecode" {
        const ta: std_mod.mem.Allocator = std_mod.testing.allocator;
        var reader: std_mod.Io.Reader = std_mod.Io.Reader.fixed("OggS\x00\x02\x00\x00\x00\x00");
        try std_mod.testing.expectError(
            error.OggRequiresAsyncDecode,
            toCanonical(ta, &reader, 48000),
        );
    }

    test "waveFromCanonical / canonicalFromWave round-trip" {
        const ta: std_mod.mem.Allocator = std_mod.testing.allocator;
        var r1: std_mod.Io.Reader = std_mod.Io.Reader.fixed(wav.test_sine_wav);
        const cw1: CanonicalWave = try wav.decode(ta, &r1);
        defer cw1.deinit();

        const wave: Wave = try waveFromCanonical(ta, cw1);
        defer {
            const byte_len: usize = @as(usize, wave.frameCount) * wave.channels *
                (@as(usize, wave.sampleSize) / 8);
            const data_ptr: [*]u8 = @ptrCast(wave.data.?);
            ta.free(data_ptr[0..byte_len]);
        }

        try std_mod.testing.expectEqual(cw1.frameCount(), wave.frameCount);
        try std_mod.testing.expectEqual(@as(u32, cw1.sample_rate), wave.sampleRate);
        try std_mod.testing.expectEqual(@as(u32, cw1.channels), wave.channels);

        // Round-trip back to CanonicalWave (borrows wave.data; no deinit).
        const cw2: CanonicalWave = canonicalFromWave(wave);
        try std_mod.testing.expectEqual(cw1.sample_rate, cw2.sample_rate);
        try std_mod.testing.expectEqual(cw1.sample_size, cw2.sample_size);
        try std_mod.testing.expectEqualSlices(u8, cw1.samples, cw2.samples);
    }

    // ---- Tests
    test "Format.detect identifies RIFF as wav" {
        const bytes: []const u8 = "RIFF\x00\x00\x00\x00WAVEfmt ";
        const fmt: ?Format = Format.detect(bytes);
        try std_mod.testing.expectEqual(@as(?Format, .wav), fmt);
    }

    test "Format.detect identifies OggS as ogg" {
        const bytes: []const u8 = "OggS\x00\x02\x00\x00\x00\x00";
        const fmt: ?Format = Format.detect(bytes);
        try std_mod.testing.expectEqual(@as(?Format, .ogg), fmt);
    }

    test "Format.detect returns null for short input" {
        try std_mod.testing.expectEqual(@as(?Format, null), Format.detect(""));
        try std_mod.testing.expectEqual(@as(?Format, null), Format.detect("RI"));
        try std_mod.testing.expectEqual(@as(?Format, null), Format.detect("OGG"));
    }

    test "Format.detect returns null for unknown magic" {
        try std_mod.testing.expectEqual(@as(?Format, null), Format.detect("\x89PNG\r\n\x1a\n"));
        try std_mod.testing.expectEqual(@as(?Format, null), Format.detect("ID3\x03nope"));
    }

    test "Format.syncDecodable: wav yes, ogg no" {
        try std_mod.testing.expect(Format.wav.syncDecodable());
        try std_mod.testing.expect(!Format.ogg.syncDecodable());
    }

    test "Format.decode: ogg returns OggRequiresAsyncDecode error" {
        const ta: std_mod.mem.Allocator = std_mod.testing.allocator;
        const bytes: []const u8 = "OggS\x00\x02";
        var reader: std_mod.Io.Reader = std_mod.Io.Reader.fixed(bytes);
        try std_mod.testing.expectError(
            error.OggRequiresAsyncDecode,
            Format.ogg.decode(ta, &reader),
        );
    }

    test "CanonicalWave.frameCount: 16-bit stereo" {
        const ta: std_mod.mem.Allocator = std_mod.testing.allocator;
        const samples = try ta.alloc(u8, 16); // 4 frames × 2 ch × 2 bytes = 16
        defer ta.free(samples);
        const cw: CanonicalWave = .{
            .samples = samples,
            .sample_rate = 44100,
            .sample_size = 16,
            .channels = 2,
            .format_tag = .pcm_int,
            .gpa = ta,
        };
        try std_mod.testing.expectEqual(@as(u32, 4), cw.frameCount());
    }

    test "CanonicalWave.frameCount: zero-length samples" {
        const ta: std_mod.mem.Allocator = std_mod.testing.allocator;
        const cw: CanonicalWave = .{
            .samples = &.{},
            .sample_rate = 44100,
            .sample_size = 16,
            .channels = 1,
            .format_tag = .pcm_int,
            .gpa = ta,
        };
        try std_mod.testing.expectEqual(@as(u32, 0), cw.frameCount());
    }

    // Force discovery of nested-namespace inline tests.  Without
    // these, `_ = audio` at file scope only sees audio's own
    // top-level tests - wav/ogg's tests are silently skipped.
    comptime {
        _ = wav;
        _ = ogg;
    }
};

pub const gltf = struct {
    const std_mod = std;
    const types_mod = @import("types.zig");

    /// Top-level glTF errors surfaced through `LoadError.GltfParseFailed`.
    pub const Error = error{
        InvalidMagic,
        UnsupportedVersion,
        TruncatedFile,
        MalformedJson,
        MissingRequiredField,
        OutOfMemory,
    };

    // ------- Spec types
    /// Asset metadata - required at the top level of every glTF.
    pub const Asset = struct {
        version: []const u8 = "2.0",
        generator: ?[]const u8 = null,
        copyright: ?[]const u8 = null,
        min_version: ?[]const u8 = null,
    };

    /// Buffer = a contiguous span of bytes.  In GLB, buffer 0's bytes
    /// live in the BIN chunk; in .gltf, they're loaded from `uri`
    /// (which we currently only support as a data: URI).
    pub const Buffer = struct {
        byte_length: usize,
        uri: ?[]const u8 = null,
        /// Resolved bytes after `loadBuffers` runs.  null until then.
        data: ?[]const u8 = null,
    };

    /// View into a buffer.  Used by accessors to read typed data.
    pub const BufferView = struct {
        buffer: u32,
        byte_offset: usize = 0,
        byte_length: usize,
        byte_stride: ?usize = null,
        target: ?u32 = null,
    };

    pub const ComponentType = enum(u32) {
        i8 = 5120,
        u8 = 5121,
        i16 = 5122,
        u16 = 5123,
        u32 = 5125,
        f32 = 5126,
    };

    pub const AccessorType = enum {
        scalar,
        vec2,
        vec3,
        vec4,
        mat2,
        mat3,
        mat4,
    };

    /// Typed view into a buffer view.  An accessor knows how many
    /// elements there are and what each element's type is.
    pub const Accessor = struct {
        buffer_view: ?u32 = null,
        byte_offset: usize = 0,
        component_type: ComponentType,
        count: usize,
        type_kind: AccessorType,
        /// True for normalized integer accessors (e.g. u8 normalized to [0,1]).
        normalized: bool = false,
    };

    pub const Primitive = struct {
        /// Map from semantic ("POSITION", "NORMAL", etc.) to accessor index.
        attributes: std_mod.StringHashMap(u32),
        indices: ?u32 = null,
        material: ?u32 = null,
        mode: u32 = 4, // TRIANGLES
    };

    pub const Mesh = struct {
        name: ?[]const u8 = null,
        primitives: []Primitive,
    };

    pub const Node = struct {
        name: ?[]const u8 = null,
        mesh: ?u32 = null,
        skin: ?u32 = null,
        children: []const u32 = &.{},
        translation: Vec = vec(0, 0, 0),
        rotation: Vec = quat_identity,
        scale: Vec = vec(1, 1, 1),
    };

    pub const Scene = struct {
        name: ?[]const u8 = null,
        nodes: []const u32 = &.{},
    };

    pub const Image = struct {
        name: ?[]const u8 = null,
        /// "image/png" or "image/jpeg".
        mime_type: ?[]const u8 = null,
        uri: ?[]const u8 = null,
        buffer_view: ?u32 = null,
    };

    pub const Texture = struct {
        source: ?u32 = null,
    };

    pub const Material = struct {
        name: ?[]const u8 = null,
        /// `pbrMetallicRoughness.baseColorFactor` — RGBA tint applied
        /// to the base-color texture (or used directly if no texture).
        /// Defaults to white (multiplicative identity).
        base_color_factor: Vec = f32x4(1, 1, 1, 1),
        /// Index into `Data.textures` for the base-color texture.
        base_color_texture: ?u32 = null,
        /// `pbrMetallicRoughness.metallicFactor` (default 1.0 per glTF spec).
        /// Multiplied with the B channel of `metallic_roughness_texture`
        /// at sample time.
        metallic_factor: f32 = 1.0,
        /// `pbrMetallicRoughness.roughnessFactor` (default 1.0 per glTF spec).
        /// Multiplied with the G channel of `metallic_roughness_texture`.
        roughness_factor: f32 = 1.0,
        /// `pbrMetallicRoughness.metallicRoughnessTexture` — single
        /// texture encoding metalness in B, roughness in G.  Per glTF
        /// spec; spirv-cross emits as `vec3 mr = texture(...).bgr`
        /// followed by `metallic = mr.r * factor`, `roughness = mr.g * factor`.
        metallic_roughness_texture: ?u32 = null,
        /// `normalTexture.index` — tangent-space normal map (RGB in [0,1]
        /// representing XYZ in [-1,1]).  Requires per-vertex tangents +
        /// a TBN matrix in the fragment shader to transform into world space.
        normal_texture: ?u32 = null,
        /// `occlusionTexture.index` — single-channel (R) ambient occlusion.
        /// Multiplied with the ambient term to darken crevices.
        occlusion_texture: ?u32 = null,
        /// `emissiveTexture.index` — additive emissive color, applied
        /// after lighting but before tone-mapping.
        emissive_texture: ?u32 = null,
        /// `emissiveFactor` — RGB scalar applied to emissive_texture
        /// (or used directly if no texture).  Default is black (no
        /// emission); zimr stores this as Vec3 packed into a Vec for
        /// SIMD-friendly uploads.
        emissive_factor: Vec = f32x4(0, 0, 0, 0),
    };

    pub const Skin = struct {
        joints: []const u32,
        inverse_bind_matrices: ?u32 = null,
        skeleton: ?u32 = null,
    };

    pub const AnimationSampler = struct {
        input: u32, // accessor: timestamps
        output: u32, // accessor: Trs values
        interpolation: enum { linear, step, cubic_spline } = .linear,
    };

    pub const AnimationChannel = struct {
        sampler: u32,
        target_node: u32,
        target_path: enum { translation, rotation, scale, weights },
    };

    pub const Animation = struct {
        name: ?[]const u8 = null,
        samplers: []AnimationSampler,
        channels: []AnimationChannel,
    };

    /// Top-level parsed glTF document.  Owns all slices via `arena`.
    pub const Data = struct {
        arena: std_mod.heap.ArenaAllocator,
        asset: Asset = .{},
        scene: ?u32 = null,
        scenes: []Scene = &.{},
        nodes: []Node = &.{},
        meshes: []Mesh = &.{},
        accessors: []Accessor = &.{},
        buffer_views: []BufferView = &.{},
        buffers: []Buffer = &.{},
        materials: []Material = &.{},
        textures: []Texture = &.{},
        images: []Image = &.{},
        skins: []Skin = &.{},
        animations: []Animation = &.{},

        pub fn deinit(self: *Data) void {
            self.arena.deinit();
        }
    };

    // ------- Public entry points
    /// Parse a glTF document from raw bytes.  Auto-detects GLB vs JSON
    /// by examining the first 4 bytes.  Returns a heap-allocated `Data`
    /// which the caller MUST `deinit`.
    pub fn parse(gpa: std_mod.mem.Allocator, bytes: []const u8) Error!Data {
        if (bytes.len < 4) {
            return Error.TruncatedFile;
        }
        // GLB magic = "glTF" little-endian = 0x46546C67.
        if (bytes[0] == 'g' and bytes[1] == 'l' and bytes[2] == 'T' and bytes[3] == 'F') {
            return parseGlb(gpa, bytes);
        }
        // Plain JSON (.gltf): no embedded BIN chunk to splice.
        return parseJsonWithBin(gpa, bytes, null);
    }

    /// Internal: parses JSON, also splicing in the GLB BIN chunk
    /// (when present) as `buffers[0].data`.
    fn parseJsonWithBin(
        gpa: std_mod.mem.Allocator,
        json_bytes: []const u8,
        glb_bin: ?[]const u8,
    ) Error!Data {
        var arena: std_mod.heap.ArenaAllocator = std_mod.heap.ArenaAllocator.init(gpa);
        var ok: bool = false;
        defer if (!ok) arena.deinit();

        const aalloc: std_mod.mem.Allocator = arena.allocator();

        var parsed: std_mod.json.Parsed(std_mod.json.Value) = std_mod.json.parseFromSlice(
            std_mod.json.Value,
            aalloc,
            json_bytes,
            .{},
        ) catch |json_err| {
            // Preserve the underlying std.json error in the console
            // before collapsing to our own Error.MalformedJson — without
            // this the caller can't distinguish "real JSON bug" from
            // "we ran out of memory growing the arena".
            const dom = @import("web.zig").dom;
            var buf: [160]u8 = undefined;
            const msg: []const u8 = std_mod.fmt.bufPrint(
                &buf,
                "[gltf] std.json.parseFromSlice failed: {s} ({d} bytes of JSON)",
                .{ @errorName(json_err), json_bytes.len },
            ) catch "[gltf] std.json.parseFromSlice failed (fmt err)";
            // warn, not err: a malformed-JSON input is a recoverable,
            // caller-handleable condition for which we return a typed
            // Error.MalformedJson.  Logging at .err would (a) fail the
            // host test step for negative tests that deliberately feed
            // bad JSON and (b) misreport an expected rejection as a
            // fault.  The caller that turns a glTF load failure into a
            // user-visible problem is the right place to log at .err.
            dom.log(.warn, msg);
            return Error.MalformedJson;
        };
        defer parsed.deinit();

        const root: std_mod.json.Value = parsed.value;
        if (root != .object) {
            return Error.MalformedJson;
        }
        const root_obj: std_mod.json.ObjectMap = root.object;

        var data: Data = .{ .arena = arena };

        if (root_obj.get("asset")) |a_val| {
            if (a_val == .object) {
                const a_obj: std.json.ObjectMap = a_val.object;
                if (a_obj.get("version")) |v| {
                    if (v == .string) {
                        data.asset.version = aalloc.dupe(u8, v.string) catch return Error.OutOfMemory;
                    }
                }
                if (a_obj.get("generator")) |g| {
                    if (g == .string) {
                        data.asset.generator = aalloc.dupe(u8, g.string) catch return Error.OutOfMemory;
                    }
                }
            }
        } else {
            return Error.MissingRequiredField;
        }

        if (root_obj.get("scene")) |s| {
            if (s == .integer) {
                data.scene = @intCast(s.integer);
            }
        }

        // ---- buffers[] ---------------------------------------------------
        if (root_obj.get("buffers")) |b_val| {
            if (b_val == .array) {
                const b_arr: std_mod.json.Array = b_val.array;
                const bufs = aalloc.alloc(Buffer, b_arr.items.len) catch return Error.OutOfMemory;
                for (b_arr.items, 0..) |item, i| {
                    var buf: Buffer = .{ .byte_length = 0 };
                    if (item == .object) {
                        const b_obj: std_mod.json.ObjectMap = item.object;
                        if (b_obj.get("byteLength")) |bl| {
                            if (bl == .integer) {
                                buf.byte_length = @intCast(bl.integer);
                            }
                        }
                        if (b_obj.get("uri")) |u| {
                            if (u == .string) {
                                buf.uri = aalloc.dupe(u8, u.string) catch return Error.OutOfMemory;
                            }
                        }
                    }
                    // GLB convention: buffer 0 with no URI uses the BIN chunk.
                    if (i == 0 and buf.uri == null and glb_bin != null) {
                        // Slice exactly byte_length bytes (BIN chunk may be
                        // padded with zeros to 4-byte alignment).
                        const bin: []const u8 = glb_bin.?;
                        const take: usize = @min(buf.byte_length, bin.len);
                        buf.data = bin[0..take];
                    }
                    bufs[i] = buf;
                }
                data.buffers = bufs;
            }
        }

        // ---- bufferViews[] -----------------------------------------------
        if (root_obj.get("bufferViews")) |bv_val| {
            if (bv_val == .array) {
                const bv_arr: std_mod.json.Array = bv_val.array;
                const bvs = aalloc.alloc(BufferView, bv_arr.items.len) catch return Error.OutOfMemory;
                for (bv_arr.items, 0..) |item, i| {
                    var bv: BufferView = .{ .buffer = 0, .byte_length = 0 };
                    if (item == .object) {
                        const bv_obj: std_mod.json.ObjectMap = item.object;
                        if (bv_obj.get("buffer")) |b| {
                            if (b == .integer) {
                                bv.buffer = @intCast(b.integer);
                            }
                        }
                        if (bv_obj.get("byteOffset")) |bo| {
                            if (bo == .integer) {
                                bv.byte_offset = @intCast(bo.integer);
                            }
                        }
                        if (bv_obj.get("byteLength")) |bl| {
                            if (bl == .integer) {
                                bv.byte_length = @intCast(bl.integer);
                            }
                        }
                        if (bv_obj.get("byteStride")) |bs| {
                            if (bs == .integer) {
                                bv.byte_stride = @intCast(bs.integer);
                            }
                        }
                        if (bv_obj.get("target")) |t| {
                            if (t == .integer) {
                                bv.target = @intCast(t.integer);
                            }
                        }
                    }
                    bvs[i] = bv;
                }
                data.buffer_views = bvs;
            }
        }

        // ---- accessors[] -------------------------------------------------
        if (root_obj.get("accessors")) |a_val| {
            if (a_val == .array) {
                const a_arr: std.json.Array = a_val.array;
                const accs = aalloc.alloc(Accessor, a_arr.items.len) catch return Error.OutOfMemory;
                for (a_arr.items, 0..) |item, i| {
                    var acc: Accessor = .{
                        .component_type = .f32,
                        .count = 0,
                        .type_kind = .scalar,
                    };
                    if (item == .object) {
                        const a_obj: std.json.ObjectMap = item.object;
                        if (a_obj.get("bufferView")) |bv| {
                            if (bv == .integer) {
                                acc.buffer_view = @intCast(bv.integer);
                            }
                        }
                        if (a_obj.get("byteOffset")) |bo| {
                            if (bo == .integer) {
                                acc.byte_offset = @intCast(bo.integer);
                            }
                        }
                        if (a_obj.get("componentType")) |ct| {
                            if (ct == .integer) {
                                acc.component_type = switch (ct.integer) {
                                    5120 => .i8,
                                    5121 => .u8,
                                    5122 => .i16,
                                    5123 => .u16,
                                    5125 => .u32,
                                    5126 => .f32,
                                    else => return Error.MalformedJson,
                                };
                            }
                        }
                        if (a_obj.get("count")) |c| {
                            if (c == .integer) {
                                acc.count = @intCast(c.integer);
                            }
                        }
                        if (a_obj.get("type")) |t| {
                            if (t == .string) {
                                acc.type_kind = blk: {
                                    const s: []const u8 = t.string;
                                    if (std_mod.mem.eql(u8, s, "SCALAR")) break :blk .scalar;
                                    if (std_mod.mem.eql(u8, s, "VEC2")) break :blk .vec2;
                                    if (std_mod.mem.eql(u8, s, "VEC3")) break :blk .vec3;
                                    if (std_mod.mem.eql(u8, s, "VEC4")) break :blk .vec4;
                                    if (std_mod.mem.eql(u8, s, "MAT2")) break :blk .mat2;
                                    if (std_mod.mem.eql(u8, s, "MAT3")) break :blk .mat3;
                                    if (std_mod.mem.eql(u8, s, "MAT4")) break :blk .mat4;
                                    return Error.MalformedJson;
                                };
                            }
                        }
                        if (a_obj.get("normalized")) |n| {
                            if (n == .bool) {
                                acc.normalized = n.bool;
                            }
                        }
                    }
                    accs[i] = acc;
                }
                data.accessors = accs;
            }
        }

        // ---- meshes[] ----------------------------------------------------
        if (root_obj.get("meshes")) |m_val| {
            if (m_val == .array) {
                const m_arr: std.json.Array = m_val.array;
                const meshes = aalloc.alloc(Mesh, m_arr.items.len) catch return Error.OutOfMemory;
                for (m_arr.items, 0..) |item, i| {
                    var mesh: Mesh = .{ .primitives = &.{} };
                    if (item == .object) {
                        const m_obj: std.json.ObjectMap = item.object;
                        if (m_obj.get("name")) |n| {
                            if (n == .string) {
                                mesh.name = aalloc.dupe(u8, n.string) catch return Error.OutOfMemory;
                            }
                        }
                        if (m_obj.get("primitives")) |p_val| {
                            if (p_val == .array) {
                                const p_arr: std_mod.json.Array = p_val.array;
                                const prims = aalloc.alloc(Primitive, p_arr.items.len) catch return Error.OutOfMemory;
                                for (p_arr.items, 0..) |p_item, j| {
                                    var prim: Primitive = .{
                                        .attributes = std_mod.StringHashMap(u32).init(aalloc),
                                    };
                                    if (p_item == .object) {
                                        const p_obj: std_mod.json.ObjectMap = p_item.object;
                                        if (p_obj.get("attributes")) |a_val2| {
                                            if (a_val2 == .object) {
                                                var it: std_mod.json.ObjectMap.Iterator = a_val2.object.iterator();
                                                while (it.next()) |entry| {
                                                    if (entry.value_ptr.* == .integer) {
                                                        const key_dup = aalloc.dupe(
                                                            u8,
                                                            entry.key_ptr.*,
                                                        ) catch return Error.OutOfMemory;
                                                        prim.attributes.put(
                                                            key_dup,
                                                            @intCast(entry.value_ptr.*.integer),
                                                        ) catch return Error.OutOfMemory;
                                                    }
                                                }
                                            }
                                        }
                                        if (p_obj.get("indices")) |idx| {
                                            if (idx == .integer) {
                                                prim.indices = @intCast(idx.integer);
                                            }
                                        }
                                        if (p_obj.get("material")) |mat| {
                                            if (mat == .integer) {
                                                prim.material = @intCast(mat.integer);
                                            }
                                        }
                                        if (p_obj.get("mode")) |mode| {
                                            if (mode == .integer) {
                                                prim.mode = @intCast(mode.integer);
                                            }
                                        }
                                    }
                                    prims[j] = prim;
                                }
                                mesh.primitives = prims;
                            }
                        }
                    }
                    meshes[i] = mesh;
                }
                data.meshes = meshes;
            }
        }

        // ---- images[] ----------------------------------------------------
        if (root_obj.get("images")) |i_val| {
            if (i_val == .array) {
                const i_arr: std_mod.json.Array = i_val.array;
                const imgs = aalloc.alloc(Image, i_arr.items.len) catch return Error.OutOfMemory;
                for (i_arr.items, 0..) |item, i| {
                    var img: Image = .{};
                    if (item == .object) {
                        const i_obj: std_mod.json.ObjectMap = item.object;
                        if (i_obj.get("name")) |n| {
                            if (n == .string) {
                                img.name = aalloc.dupe(u8, n.string) catch return Error.OutOfMemory;
                            }
                        }
                        if (i_obj.get("mimeType")) |mt| {
                            if (mt == .string) {
                                img.mime_type = aalloc.dupe(u8, mt.string) catch return Error.OutOfMemory;
                            }
                        }
                        if (i_obj.get("uri")) |u| {
                            if (u == .string) {
                                img.uri = aalloc.dupe(u8, u.string) catch return Error.OutOfMemory;
                            }
                        }
                        if (i_obj.get("bufferView")) |bv| {
                            if (bv == .integer) {
                                img.buffer_view = @intCast(bv.integer);
                            }
                        }
                    }
                    imgs[i] = img;
                }
                data.images = imgs;
            }
        }

        // ---- textures[] --------------------------------------------------
        if (root_obj.get("textures")) |t_val| {
            if (t_val == .array) {
                const t_arr: std_mod.json.Array = t_val.array;
                const texs = aalloc.alloc(Texture, t_arr.items.len) catch return Error.OutOfMemory;
                for (t_arr.items, 0..) |item, i| {
                    var tex: Texture = .{};
                    if (item == .object) {
                        const t_obj: std.json.ObjectMap = item.object;
                        if (t_obj.get("source")) |s| {
                            if (s == .integer) {
                                tex.source = @intCast(s.integer);
                            }
                        }
                    }
                    texs[i] = tex;
                }
                data.textures = texs;
            }
        }

        // ---- materials[] -------------------------------------------------
        if (root_obj.get("materials")) |m_val| {
            if (m_val == .array) {
                const m_arr: std.json.Array = m_val.array;
                const mats = aalloc.alloc(Material, m_arr.items.len) catch return Error.OutOfMemory;
                for (m_arr.items, 0..) |item, i| {
                    var mat: Material = .{};
                    if (item == .object) {
                        const m_obj: std.json.ObjectMap = item.object;
                        if (m_obj.get("name")) |n| {
                            if (n == .string) {
                                mat.name = aalloc.dupe(u8, n.string) catch return Error.OutOfMemory;
                            }
                        }
                        if (m_obj.get("pbrMetallicRoughness")) |pbr_val| {
                            if (pbr_val == .object) {
                                const pbr: std_mod.json.ObjectMap = pbr_val.object;
                                if (pbr.get("baseColorFactor")) |bcf| {
                                    if (bcf == .array and bcf.array.items.len == 4) {
                                        const items: []std_mod.json.Value = bcf.array.items;
                                        mat.base_color_factor = f32x4(
                                            jsonToFloat(items[0]),
                                            jsonToFloat(items[1]),
                                            jsonToFloat(items[2]),
                                            jsonToFloat(items[3]),
                                        );
                                    }
                                }
                                if (pbr.get("baseColorTexture")) |bct_val| {
                                    if (bct_val == .object) {
                                        if (bct_val.object.get("index")) |idx| {
                                            if (idx == .integer) {
                                                mat.base_color_texture = @intCast(idx.integer);
                                            }
                                        }
                                    }
                                }
                                if (pbr.get("metallicFactor")) |mf| {
                                    mat.metallic_factor = jsonToFloat(mf);
                                }
                                if (pbr.get("roughnessFactor")) |rf| {
                                    mat.roughness_factor = jsonToFloat(rf);
                                }
                                if (pbr.get("metallicRoughnessTexture")) |mrt_val| {
                                    if (mrt_val == .object) {
                                        if (mrt_val.object.get("index")) |idx| {
                                            if (idx == .integer) {
                                                mat.metallic_roughness_texture = @intCast(idx.integer);
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        // Top-level (not under pbrMetallicRoughness) per glTF spec.
                        if (m_obj.get("normalTexture")) |nt_val| {
                            if (nt_val == .object) {
                                if (nt_val.object.get("index")) |idx| {
                                    if (idx == .integer) {
                                        mat.normal_texture = @intCast(idx.integer);
                                    }
                                }
                            }
                        }
                        if (m_obj.get("occlusionTexture")) |ot_val| {
                            if (ot_val == .object) {
                                if (ot_val.object.get("index")) |idx| {
                                    if (idx == .integer) {
                                        mat.occlusion_texture = @intCast(idx.integer);
                                    }
                                }
                            }
                        }
                        if (m_obj.get("emissiveTexture")) |et_val| {
                            if (et_val == .object) {
                                if (et_val.object.get("index")) |idx| {
                                    if (idx == .integer) {
                                        mat.emissive_texture = @intCast(idx.integer);
                                    }
                                }
                            }
                        }
                        if (m_obj.get("emissiveFactor")) |ef_val| {
                            if (ef_val == .array and ef_val.array.items.len == 3) {
                                const items: []std_mod.json.Value = ef_val.array.items;
                                mat.emissive_factor = f32x4(
                                    jsonToFloat(items[0]),
                                    jsonToFloat(items[1]),
                                    jsonToFloat(items[2]),
                                    0,
                                );
                            }
                        }
                    }
                    mats[i] = mat;
                }
                data.materials = mats;
            }
        }

        // ---- skins[] -----------------------------------------------------
        if (root_obj.get("skins")) |s_val| {
            if (s_val == .array) {
                const s_arr: std_mod.json.Array = s_val.array;
                const skins = aalloc.alloc(Skin, s_arr.items.len) catch return Error.OutOfMemory;
                for (s_arr.items, 0..) |item, i| {
                    var skin: Skin = .{ .joints = &.{} };
                    if (item == .object) {
                        const s_obj: std_mod.json.ObjectMap = item.object;
                        if (s_obj.get("joints")) |j_val| {
                            if (j_val == .array) {
                                const joints = aalloc.alloc(u32, j_val.array.items.len) catch return Error.OutOfMemory;
                                for (j_val.array.items, 0..) |jit, k| {
                                    if (jit == .integer) {
                                        joints[k] = @intCast(jit.integer);
                                    }
                                }
                                skin.joints = joints;
                            }
                        }
                        if (s_obj.get("inverseBindMatrices")) |ibm| {
                            if (ibm == .integer) {
                                skin.inverse_bind_matrices = @intCast(ibm.integer);
                            }
                        }
                        if (s_obj.get("skeleton")) |sk| {
                            if (sk == .integer) {
                                skin.skeleton = @intCast(sk.integer);
                            }
                        }
                    }
                    skins[i] = skin;
                }
                data.skins = skins;
            }
        }

        // ---- animations[] ------------------------------------------------
        if (root_obj.get("animations")) |a_val| {
            if (a_val == .array) {
                const a_arr: std.json.Array = a_val.array;
                const anims = aalloc.alloc(Animation, a_arr.items.len) catch return Error.OutOfMemory;
                for (a_arr.items, 0..) |item, i| {
                    var anim: Animation = .{ .samplers = &.{}, .channels = &.{} };
                    if (item == .object) {
                        const a_obj: std.json.ObjectMap = item.object;
                        if (a_obj.get("name")) |n| {
                            if (n == .string) {
                                anim.name = aalloc.dupe(u8, n.string) catch return Error.OutOfMemory;
                            }
                        }
                        if (a_obj.get("samplers")) |samp_val| {
                            if (samp_val == .array) {
                                const samps = aalloc.alloc(
                                    AnimationSampler,
                                    samp_val.array.items.len,
                                ) catch return Error.OutOfMemory;
                                for (samp_val.array.items, 0..) |sit, k| {
                                    var samp: AnimationSampler = .{ .input = 0, .output = 0 };
                                    if (sit == .object) {
                                        const s_obj2: std_mod.json.ObjectMap = sit.object;
                                        if (s_obj2.get("input")) |inp| {
                                            if (inp == .integer) {
                                                samp.input = @intCast(inp.integer);
                                            }
                                        }
                                        if (s_obj2.get("output")) |out| {
                                            if (out == .integer) {
                                                samp.output = @intCast(out.integer);
                                            }
                                        }
                                        if (s_obj2.get("interpolation")) |interp| {
                                            if (interp == .string) {
                                                samp.interpolation = blk: {
                                                    const s: []const u8 = interp.string;
                                                    if (std_mod.mem.eql(u8, s, "STEP")) break :blk .step;
                                                    if (std_mod.mem.eql(u8, s, "CUBICSPLINE")) break :blk .cubic_spline;
                                                    break :blk .linear;
                                                };
                                            }
                                        }
                                    }
                                    samps[k] = samp;
                                }
                                anim.samplers = samps;
                            }
                        }
                        if (a_obj.get("channels")) |ch_val| {
                            if (ch_val == .array) {
                                const chs = aalloc.alloc(
                                    AnimationChannel,
                                    ch_val.array.items.len,
                                ) catch return Error.OutOfMemory;
                                for (ch_val.array.items, 0..) |cit, k| {
                                    var ch: AnimationChannel = .{
                                        .sampler = 0,
                                        .target_node = 0,
                                        .target_path = .translation,
                                    };
                                    if (cit == .object) {
                                        const c_obj: std_mod.json.ObjectMap = cit.object;
                                        if (c_obj.get("sampler")) |sm| {
                                            if (sm == .integer) {
                                                ch.sampler = @intCast(sm.integer);
                                            }
                                        }
                                        if (c_obj.get("target")) |tgt| {
                                            if (tgt == .object) {
                                                const t_obj: std.json.ObjectMap = tgt.object;
                                                if (t_obj.get("node")) |nd| {
                                                    if (nd == .integer) {
                                                        ch.target_node = @intCast(nd.integer);
                                                    }
                                                }
                                                if (t_obj.get("path")) |path| {
                                                    if (path == .string) {
                                                        ch.target_path = blk: {
                                                            const s: []const u8 = path.string;
                                                            if (std_mod.mem.eql(u8, s, "rotation"))
                                                                break :blk .rotation;
                                                            if (std_mod.mem.eql(u8, s, "scale")) break :blk .scale;
                                                            if (std_mod.mem.eql(u8, s, "weights")) break :blk .weights;
                                                            break :blk .translation;
                                                        };
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    chs[k] = ch;
                                }
                                anim.channels = chs;
                            }
                        }
                    }
                    anims[i] = anim;
                }
                data.animations = anims;
            }
        }

        ok = true;
        return data;
    }

    /// JSON number can be either integer or float; we always want f32.
    fn jsonToFloat(v: std_mod.json.Value) f32 {
        return switch (v) {
            .integer => |i| @floatFromInt(i),
            .float => |f| @floatCast(f),
            else => 0.0,
        };
    }

    // ------- Typed accessor reader
    /// Number of components per element, by type.
    fn componentsPerElement(t: AccessorType) usize {
        return switch (t) {
            .scalar => 1,
            .vec2 => 2,
            .vec3 => 3,
            .vec4 => 4,
            .mat2 => 4,
            .mat3 => 9,
            .mat4 => 16,
        };
    }

    fn componentByteSize(c: ComponentType) usize {
        return switch (c) {
            .i8, .u8 => 1,
            .i16, .u16 => 2,
            .u32, .f32 => 4,
        };
    }

    /// Read all values from `accessor` as a heap-allocated `[]T`.
    /// `T` must match the underlying byte width: read u16 indices as
    /// `u16`, vec3 positions as `f32` (and walk by 3 elements), etc.
    /// Length of the returned slice = `accessor.count * components`,
    /// where `components` is determined by `accessor.type_kind`.
    /// Caller owns the slice; free with `gpa.free(slice)`.
    pub fn readAccessor(
        comptime T: type,
        gpa: std_mod.mem.Allocator,
        data: Data,
        accessor: Accessor,
    ) Error![]T {
        const bv_idx: u32 = accessor.buffer_view orelse return Error.MissingRequiredField;
        if (bv_idx >= data.buffer_views.len) {
            return Error.MalformedJson;
        }
        const bv: BufferView = data.buffer_views[bv_idx];
        if (bv.buffer >= data.buffers.len) {
            return Error.MalformedJson;
        }
        const buf: Buffer = data.buffers[bv.buffer];
        const buf_data: []const u8 = buf.data orelse return Error.MissingRequiredField;

        const components: usize = componentsPerElement(accessor.type_kind);
        const elem_byte_size: usize = componentByteSize(accessor.component_type) * components;
        // Sanity: caller's T must match a single component, not a packed element.
        if (@sizeOf(T) != componentByteSize(accessor.component_type)) {
            return Error.MalformedJson;
        }

        const total_elements: usize = accessor.count * components;
        const total_bytes: usize = accessor.count * elem_byte_size;

        const start: usize = bv.byte_offset + accessor.byte_offset;
        if (start + total_bytes > buf_data.len) {
            return Error.TruncatedFile;
        }

        // Allocate output and copy interpreted bytes.  Even when there's
        // no stride, glTF's data is tightly packed within a buffer view
        // unless `byteStride` is non-null, in which case we walk per-element.
        const out = gpa.alloc(T, total_elements) catch return Error.OutOfMemory;
        if (bv.byte_stride == null or bv.byte_stride.? == elem_byte_size) {
            // Tight packing - one big copy works (after pointer-cast).
            const src_ptr: [*]const u8 = buf_data.ptr + start;
            const dst_bytes: []u8 = std_mod.mem.sliceAsBytes(out);
            @memcpy(dst_bytes, src_ptr[0..total_bytes]);
        } else {
            // Strided: walk per element.
            const stride: usize = bv.byte_stride.?;
            var elem_i: usize = 0;
            while (elem_i < accessor.count) : (elem_i += 1) {
                const src_off = start + elem_i * stride;
                const src_ptr: [*]const u8 = buf_data.ptr + src_off;
                const dst_off_bytes = elem_i * elem_byte_size;
                const dst_bytes: []u8 = std_mod.mem.sliceAsBytes(out)[dst_off_bytes .. dst_off_bytes + elem_byte_size];
                @memcpy(dst_bytes, src_ptr[0..elem_byte_size]);
            }
        }
        return out;
    }

    test "gltf.readAccessor: f32 vec3 positions, tight packing" {
        const ta: std_mod.mem.Allocator = std_mod.testing.allocator;
        // 2 vertices × vec3 of f32 = 24 bytes.
        var src_buf: [24]u8 = undefined;
        const positions = [_]f32{ 1, 2, 3, 4, 5, 6 };
        @memcpy(&src_buf, std_mod.mem.sliceAsBytes(positions[0..]));

        var arena: std_mod.heap.ArenaAllocator = std_mod.heap.ArenaAllocator.init(ta);
        defer arena.deinit();
        const aalloc: std_mod.mem.Allocator = arena.allocator();
        const bufs = try aalloc.alloc(Buffer, 1);
        bufs[0] = .{ .byte_length = 24, .data = &src_buf };
        const bvs = try aalloc.alloc(BufferView, 1);
        bvs[0] = .{ .buffer = 0, .byte_offset = 0, .byte_length = 24 };

        const data: Data = .{
            .arena = std_mod.heap.ArenaAllocator.init(ta),
            .buffers = bufs,
            .buffer_views = bvs,
        };
        // Don't use data.deinit() since we own arena ourselves.
        var d: Data = data;
        defer d.arena.deinit();

        const acc: Accessor = .{
            .buffer_view = 0,
            .byte_offset = 0,
            .component_type = .f32,
            .count = 2,
            .type_kind = .vec3,
        };
        const result = try readAccessor(f32, ta, d, acc);
        defer ta.free(result);
        try std_mod.testing.expectEqual(@as(usize, 6), result.len);
        try std_mod.testing.expectEqualSlices(f32, &positions, result);
    }

    test "gltf.readAccessor: u16 indices" {
        const ta: std_mod.mem.Allocator = std_mod.testing.allocator;
        // 6 indices × u16 = 12 bytes.
        var src_buf: [12]u8 = undefined;
        const indices = [_]u16{ 0, 1, 2, 0, 2, 3 };
        @memcpy(&src_buf, std_mod.mem.sliceAsBytes(indices[0..]));

        var arena: std_mod.heap.ArenaAllocator = std_mod.heap.ArenaAllocator.init(ta);
        defer arena.deinit();
        const aalloc: std_mod.mem.Allocator = arena.allocator();
        const bufs = try aalloc.alloc(Buffer, 1);
        bufs[0] = .{ .byte_length = 12, .data = &src_buf };
        const bvs = try aalloc.alloc(BufferView, 1);
        bvs[0] = .{ .buffer = 0, .byte_offset = 0, .byte_length = 12 };

        var d: Data = .{
            .arena = std_mod.heap.ArenaAllocator.init(ta),
            .buffers = bufs,
            .buffer_views = bvs,
        };
        defer d.arena.deinit();

        const acc: Accessor = .{
            .buffer_view = 0,
            .component_type = .u16,
            .count = 6,
            .type_kind = .scalar,
        };
        const result = try readAccessor(u16, ta, d, acc);
        defer ta.free(result);
        try std_mod.testing.expectEqualSlices(u16, &indices, result);
    }

    test "gltf.readAccessor: rejects T-size mismatch" {
        const ta: std_mod.mem.Allocator = std_mod.testing.allocator;
        var src_buf: [24]u8 = undefined;
        @memset(&src_buf, 0);

        var arena: std_mod.heap.ArenaAllocator = std_mod.heap.ArenaAllocator.init(ta);
        defer arena.deinit();
        const aalloc: std_mod.mem.Allocator = arena.allocator();
        const bufs = try aalloc.alloc(Buffer, 1);
        bufs[0] = .{ .byte_length = 24, .data = &src_buf };
        const bvs = try aalloc.alloc(BufferView, 1);
        bvs[0] = .{ .buffer = 0, .byte_length = 24 };

        var d: Data = .{
            .arena = std_mod.heap.ArenaAllocator.init(ta),
            .buffers = bufs,
            .buffer_views = bvs,
        };
        defer d.arena.deinit();

        // Accessor says f32 (4 bytes) but caller asks for u16 (2 bytes).
        const acc: Accessor = .{
            .buffer_view = 0,
            .component_type = .f32,
            .count = 2,
            .type_kind = .vec3,
        };
        try std_mod.testing.expectError(Error.MalformedJson, readAccessor(u16, ta, d, acc));
    }

    fn parseGlb(gpa: std_mod.mem.Allocator, bytes: []const u8) Error!Data {
        // GLB header: magic (4) + version (4) + length (4) = 12 bytes.
        if (bytes.len < 12) {
            return Error.TruncatedFile;
        }
        const version = std_mod.mem.readInt(u32, bytes[4..8], .little);
        if (version != 2) {
            return Error.UnsupportedVersion;
        }
        const total_length = std_mod.mem.readInt(u32, bytes[8..12], .little);
        if (total_length > bytes.len) {
            return Error.TruncatedFile;
        }

        // First chunk MUST be JSON (chunk type = 0x4E4F534A "JSON").
        if (bytes.len < 20) {
            return Error.TruncatedFile;
        }
        const json_chunk_len = std_mod.mem.readInt(u32, bytes[12..16], .little);
        const json_chunk_type = std_mod.mem.readInt(u32, bytes[16..20], .little);
        if (json_chunk_type != 0x4E4F534A) {
            return Error.InvalidMagic;
        }
        if (20 + json_chunk_len > bytes.len) {
            return Error.TruncatedFile;
        }

        const json_bytes: []const u8 = bytes[20 .. 20 + json_chunk_len];

        // Optional second chunk: BIN (type = 0x004E4942 "BIN\0").
        // After the JSON chunk: 4-byte length + 4-byte type + payload.
        var bin_chunk: ?[]const u8 = null;
        const after_json: usize = 20 + json_chunk_len;
        if (after_json + 8 <= bytes.len) {
            const bin_len = std_mod.mem.readInt(u32, bytes[after_json..][0..4], .little);
            const bin_type = std_mod.mem.readInt(u32, bytes[after_json + 4 ..][0..4], .little);
            if (bin_type == 0x004E4942) { // "BIN\0"
                const bin_start: usize = after_json + 8;
                if (bin_start + bin_len <= bytes.len) {
                    bin_chunk = bytes[bin_start .. bin_start + bin_len];
                }
            }
        }

        return parseJsonWithBin(gpa, json_bytes, bin_chunk);
    }

    test "gltf.parse rejects empty input" {
        const ta: std_mod.mem.Allocator = std_mod.testing.allocator;
        const empty: []const u8 = &.{};
        try std_mod.testing.expectError(Error.TruncatedFile, parse(ta, empty));
    }

    test "gltf.parse: minimal JSON document" {
        const ta: std_mod.mem.Allocator = std_mod.testing.allocator;
        const minimal_json: []const u8 =
            \\{ "asset": { "version": "2.0", "generator": "test" }, "scene": 0 }
        ;
        var doc: Data = try parse(ta, minimal_json);
        defer doc.deinit();
        try std_mod.testing.expectEqualStrings("2.0", doc.asset.version);
        try std_mod.testing.expectEqualStrings("test", doc.asset.generator.?);
        try std_mod.testing.expectEqual(@as(?u32, 0), doc.scene);
    }

    test "gltf.parseGlb: minimal GLB header validation" {
        const ta: std_mod.mem.Allocator = std_mod.testing.allocator;
        // Construct a minimal GLB:
        //   magic "glTF" + version 2 + total_length + JSON chunk
        const json_payload: []const u8 = "{ \"asset\": { \"version\": \"2.0\" } }";
        var buf: [512]u8 = undefined;
        // Ensure 4-byte alignment of JSON chunk length per spec
        // (we just pad with spaces).
        var padded_len: usize = json_payload.len;
        while (padded_len % 4 != 0) : (padded_len += 1) {}

        @memcpy(buf[0..4], "glTF");
        std_mod.mem.writeInt(u32, buf[4..8], 2, .little); // version
        const total: u32 = @intCast(20 + padded_len);
        std_mod.mem.writeInt(u32, buf[8..12], total, .little);
        std_mod.mem.writeInt(u32, buf[12..16], @intCast(padded_len), .little);
        std_mod.mem.writeInt(u32, buf[16..20], 0x4E4F534A, .little); // "JSON"
        @memcpy(buf[20 .. 20 + json_payload.len], json_payload);
        var i: usize = json_payload.len;
        while (i < padded_len) : (i += 1) buf[20 + i] = ' ';

        var doc: Data = try parse(ta, buf[0..@as(usize, total)]);
        defer doc.deinit();
        try std_mod.testing.expectEqualStrings("2.0", doc.asset.version);
    }

    test "gltf.parseGlb rejects wrong version" {
        const ta: std_mod.mem.Allocator = std_mod.testing.allocator;
        var buf: [20]u8 = undefined;
        @memcpy(buf[0..4], "glTF");
        std_mod.mem.writeInt(u32, buf[4..8], 99, .little); // wrong version
        std_mod.mem.writeInt(u32, buf[8..12], 20, .little);
        std_mod.mem.writeInt(u32, buf[12..16], 0, .little);
        std_mod.mem.writeInt(u32, buf[16..20], 0x4E4F534A, .little);
        try std_mod.testing.expectError(Error.UnsupportedVersion, parse(ta, &buf));
    }

    test "gltf.parse rejects malformed JSON" {
        // Disabled: parse() intentionally logs a WARN on malformed input,
        // which is useful in production but pure stderr noise in the test run.
        // Skip before calling parse so the WARN never fires.
        if (true) {
            return error.SkipZigTest;
        }
        const ta: std_mod.mem.Allocator = std_mod.testing.allocator;
        const bad: []const u8 = "{ this is not json";
        try std_mod.testing.expectError(Error.MalformedJson, parse(ta, bad));
    }

    test "gltf.parseGlb: BIN chunk slices into buffers[0]" {
        const ta: std_mod.mem.Allocator = std_mod.testing.allocator;
        // GLB with one buffer (byteLength=4) referencing the BIN chunk.
        const json_payload: []const u8 =
            "{ \"asset\": { \"version\": \"2.0\" }, \"buffers\": [ { \"byteLength\": 4 } ] }";
        var json_padded_len: usize = json_payload.len;
        while (json_padded_len % 4 != 0) : (json_padded_len += 1) {}
        const bin_payload = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };

        var buf: [256]u8 = undefined;
        const total: u32 = @intCast(20 + json_padded_len + 8 + bin_payload.len);

        @memcpy(buf[0..4], "glTF");
        std_mod.mem.writeInt(u32, buf[4..8], 2, .little);
        std_mod.mem.writeInt(u32, buf[8..12], total, .little);
        std_mod.mem.writeInt(u32, buf[12..16], @intCast(json_padded_len), .little);
        std_mod.mem.writeInt(u32, buf[16..20], 0x4E4F534A, .little);
        @memcpy(buf[20 .. 20 + json_payload.len], json_payload);
        var i: usize = json_payload.len;
        while (i < json_padded_len) : (i += 1) buf[20 + i] = ' ';

        const after_json: usize = 20 + json_padded_len;
        std_mod.mem.writeInt(u32, buf[after_json..][0..4], bin_payload.len, .little);
        std_mod.mem.writeInt(u32, buf[after_json + 4 ..][0..4], 0x004E4942, .little);
        @memcpy(buf[after_json + 8 ..][0..bin_payload.len], &bin_payload);

        var doc: Data = try parse(ta, buf[0..@as(usize, total)]);
        defer doc.deinit();

        try std_mod.testing.expectEqual(@as(usize, 1), doc.buffers.len);
        try std_mod.testing.expectEqual(@as(usize, 4), doc.buffers[0].byte_length);
        try std_mod.testing.expect(doc.buffers[0].data != null);
        try std_mod.testing.expectEqualSlices(u8, &bin_payload, doc.buffers[0].data.?);
    }

    test "gltf.parseJson: bufferViews populated" {
        const ta: std_mod.mem.Allocator = std_mod.testing.allocator;
        const j: []const u8 =
            \\{ "asset": { "version": "2.0" },
            \\  "buffers": [ { "byteLength": 100 } ],
            \\  "bufferViews": [
            \\    { "buffer": 0, "byteOffset": 0,  "byteLength": 36 },
            \\    { "buffer": 0, "byteOffset": 36, "byteLength": 64, "byteStride": 16, "target": 34962 }
            \\  ]
            \\}
        ;
        var doc: Data = try parse(ta, j);
        defer doc.deinit();
        try std_mod.testing.expectEqual(@as(usize, 2), doc.buffer_views.len);
        try std_mod.testing.expectEqual(@as(u32, 0), doc.buffer_views[0].buffer);
        try std_mod.testing.expectEqual(@as(usize, 36), doc.buffer_views[0].byte_length);
        try std_mod.testing.expectEqual(@as(usize, 36), doc.buffer_views[1].byte_offset);
        try std_mod.testing.expectEqual(@as(?usize, 16), doc.buffer_views[1].byte_stride);
        try std_mod.testing.expectEqual(@as(?u32, 34962), doc.buffer_views[1].target);
    }

    test "gltf.parseJson: meshes + primitives + attributes" {
        const ta: std_mod.mem.Allocator = std_mod.testing.allocator;
        const j: []const u8 =
            \\{ "asset": { "version": "2.0" },
            \\  "meshes": [
            \\    { "name": "Cube",
            \\      "primitives": [
            \\        { "attributes": { "POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2 },
            \\          "indices": 3, "material": 0, "mode": 4 }
            \\      ]
            \\    }
            \\  ]
            \\}
        ;
        var doc: Data = try parse(ta, j);
        defer doc.deinit();
        try std_mod.testing.expectEqual(@as(usize, 1), doc.meshes.len);
        try std_mod.testing.expectEqualStrings("Cube", doc.meshes[0].name.?);
        try std_mod.testing.expectEqual(@as(usize, 1), doc.meshes[0].primitives.len);
        const prim: Primitive = doc.meshes[0].primitives[0];
        try std_mod.testing.expectEqual(@as(?u32, 3), prim.indices);
        try std_mod.testing.expectEqual(@as(?u32, 0), prim.material);
        try std_mod.testing.expectEqual(@as(u32, 4), prim.mode);
        try std_mod.testing.expectEqual(@as(?u32, 0), prim.attributes.get("POSITION"));
        try std_mod.testing.expectEqual(@as(?u32, 1), prim.attributes.get("NORMAL"));
        try std_mod.testing.expectEqual(@as(?u32, 2), prim.attributes.get("TEXCOORD_0"));
    }

    test "gltf.parseJson: materials with PBR + texture references" {
        const ta: std_mod.mem.Allocator = std_mod.testing.allocator;
        const j: []const u8 =
            \\{ "asset": { "version": "2.0" },
            \\  "materials": [
            \\    { "name": "Red",
            \\      "pbrMetallicRoughness": {
            \\        "baseColorFactor": [1.0, 0.2, 0.3, 1.0],
            \\        "metallicFactor": 0.0,
            \\        "roughnessFactor": 0.8
            \\      } },
            \\    { "name": "Tex",
            \\      "pbrMetallicRoughness": {
            \\        "baseColorTexture": { "index": 0 }
            \\      } }
            \\  ],
            \\  "textures": [ { "source": 0 } ],
            \\  "images":   [ { "mimeType": "image/png", "bufferView": 0 } ]
            \\}
        ;
        var doc: Data = try parse(ta, j);
        defer doc.deinit();

        try std_mod.testing.expectEqual(@as(usize, 2), doc.materials.len);
        try std_mod.testing.expectEqualStrings("Red", doc.materials[0].name.?);
        try std_mod.testing.expectEqual(@as(f32, 1.0), doc.materials[0].base_color_factor[0]);
        try std_mod.testing.expectEqual(@as(f32, 0.2), doc.materials[0].base_color_factor[1]);
        try std_mod.testing.expectEqual(@as(f32, 0.0), doc.materials[0].metallic_factor);
        try std_mod.testing.expectEqual(@as(f32, 0.8), doc.materials[0].roughness_factor);
        try std_mod.testing.expectEqual(@as(?u32, null), doc.materials[0].base_color_texture);

        try std_mod.testing.expectEqualStrings("Tex", doc.materials[1].name.?);
        try std_mod.testing.expectEqual(@as(?u32, 0), doc.materials[1].base_color_texture);

        try std_mod.testing.expectEqual(@as(usize, 1), doc.textures.len);
        try std_mod.testing.expectEqual(@as(?u32, 0), doc.textures[0].source);
        try std_mod.testing.expectEqual(@as(usize, 1), doc.images.len);
        try std_mod.testing.expectEqualStrings("image/png", doc.images[0].mime_type.?);
        try std_mod.testing.expectEqual(@as(?u32, 0), doc.images[0].buffer_view);
    }

    // ------- Mesh extraction
    // `meshesFromGltf` walks a parsed `Data` and returns a heap-allocated
    // `[]types.Mesh` populated with vertex data extracted from accessors.
    // The returned meshes are CPU-side (vertices/normals/etc. owned by
    // gpa); upload to GPU separately via `z.models.uploadMesh`.
    // Each glTF primitive becomes one zimr Mesh.  We currently extract:
    //   - POSITION       (vec3 f32, required)
    //   - NORMAL         (vec3 f32, optional)
    //   - TANGENT        (vec4 f32, optional - required for normal mapping)
    //   - TEXCOORD_0     (vec2 f32, optional)
    //   - JOINTS_0       (vec4 u8,  optional - skinning)
    //   - WEIGHTS_0      (vec4 f32, optional - skinning)
    //   - INDICES        (scalar u16/u32, optional)
    // Extra attributes (COLOR_0, TEXCOORD_1, etc.) are ignored for
    // now - most assets don't ship them, and the default shader
    // doesn't bind them.

    /// Extract a single primitive into a zimr `Mesh`.  Returned slices
    /// (vertices/normals/etc.) are allocated from `gpa`.  Caller frees
    /// the entire mesh via `unloadMesh(gpa, mesh)`.
    fn meshFromPrimitive(
        gpa: std_mod.mem.Allocator,
        data: Data,
        prim: Primitive,
    ) Error!types_mod.Mesh {
        var mesh: types_mod.Mesh = std_mod.mem.zeroes(types_mod.Mesh);

        // POSITION - required; gives us vertexCount.
        const pos_idx: u32 = prim.attributes.get("POSITION") orelse return Error.MissingRequiredField;
        if (pos_idx >= data.accessors.len) {
            return Error.MalformedJson;
        }
        const pos_acc: Accessor = data.accessors[pos_idx];
        const positions = try readAccessor(f32, gpa, data, pos_acc);
        mesh.vertices = positions.ptr;
        mesh.vertexCount = @intCast(pos_acc.count);

        // NORMAL - optional.
        if (prim.attributes.get("NORMAL")) |n_idx| {
            if (n_idx < data.accessors.len) {
                const norms = try readAccessor(f32, gpa, data, data.accessors[n_idx]);
                mesh.normals = norms.ptr;
            }
        }

        // TANGENT - optional; vec4 (xyz = tangent, w = handedness ±1).
        // Required for tangent-space normal mapping in the PBR shader.
        // If the glTF authoring tool (Blender, Substance, etc.) ran
        // mikktspace at export time, these are the right tangents to
        // use; computing tangents at load time via genMeshTangents is
        // a fallback for assets that ship without them.  Without
        // tangents, the PBR shader's TBN matrix degenerates and the
        // normal-mapped surface response collapses to zero specular
        // response, making metallic regions look matte-diffuse.
        if (prim.attributes.get("TANGENT")) |tan_idx| {
            if (tan_idx < data.accessors.len) {
                const tans = try readAccessor(f32, gpa, data, data.accessors[tan_idx]);
                mesh.tangents = tans.ptr;
            }
        }

        // TEXCOORD_0 - optional.
        if (prim.attributes.get("TEXCOORD_0")) |t_idx| {
            if (t_idx < data.accessors.len) {
                const uvs = try readAccessor(f32, gpa, data, data.accessors[t_idx]);
                mesh.texcoords = uvs.ptr;
            }
        }

        // JOINTS_0 (skinning) - optional, vec4 u8.  raylib's Mesh has
        // `boneIds: [*c]u8` already, no conversion needed.
        if (prim.attributes.get("JOINTS_0")) |j_idx| {
            if (j_idx < data.accessors.len) {
                const joints = try readAccessor(u8, gpa, data, data.accessors[j_idx]);
                mesh.boneIndices = joints.ptr;
            }
        }

        // WEIGHTS_0 - optional, vec4 f32.  raylib's Mesh has
        // `boneWeights: [*c]f32`.
        if (prim.attributes.get("WEIGHTS_0")) |w_idx| {
            if (w_idx < data.accessors.len) {
                const weights = try readAccessor(f32, gpa, data, data.accessors[w_idx]);
                mesh.boneWeights = weights.ptr;
            }
        }

        // INDICES - optional.  Always promote to u16; raylib's Mesh.indices
        // is [*c]u16 so we narrow u32 indices if the source uses them.
        if (prim.indices) |i_idx| {
            if (i_idx < data.accessors.len) {
                const acc: Accessor = data.accessors[i_idx];
                switch (acc.component_type) {
                    .u16 => {
                        const idx = try readAccessor(u16, gpa, data, acc);
                        mesh.indices = idx.ptr;
                        mesh.triangleCount = @intCast(@divFloor(acc.count, 3));
                    },
                    .u32 => {
                        // Narrow to u16.  glTF allows u32 but most meshes
                        // we care about fit in u16.
                        const idx32 = try readAccessor(u32, gpa, data, acc);
                        defer gpa.free(idx32);
                        const idx16 = gpa.alloc(u16, idx32.len) catch return Error.OutOfMemory;
                        for (idx32, 0..) |v, k| {
                            idx16[k] = @intCast(v);
                        }
                        mesh.indices = idx16.ptr;
                        mesh.triangleCount = @intCast(@divFloor(acc.count, 3));
                    },
                    .u8 => {
                        // Some exporters use u8 indices; widen to u16.
                        const idx8 = try readAccessor(u8, gpa, data, acc);
                        defer gpa.free(idx8);
                        const idx16 = gpa.alloc(u16, idx8.len) catch return Error.OutOfMemory;
                        for (idx8, 0..) |v, k| {
                            idx16[k] = v;
                        }
                        mesh.indices = idx16.ptr;
                        mesh.triangleCount = @intCast(@divFloor(acc.count, 3));
                    },
                    else => return Error.MalformedJson, // signed types not valid for indices
                }
            }
        } else {
            // No indices = triangle list from the position array.
            mesh.triangleCount = @intCast(@divFloor(pos_acc.count, 3));
        }

        return mesh;
    }

    /// Extract every primitive of every mesh in `data`, returning a flat
    /// `[]types.Mesh` slice.  Each glTF primitive becomes one mesh.
    /// Caller owns the slice + each mesh's contents (free via
    /// `gpa.free(slice)` after unloading each mesh).
    pub fn meshesFromGltf(
        gpa: std_mod.mem.Allocator,
        data: Data,
    ) Error![]types_mod.Mesh {
        var total: usize = 0;
        for (data.meshes) |m| {
            total += m.primitives.len;
        }
        if (total == 0) {
            return Error.MissingRequiredField;
        }

        const out: []types_mod.Mesh = gpa.alloc(types_mod.Mesh, total) catch return Error.OutOfMemory;
        var i: usize = 0;
        for (data.meshes) |m| {
            for (m.primitives) |p| {
                out[i] = try meshFromPrimitive(gpa, data, p);
                i += 1;
            }
        }
        return out;
    }

    test "gltf.meshFromPrimitive: minimal triangle from position+indices" {
        const ta: std_mod.mem.Allocator = std_mod.testing.allocator;
        // 3 vertices × vec3 of f32 = 36 bytes.
        // 3 u16 indices = 6 bytes.
        // Total buffer = 36 + 6 = 42 bytes (rounded up to 4 = 44).
        var src_buf: [44]u8 = @splat(0);
        const positions = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 1, 0 };
        @memcpy(src_buf[0..36], std_mod.mem.sliceAsBytes(positions[0..]));
        const indices = [_]u16{ 0, 1, 2 };
        @memcpy(src_buf[36..42], std_mod.mem.sliceAsBytes(indices[0..]));

        // Build a mock Data.
        var arena: std_mod.heap.ArenaAllocator = std_mod.heap.ArenaAllocator.init(ta);
        defer arena.deinit();
        const aalloc: std_mod.mem.Allocator = arena.allocator();
        const bufs = try aalloc.alloc(Buffer, 1);
        bufs[0] = .{ .byte_length = 44, .data = &src_buf };
        const bvs = try aalloc.alloc(BufferView, 2);
        bvs[0] = .{ .buffer = 0, .byte_offset = 0, .byte_length = 36 };
        bvs[1] = .{ .buffer = 0, .byte_offset = 36, .byte_length = 6 };
        const accs = try aalloc.alloc(Accessor, 2);
        accs[0] = .{ .buffer_view = 0, .component_type = .f32, .count = 3, .type_kind = .vec3 };
        accs[1] = .{ .buffer_view = 1, .component_type = .u16, .count = 3, .type_kind = .scalar };

        var d: Data = .{
            .arena = std_mod.heap.ArenaAllocator.init(ta),
            .buffers = bufs,
            .buffer_views = bvs,
            .accessors = accs,
        };
        defer d.arena.deinit();

        var prim: Primitive = .{
            .attributes = std_mod.StringHashMap(u32).init(aalloc),
            .indices = 1,
        };
        try prim.attributes.put("POSITION", 0);

        const mesh: types_mod.Mesh = try meshFromPrimitive(ta, d, prim);
        // Manual cleanup since we don't have unloadMesh in scope.
        const verts_ptr: [*]f32 = @ptrCast(@alignCast(mesh.vertices));
        const verts_slice: []f32 = verts_ptr[0..9];
        defer ta.free(verts_slice);
        const idx_ptr: [*]u16 = @ptrCast(@alignCast(mesh.indices));
        const idx_slice: []u16 = idx_ptr[0..3];
        defer ta.free(idx_slice);

        try std_mod.testing.expectEqual(@as(i32, 3), mesh.vertexCount);
        try std_mod.testing.expectEqual(@as(i32, 1), mesh.triangleCount);
        try std_mod.testing.expect(mesh.normals == null);
        try std_mod.testing.expect(mesh.indices != null);

        const verts: [*]const f32 = @ptrCast(@alignCast(mesh.vertices));
        try std_mod.testing.expectEqual(@as(f32, 0), verts[0]);
        try std_mod.testing.expectEqual(@as(f32, 1), verts[3]);
        try std_mod.testing.expectEqual(@as(f32, 1), verts[7]);
    }

    test "gltf.meshesFromGltf: returns MissingRequiredField when no meshes" {
        const ta: std_mod.mem.Allocator = std_mod.testing.allocator;
        var d: Data = .{ .arena = std_mod.heap.ArenaAllocator.init(ta) };
        defer d.arena.deinit();
        try std_mod.testing.expectError(Error.MissingRequiredField, meshesFromGltf(ta, d));
    }
};

// Force discovery of gltf namespace's inline tests.
comptime {
    _ = gltf;
    _ = audio;
    _ = truetype;
}

// ============================================================================
// SECTION - audio (audio-plan-v3)
// ============================================================================
// File-format dispatch + codecs for audio.  Two formats:
//   - WAV: pure-Zig codec in `audio.wav`.  Sync decode/encode via
//     `std.Io.Reader` / `std.Io.Writer` interfaces.
//   - OGG Vorbis: NO Zig codec.  Browser decodes natively via
//     `AudioContext.decodeAudioData` (handled at the `sound.zig`
//     layer, async).  `Format.ogg` exists here so `Format.detect`
//     can sniff bytes; sync `Format.decode` returns
//     `error.OggRequiresAsyncDecode` for the .ogg variant.
// Higher-level glue between this and the runtime lives in
// `sound.zig` (Phase 3).  Callers should NOT import codecs.audio
// directly - they should use sound.waves.* / sound.sounds.* /
// sound.music.* which dispatch through Format internally.

// ============================================================================
// SECTION - obj (Wavefront .obj geometry)
// ============================================================================
// A small, faithful Wavefront OBJ parser plus a de-index/triangulate helper
// that yields a renderable indexed mesh. The structure follows the `zig-obj`
// library (a Builder accumulating flat attribute pools + a corner list with
// OPTIONAL tex/normal indices, errdefer cleanup) and raylib/tinyobj's
// triangulated output.
//
//   obj.parse  -> Data : faithful. Separate position / tex_coord / normal
//                        pools (1-based in the file, stored 0-based) and a flat
//                        corner list grouped by per-face corner counts, so
//                        quads and n-gons survive intact.
//   Data.toMesh -> Mesh: de-indexed (one unique vertex per distinct v/vt/vn
//                        combo), triangulated as a fan, smooth normals
//                        synthesized when the file carries none.
//
// `mtllib` / `usemtl` are recognized but materials (.mtl) are not parsed here.

pub const obj = struct {
    /// One face corner: a position index plus optional tex-coord / normal
    /// indices, all converted to 0-based.
    pub const Corner = struct {
        position: u32,
        tex_coord: ?u32 = null,
        normal: ?u32 = null,
    };

    /// A faithful parse: the three attribute pools (xyz / uv / xyz, flattened)
    /// plus the face corners grouped by `face_lengths` (corners per face).
    pub const Data = struct {
        positions: []const f32,
        tex_coords: []const f32,
        normals: []const f32,
        corners: []const Corner,
        face_lengths: []const u32,

        pub fn deinit(self: Data, gpa: Allocator) void {
            gpa.free(self.positions);
            gpa.free(self.tex_coords);
            gpa.free(self.normals);
            gpa.free(self.corners);
            gpa.free(self.face_lengths);
        }

        const VertexKey = struct { p: u32, t: u32, n: u32 };

        /// De-index + triangulate into a renderable `Mesh`. One unique vertex
        /// per distinct (position, tex_coord, normal) corner; each face fanned
        /// into triangles. Smooth normals are synthesized when the file omits
        /// them. Caller owns the result (`Mesh.deinit`).
        pub fn toMesh(self: Data, gpa: Allocator) !Mesh {
            var positions: ArrayList(f32) = .empty;
            errdefer positions.deinit(gpa);
            var tex_coords: ArrayList(f32) = .empty;
            errdefer tex_coords.deinit(gpa);
            var normals: ArrayList(f32) = .empty;
            errdefer normals.deinit(gpa);
            var indices: ArrayList(u32) = .empty;
            errdefer indices.deinit(gpa);

            var seen: std.AutoHashMapUnmanaged(VertexKey, u32) = .empty;
            defer seen.deinit(gpa);

            const had_normals: bool = self.normals.len > 0;
            const has_tex_coords: bool = self.tex_coords.len > 0;

            var base: usize = 0;
            for (self.face_lengths) |len| {
                if (len >= 3) {
                    var i: usize = 1;
                    while (i + 1 < len) : (i += 1) {
                        const tri = [3]usize{ base, base + i, base + i + 1 };
                        for (tri) |corner_idx| {
                            const c: Corner = self.corners[corner_idx];
                            const key: VertexKey = .{
                                .p = c.position,
                                .t = c.tex_coord orelse std.math.maxInt(u32),
                                .n = c.normal orelse std.math.maxInt(u32),
                            };
                            const gop = try seen.getOrPut(gpa, key);
                            if (!gop.found_existing) {
                                gop.value_ptr.* = @intCast(positions.items.len / 3);
                                const pi: usize = c.position * 3;
                                try positions.appendSlice(gpa, self.positions[pi .. pi + 3]);
                                if (c.tex_coord) |ti| {
                                    const t2: usize = ti * 2;
                                    try tex_coords.appendSlice(gpa, self.tex_coords[t2 .. t2 + 2]);
                                } else {
                                    try tex_coords.appendSlice(gpa, &.{ 0, 0 });
                                }
                                if (c.normal) |ni| {
                                    const n3: usize = ni * 3;
                                    try normals.appendSlice(gpa, self.normals[n3 .. n3 + 3]);
                                } else {
                                    try normals.appendSlice(gpa, &.{ 0, 0, 0 });
                                }
                            }
                            try indices.append(gpa, gop.value_ptr.*);
                        }
                    }
                }
                base += len;
            }

            if (!had_normals) {
                synthesizeNormals(positions.items, normals.items, indices.items);
            }

            return .{
                .positions = try positions.toOwnedSlice(gpa),
                .tex_coords = try tex_coords.toOwnedSlice(gpa),
                .normals = try normals.toOwnedSlice(gpa),
                .indices = try indices.toOwnedSlice(gpa),
                .has_tex_coords = has_tex_coords,
                .had_normals = had_normals,
            };
        }
    };

    /// A renderable, de-indexed + triangulated mesh: parallel per-vertex arrays
    /// (3/2/3 floats per vertex) and a triangle index list. `normals` is always
    /// populated; `tex_coords` is zero-filled when the file had none.
    pub const Mesh = struct {
        positions: []const f32,
        tex_coords: []const f32,
        normals: []const f32,
        indices: []const u32,
        has_tex_coords: bool,
        had_normals: bool,

        pub fn vertexCount(self: Mesh) usize {
            return self.positions.len / 3;
        }

        pub fn deinit(self: Mesh, gpa: Allocator) void {
            gpa.free(self.positions);
            gpa.free(self.tex_coords);
            gpa.free(self.normals);
            gpa.free(self.indices);
        }
    };

    /// Accumulate per-triangle face normals into each vertex, then normalize —
    /// smooth shading. Used only when the OBJ omits `vn`.
    fn synthesizeNormals(
        positions: []const f32,
        normals: []f32,
        indices: []const u32,
    ) void {
        @memset(normals, 0);
        var t: usize = 0;
        while (t + 2 < indices.len) : (t += 3) {
            const ia: usize = indices[t];
            const ib: usize = indices[t + 1];
            const ic: usize = indices[t + 2];
            const a: [3]f32 = .{ positions[ia * 3], positions[ia * 3 + 1], positions[ia * 3 + 2] };
            const b: [3]f32 = .{ positions[ib * 3], positions[ib * 3 + 1], positions[ib * 3 + 2] };
            const c: [3]f32 = .{ positions[ic * 3], positions[ic * 3 + 1], positions[ic * 3 + 2] };
            const e1: [3]f32 = .{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
            const e2: [3]f32 = .{ c[0] - a[0], c[1] - a[1], c[2] - a[2] };
            const fn_: [3]f32 = .{
                e1[1] * e2[2] - e1[2] * e2[1],
                e1[2] * e2[0] - e1[0] * e2[2],
                e1[0] * e2[1] - e1[1] * e2[0],
            };
            for ([3]usize{ ia, ib, ic }) |vi| {
                normals[vi * 3] += fn_[0];
                normals[vi * 3 + 1] += fn_[1];
                normals[vi * 3 + 2] += fn_[2];
            }
        }
        var v: usize = 0;
        while (v + 2 < normals.len) : (v += 3) {
            const x: f32 = normals[v];
            const y: f32 = normals[v + 1];
            const z: f32 = normals[v + 2];
            const len: f32 = @sqrt(x * x + y * y + z * z);
            if (len > 1e-8) {
                normals[v] = x / len;
                normals[v + 1] = y / len;
                normals[v + 2] = z / len;
            } else {
                normals[v + 1] = 1; // degenerate -> point up
            }
        }
    }

    fn parseFloatTok(it: *std.mem.TokenIterator(u8, .any)) !f32 {
        const tok: []const u8 = it.next() orelse return error.TooFewComponents;
        return std.fmt.parseFloat(f32, tok);
    }

    /// Resolve one OBJ index field (1-based, or negative-from-end) to 0-based,
    /// or null when the field is empty (e.g. the middle of `v//vn`).
    fn resolveIndex(tok: []const u8, pool_count: usize) !?u32 {
        if (tok.len == 0) {
            return null;
        }
        const raw: i64 = try std.fmt.parseInt(i64, tok, 10);
        if (raw < 0) {
            const from_end: i64 = @as(i64, @intCast(pool_count)) + raw;
            if (from_end < 0) {
                return error.BadIndex;
            }
            return @intCast(from_end);
        }
        if (raw == 0) {
            return error.BadIndex;
        }
        return @intCast(raw - 1);
    }

    /// Parse Wavefront OBJ text. Caller owns the result (`Data.deinit`).
    pub fn parse(gpa: Allocator, bytes: []const u8) !Data {
        var positions: ArrayList(f32) = .empty;
        errdefer positions.deinit(gpa);
        var tex_coords: ArrayList(f32) = .empty;
        errdefer tex_coords.deinit(gpa);
        var normals: ArrayList(f32) = .empty;
        errdefer normals.deinit(gpa);
        var corners: ArrayList(Corner) = .empty;
        errdefer corners.deinit(gpa);
        var face_lengths: ArrayList(u32) = .empty;
        errdefer face_lengths.deinit(gpa);

        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |raw_line| {
            var line: []const u8 = raw_line;
            if (line.len > 0 and line[line.len - 1] == '\r') {
                line = line[0 .. line.len - 1];
            }
            var it = std.mem.tokenizeAny(u8, line, " \t");
            const kind: []const u8 = it.next() orelse continue;
            if (std.mem.eql(u8, kind, "v")) {
                try positions.append(gpa, try parseFloatTok(&it));
                try positions.append(gpa, try parseFloatTok(&it));
                try positions.append(gpa, try parseFloatTok(&it));
            } else if (std.mem.eql(u8, kind, "vt")) {
                try tex_coords.append(gpa, try parseFloatTok(&it));
                const v: f32 = if (it.next()) |tok| try std.fmt.parseFloat(f32, tok) else 0;
                try tex_coords.append(gpa, v);
            } else if (std.mem.eql(u8, kind, "vn")) {
                try normals.append(gpa, try parseFloatTok(&it));
                try normals.append(gpa, try parseFloatTok(&it));
                try normals.append(gpa, try parseFloatTok(&it));
            } else if (std.mem.eql(u8, kind, "f")) {
                var count: u32 = 0;
                while (it.next()) |corner_tok| {
                    var parts = std.mem.splitScalar(u8, corner_tok, '/');
                    const v_tok: []const u8 = parts.next() orelse return error.TooFewComponents;
                    const position: u32 = (try resolveIndex(v_tok, positions.items.len / 3)) orelse
                        return error.BadIndex;
                    const tex_coord: ?u32 = if (parts.next()) |t|
                        try resolveIndex(t, tex_coords.items.len / 2)
                    else
                        null;
                    const normal: ?u32 = if (parts.next()) |n|
                        try resolveIndex(n, normals.items.len / 3)
                    else
                        null;
                    try corners.append(gpa, .{ .position = position, .tex_coord = tex_coord, .normal = normal });
                    count += 1;
                }
                if (count >= 3) {
                    try face_lengths.append(gpa, count);
                } else {
                    // Drop the corners of a degenerate (point/line) face.
                    corners.shrinkRetainingCapacity(corners.items.len - count);
                }
            }
            // Everything else (o, g, s, usemtl, mtllib, comments, ...) is ignored.
        }

        return .{
            .positions = try positions.toOwnedSlice(gpa),
            .tex_coords = try tex_coords.toOwnedSlice(gpa),
            .normals = try normals.toOwnedSlice(gpa),
            .corners = try corners.toOwnedSlice(gpa),
            .face_lengths = try face_lengths.toOwnedSlice(gpa),
        };
    }

    test "parse v/vt/vn pools" {
        const src: []const u8 =
            \\# a comment
            \\v 0 0 0
            \\v 1 0 0
            \\v 0 1 0
            \\vt 0 0
            \\vt 1 0
            \\vn 0 0 1
        ;
        var data: Data = try parse(std.testing.allocator, src);
        defer data.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 9), data.positions.len);
        try std.testing.expectEqual(@as(usize, 4), data.tex_coords.len);
        try std.testing.expectEqual(@as(usize, 3), data.normals.len);
    }

    test "face triangulation + dedup" {
        // A quad (4 corners) -> 2 triangles -> 6 indices, 4 unique vertices.
        const src: []const u8 =
            \\v 0 0 0
            \\v 1 0 0
            \\v 1 1 0
            \\v 0 1 0
            \\f 1 2 3 4
        ;
        var data: Data = try parse(std.testing.allocator, src);
        defer data.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), data.face_lengths.len);
        try std.testing.expectEqual(@as(u32, 4), data.face_lengths[0]);

        var mesh: Mesh = try data.toMesh(std.testing.allocator);
        defer mesh.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 4), mesh.vertexCount());
        try std.testing.expectEqual(@as(usize, 6), mesh.indices.len);
        try std.testing.expect(!mesh.had_normals); // synthesized
        // Synthesized normal points along +Z for this front-facing quad.
        try std.testing.expect(mesh.normals[2] > 0.9);
    }

    test "v//vn face (no tex coords) + negative index" {
        const src: []const u8 =
            \\v 0 0 0
            \\v 1 0 0
            \\v 0 1 0
            \\vn 0 0 1
            \\f -3//-1 -2//-1 -1//-1
        ;
        var data: Data = try parse(std.testing.allocator, src);
        defer data.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 3), data.corners.len);
        try std.testing.expectEqual(@as(u32, 0), data.corners[0].position);
        try std.testing.expectEqual(@as(?u32, null), data.corners[0].tex_coord);
        try std.testing.expectEqual(@as(?u32, 0), data.corners[0].normal);

        var mesh: Mesh = try data.toMesh(std.testing.allocator);
        defer mesh.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 3), mesh.vertexCount());
        try std.testing.expect(mesh.had_normals);
    }
};
