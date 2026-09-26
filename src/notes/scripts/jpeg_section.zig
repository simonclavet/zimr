// ============================================================================
// SECTION - jpeg (baseline 8-bit sequential)
// ============================================================================
//
// What this decodes: baseline JPEG (SOF0), 8-bit precision, Huffman entropy
// coding.  Grayscale (1 component) or YCbCr (3 components) with chroma
// sampling factors up to 2x2 on luma - covers 4:4:4, 4:4:0, 4:2:2, 4:2:0
// which is ~every consumer JPEG.  Output is always RGBA8 to match png.Image
// so callers don't notice which codec ran.
//
// What this does NOT do: progressive JPEG (SOF2), arithmetic coding (SOF9+),
// 12-bit precision (SOF1), lossless modes (SOF3, SOF7), hierarchical (SOF5,
// SOF6), CMYK, EXIF/ICC handling.  Hitting any of these returns a specific
// Error.Unsupported* - callers fall back to "warn + leave untextured" rather
// than aborting whole loads.  We surfaced that fallback path while debugging
// DamagedHelmet's JPEG textures; this section's job is to remove the need
// for the fallback in the common case.
//
// Pipeline, top to bottom:
//   1. marker scan      - walk FF-prefixed markers, dispatch on type
//   2. segment parse    - DQT (quant), DHT (Huffman), SOF0 (frame), SOS (scan)
//   3. entropy decode   - Huffman + run-length-zero + inline dequantize, per
//                         MCU block
//   4. inverse DCT      - Loeffler-style fixed-point, 8x8 frequency -> spatial
//   5. chroma upsample  - nearest-neighbor Cb/Cr to Y resolution
//   6. YCbCr -> RGB      - fixed-point 16.16 matrix; clamp; alpha=255
//
// References studied (not copied):
//   - stb_image.h JPEG decoder (raylib's external/, lines 1914-4080) - single
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
    const Allocator = std.mem.Allocator;

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
    // cluster near linear index 0 after zig-zagging - which means the
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
    // 9 bits is the sweet spot per stb_image - 512 entries (small) but covers
    // ~99% of real-world codes (big speedup).
    const fast_bits: u5 = 9;
    const fast_size: usize = 1 << fast_bits;

    // One Huffman table per (class, table_id) - JPEG allows up to 4 DC + 4 AC
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
        // maxcode[L] defaults to "impossible" so unused lengths short-circuit.
        mincode: [17]u32 = @splat(0),
        maxcode: [18]u32 = @splat(0xFFFFFFFF),
        valptr: [17]usize = @splat(0),
        symbols: [256]u8 = @splat(0),
    };

    // Component info from SOF0.  Up to 4 are allowed by spec; we accept 1
    // (grayscale) or 3 (YCbCr).  CMYK (4 components) returns Unsupported.
    const Component = struct {
        id: u8, // glyph id from SOF0 - usually 1=Y, 2=Cb, 3=Cr but not always
        h: u8, // horizontal sampling factor (1..4 per spec; we only do 1..2)
        v: u8, // vertical sampling factor (same)
        quant_id: u8, // which quant table index to dequantize with
        dc_huff_id: u8 = 0, // DC Huffman table index (set later from SOS)
        ac_huff_id: u8 = 0, // AC Huffman table index (set later from SOS)
        // Decoded sample buffer, sized to the component's actual resolution
        // (image_w / max_h * h, rounded up to 8x8 blocks).  Owned by the
        // decoder, freed at the end.
        pixels: []u8 = &.{},
        stride: usize = 0, // row stride in pixels - may exceed actual width
        blocks_w: usize = 0, // number of 8x8 blocks horizontally
        blocks_h: usize = 0, // number of 8x8 blocks vertically
    };

    // Sniff a JPEG magic by SOI marker. Used as a defense-in-depth check when
    // mime_type isn't set - see drawing.zig materialsFromGltf.
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
                // No codes of this length - make maxcode impossible so the
                // slow-path walk skips this length entirely.
                out.maxcode[length] = 0xFFFFFFFF;
            } else {
                // Largest code at this length is mincode + count - 1
                out.maxcode[length] = code + count - 1;
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
        // mincode/maxcode for length 17 is the sentinel - we initialize
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
    //   2. Markers: a 0xFF followed by NON-zero is a marker - usually
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
                        // Stuffing byte - the real data is just 0xFF.
                        // Push 0xFF onto the accumulator and continue.
                        self.acc |= @as(u32, 0xFF) << @intCast(24 - self.bits);
                        self.bits += 8;
                    } else {
                        // It's a marker - stop refilling.  Common ones are
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

        // JPEG "extend" - convert an N-bit unsigned magnitude into a signed
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
                // Negative branch - extend with leading 1s and the +1 offset
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
        var length: u5 = 1;
        while (length <= 16) : (length += 1) {
            const bit: u32 = try br.readBits(1);
            code = (code << 1) | bit;
            if (code <= t.maxcode[length]) {
                // Found it - symbol index is valptr[length] + (code - mincode[length])
                const idx: usize = t.valptr[length] + @as(usize, @intCast(code - t.mincode[length]));
                return t.symbols[idx];
            }
        }
        return Error.InvalidHuffmanCode;
    }

    fn huffDecode(br: *BitReader, t: *const HuffmanTable) Error!u8 {
        br.refill();
        // Try the 9-bit fast lookup first.  If we have fewer than 9 bits
        // (near EOF), the lookup might still hit a short code - peek a partial
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
    // (not zig-zag) order.  Updates prev_dc in place - DC coefficients are
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
    // IDCT - Loeffler-style fixed-point inverse DCT.  Operates in place on a
    // [64]i32 block.  Two passes: columns first, then rows.  Output is signed
    // i32 samples; caller adds 128 and clamps for u8 output.
    // ------------------------------------------------------------------------
    //
    // The Loeffler 8-point IDCT decomposes the 8x8 DCT into a small graph of
    // multiplications and rotations.  The constants below come from the
    // standard form (12 fractional bits of precision).  We use a 1-D function
    // and call it twice - once per column, once per row - like the textbook.
    // After the first pass we have an intermediate scaled by 2^10 (the 1024
    // bias absorbs the rounding).  After the second pass we scale by 2^17
    // (output bits) and round to integer samples.
    //
    // I wrote the constants and operations out by hand from the Loeffler '89
    // paper rather than copying from zigimg or stb_image to make sure I
    // understand them.  Cross-checked the numeric output on a few sample
    // blocks against zigimg's IDCT - agreement to within 1 LSB which is the
    // expected rounding-equivalence ceiling.
    fn f2f(comptime x: f32) i32 {
        // round(x * 4096) - 12 fractional bits
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
    // This function is intentionally LONG - Carmack-style flat code with
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

        // Per-decoder state, all local - no struct fields, no globals.
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
        // hit SOS - at that point the entropy stream begins and we switch to
        // bit-level reading.
        var cursor: usize = 2;
        var sof_seen: bool = false;
        var sos_seen: bool = false;

        scan: while (cursor + 1 < bytes.len) {
            // Every segment starts with FF + marker_byte.  Some encoders
            // emit padding FFs (FF FF FF...) - skip them.
            while (cursor < bytes.len and bytes[cursor] == 0xFF) {
                cursor += 1;
            }
            if (cursor >= bytes.len) {
                return Error.UnexpectedEnd;
            }
            const marker: u8 = bytes[cursor];
            cursor += 1;

            // Markers without a following segment payload: SOI (already past),
            // EOI, restart markers (RST0..RST7 = D0..D7), TEM (01).
            if (marker == 0xD9) {
                // EOI - end of image, we're done (this happens after SOS
                // entropy decode is over, but defensively handle it here too)
                break :scan;
            }
            if (marker >= 0xD0 and marker <= 0xD7) {
                // Stray restart marker outside a scan - shouldn't happen but
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
                // SOF0 - baseline DCT.  This is the only frame mode we accept.
                0xC0 => {
                    if (sof_seen) {
                        return Error.InvalidMarker;
                    }
                    sof_seen = true;
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
                    }
                },

                // SOF1, SOF2, SOF3, SOF5-7, SOF9-15 - all unsupported modes
                0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF => {
                    return Error.UnsupportedMode;
                },

                // DQT - Define Quantization Tables.  Can pack multiple tables
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
                            // Stored in zig-zag order - un-zigzag while reading
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

                // DHT - Define Huffman Tables.  Same pack-multiple convention.
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

                // DRI - Define Restart Interval.  After this many MCUs, the
                // entropy stream is reset (DC predictors zeroed) and a restart
                // marker is inserted.  Most JPEGs don't use restart; in those
                // it stays 0.
                0xDD => {
                    if (payload.len != 2) {
                        return Error.InvalidMarker;
                    }
                    restart_interval = (@as(u32, payload[0]) << 8) | payload[1];
                },

                // SOS - Start Of Scan.  The entropy stream starts immediately
                // after the SOS segment header.  We process it inline here
                // rather than continuing the marker loop.
                0xDA => {
                    if (!sof_seen) {
                        return Error.InvalidScan;
                    }
                    sos_seen = true;
                    if (payload.len < 1) {
                        return Error.InvalidScan;
                    }
                    const ns: usize = payload[0];
                    if (ns != num_components) {
                        // Per-component scans (used in progressive) are
                        // unsupported; baseline interleaves all components
                        return Error.UnsupportedMode;
                    }
                    if (payload.len < 1 + ns * 2 + 3) {
                        return Error.InvalidScan;
                    }
                    // Two bytes per component: id, then (dc_id<<4 | ac_id)
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
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            return Error.InvalidScan;
                        }
                    }
                    // The trailing 3 bytes (Ss, Se, Ah_Al) describe the
                    // spectral selection for progressive scans.  Baseline
                    // requires Ss=0, Se=63, Ah=Al=0.  We accept anything but
                    // ignore - non-conforming baseline encoders sometimes
                    // emit junk here.

                    // Set up the bit reader on the entropy-coded stream that
                    // starts at `cursor`.
                    var br: BitReader = .{ .bytes = bytes, .cursor = cursor };

                    // MCU loop.  An MCU is one block per component if not
                    // subsampled, or sum(h*v) blocks across all components
                    // if subsampled (e.g. 4:2:0 has 4 Y + 1 Cb + 1 Cr = 6
                    // blocks per MCU).
                    const mcus_w: usize = (@as(usize, width) + (max_h * 8) - 1) / (max_h * 8);
                    const mcus_h: usize = (@as(usize, height) + (max_v * 8) - 1) / (max_v * 8);
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
                            if (restart_interval != 0 and mcu_count % restart_interval == 0 and
                                mcu_count != mcus_w * mcus_h)
                            {
                                // Discard partial byte to byte-align
                                br.bits = 0;
                                br.acc = 0;
                                if (br.marker) |m| {
                                    if (m != rst_expected) {
                                        // Out-of-order or missing restart
                                        // marker - be lenient and just clear
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
                    // here - JPEGs after baseline SOS are almost always just
                    // EOI.  Break out of the scan loop and finalize.
                    break :scan;
                },

                // Application markers (APP0..APP15), comment (COM), DNL - skip
                0xE0...0xEF, 0xFE, 0xDC => {
                    // Length-prefixed; already consumed by `cursor += seg_len`
                },

                else => {
                    // Unknown marker - be lenient and skip it.  Real-world
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
            // YCbCr -> RGB.  Chroma channels may be subsampled - we replicate
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

        // Components' pixel buffers can be freed now - output is built.
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
        try std.testing.expectError(Error.UnexpectedEnd, decode(ta, &.{}));
    }

    test "jpeg: rejects non-jpeg" {
        const ta: Allocator = std.testing.allocator;
        const bad: []const u8 = "this is not a jpeg at all";
        try std.testing.expectError(Error.InvalidSignature, decode(ta, bad));
    }

    test "jpeg: isJpeg sniffs SOI correctly" {
        try std.testing.expect(jpeg.isJpeg(&.{ 0xFF, 0xD8, 0xFF, 0xE0 }));
        try std.testing.expect(!jpeg.isJpeg(&.{ 0xFF, 0xD8 })); // too short
        try std.testing.expect(!jpeg.isJpeg(&.{ 0x89, 0x50, 0x4E })); // PNG
    }
};
