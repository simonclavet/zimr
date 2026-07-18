// src/raster_pixel.zig
// Pixel format definitions + the comptime-specialized read/write
// codecs used by the rasterizer's framebuffer access paths.
// `PixelFormat` and `PixelAlpha` are both defined here - they're
// pixel-format storage descriptors, conceptually pixel-module
// concerns.  raster.zig re-exports them so external callers can say
// either `raster.PixelFormat` (alias) or `raster.pixel.PixelFormat`
// (direct namespace) - both work.

const std = @import("std");
const expect = std.testing.expect;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;
const expectEqual = std.testing.expectEqual;
// S4: the half-float pair lives in zimrmath; these are re-exports.
const zm = @import("zm");
const floatToHalf = zm.floatToHalf;
const halfToFloat = zm.halfToFloat;
const float = zm.float;
const nan = zm.nan;

// ============================================================================
// Pixel format tags
// ============================================================================

/// Internal pixel-format tag.  Groups together the channel count,
/// per-channel size, and per-channel encoding into one identity.
/// Each row in the format-properties tables is keyed by this enum.
/// Densely numbered so the enum doubles as an array index.  Donor
/// uses `int` enum-as-index pattern; we use `u8` because there are
/// fewer than 256 formats and small integers index faster.
pub const PixelFormat = enum(u8) {
    unknown = 0,
    color_grayscale,
    color_grayalpha,
    color_r3g3b2,
    color_r5g6b5,
    color_r8g8b8,
    color_r5g5b5a1,
    color_r4g4b4a4,
    color_r8g8b8a8,
    color_r32,
    color_r32g32b32,
    color_r32g32b32a32,
    color_r16,
    color_r16g16b16,
    color_r16g16b16a16,
    depth_d8,
    depth_d16,
    depth_d32,

    /// Sentinel - useful for sizing a `[count]T` lookup table.  Not
    /// a real format value.
    pub const count = @typeInfo(@This()).@"enum".field_names.len;
};

/// How alpha is stored in a pixel format.  Used by the rasterizer
/// to fast-path the texture-sampling branch: when sampling a
/// `none`-alpha texture, the alpha-saturate test becomes a no-op
/// and we skip the alpha blend lookup.
pub const PixelAlpha = enum(u8) {
    /// Format has no alpha channel.  Result alpha is always 1.
    none = 0,
    /// Format has 1-bit alpha (R5G5B5A1) - alpha is either 0 or 1.
    /// Saves a multiply in the blend path.
    bin,
    /// Format has multi-bit alpha (RGBA8, RGBA4, RGBA16F, ...)
    /// the general case requiring the full blend recipe.
    yes,
};

// ============================================================================
// Format property tables
// ============================================================================
// Two parallel `EnumArray(PixelFormat, T)` tables - one for byte-size,
// one for alpha-storage classification.  `EnumArray` enforces the
// "exactly one slot per enumerator" invariant statically; reads use
// `.get(fmt)` so callers never reach for `@intFromEnum` on the index.
// The donor (`raster.h`) used C99 designated initializers
// (`[ENUM_VALUE] = ...`) to make the table self-keying; we get the
// same guarantee from `EnumArray` plus type safety on the keys.

/// Bytes per pixel for each format.  Donor: `SW_PIXELFORMAT_SIZE`.
pub const pixel_format_size: std.enums.EnumArray(PixelFormat, u8) = blk: {
    var t: std.enums.EnumArray(PixelFormat, u8) = .initFill(0);
    t.set(.color_grayscale, 1);
    t.set(.color_grayalpha, 2);
    t.set(.color_r3g3b2, 1);
    t.set(.color_r5g6b5, 2);
    t.set(.color_r8g8b8, 3);
    t.set(.color_r5g5b5a1, 2);
    t.set(.color_r4g4b4a4, 2);
    t.set(.color_r8g8b8a8, 4);
    t.set(.color_r32, 4);
    t.set(.color_r32g32b32, 12);
    t.set(.color_r32g32b32a32, 16);
    t.set(.color_r16, 2);
    t.set(.color_r16g16b16, 6);
    t.set(.color_r16g16b16a16, 8);
    t.set(.depth_d8, 1);
    t.set(.depth_d16, 2);
    t.set(.depth_d32, 4);
    break :blk t;
};

/// Whether each pixel format has an alpha channel and how it's stored.
/// Donor: `SW_PIXELFORMAT_ALPHA`.  Used by the rasterizer as a fast-
/// path discriminator: `none` skips the alpha-blend math entirely;
/// `bin` (binary alpha - 0 or 255, e.g. R5G5B5A1) can use a cheaper
/// test-and-skip; `yes` is full alpha blending.
pub const pixel_format_alpha: std.enums.EnumArray(PixelFormat, PixelAlpha) = blk: {
    var t: std.enums.EnumArray(PixelFormat, PixelAlpha) = .initFill(.none);
    t.set(.color_grayalpha, .yes);
    t.set(.color_r5g5b5a1, .bin);
    t.set(.color_r4g4b4a4, .yes);
    t.set(.color_r8g8b8a8, .yes);
    t.set(.color_r32g32b32a32, .yes);
    t.set(.color_r16g16b16a16, .yes);
    break :blk t;
};

// ============================================================================
// Read / write codecs (formerly `pub const pixel = struct { ... }`)
// ============================================================================
// Each color `PixelFormat` knows how to:
//   - read a pixel at offset N → 4 bytes RGBA  (read_color8)
//   - read a pixel at offset N → 4 floats RGBA (read_color, normalized 0..1)
//   - write a pixel at offset N from 4 bytes   (write_color8)
//   - write a pixel at offset N from 4 floats  (write_color, expects 0..1)
// Each depth `PixelFormat` has analogous (read_depth, write_depth) f32-typed
// paths.  The float input/output is the rasterizer's normalized-depth
// representation, common across all depth formats.
// Donor: sw_pixel_read_color8_*, sw_pixel_read_color_*,
// sw_pixel_write_color8_*, sw_pixel_write_color_* (lines 1811-2401),
// plus sw_luminance / sw_luminance8 / sw_color8_to_color / sw_color_to_color8
// / sw_expand_NtoB / sw_compress_8toN / sw_half_to_float / sw_float_to_half
// helpers.
// **Alignment**.  Multi-byte format readers/writers (R5G6B5, R32, R16,
// etc.) use `*align(1) const T` casts - typed access with explicit
// 1-byte alignment.  This works on byte-aligned source buffers (the
// framebuffer's depth pixels are `gpa.alloc(u8, ...)`, alignment 1)
// because the compiler emits unaligned loads/stores instead of
// asserting alignment.  All target platforms (x86_64, wasm32, ARM64)
// support unaligned multi-byte loads at modest or zero extra cost.
// **SIMD**.  The donor has SSE2 / SSE4.1 / NEON / RVV variants of
// `sw_color_to_color8` (line 1523).  We ship the scalar fallback only.
// If profiling later shows this is hot, we can add @Vector(4, f32)
// vectorization to taste - Zig's portable vectors will compile to the
// platform's native instructions automatically.

/// Function pointer types for the dispatch tables.  Each wraps
/// the corresponding comptime-specialized fn (`readColor8`,
/// `readColor`, etc.), monomorphized for one `PixelFormat`.  The
/// table-pointed-to fns are out-parameter style (writes through
/// `out`) even though the underlying comptime fns return by
/// value - the table's signature is fixed across all formats, so
/// we use the convention that fits both byte- and float-typed
/// outputs without a Result-type sum.
pub const ReadColor8Fn = *const fn (out: *[4]u8, src: []const u8, index: u32) void;
pub const ReadColorFn = *const fn (out: *[4]f32, src: []const u8, index: u32) void;
pub const WriteColor8Fn = *const fn (dst: []u8, color: *const [4]u8, index: u32) void;
pub const WriteColorFn = *const fn (dst: []u8, color: *const [4]f32, index: u32) void;
pub const ReadDepthFn = *const fn (src: []const u8, index: u32) f32;
pub const WriteDepthFn = *const fn (dst: []u8, depth: f32, index: u32) void;

/// 1.0 / 255.0 - recurring constant for byte-to-normalized
/// conversions.  Donor: `SW_INV_255`.
pub const inv_255: f32 = 1.0 / 255.0;

/// RGB → 8-bit luminance, BT.601 weights in integer form
/// (77, 150, 29 / 256).  Donor: `sw_luminance8`.  Renamed from
/// `luminance8` earlier - the new name says what the input
/// is, not what it isn't.
pub fn luminanceFromBytes(color: *const [4]u8) u8 {
    const sum: u32 = @as(u32, color[0]) * 77 + @as(u32, color[1]) * 150 + @as(u32, color[2]) * 29;
    return @intCast(sum >> 8);
}

/// RGB → 0..1 luminance, BT.601 weights.  Donor: `sw_luminance`.
/// Renamed from `luminance`.
pub fn luminanceFromFloats(color: *const [4]f32) f32 {
    return color[0] * 0.299 + color[1] * 0.587 + color[2] * 0.114;
}

/// Convert 4 RGBA bytes to normalized RGBA floats.  Donor:
/// `sw_color8_to_color`.  Renamed from `color8ToColor`.
pub fn byteColorToFloats(out: *[4]f32, src: *const [4]u8) void {
    out[0] = float(src[0]) * inv_255;
    out[1] = float(src[1]) * inv_255;
    out[2] = float(src[2]) * inv_255;
    out[3] = float(src[3]) * inv_255;
}

/// Convert 4 RGBA floats (assumed in 0..1) to 4 RGBA bytes.
/// Donor: `sw_color_to_color8` (we ship the scalar fallback
/// only - the donor's SIMD paths are out of scope for this port).
/// Truncation matches the donor's `(uint8_t)(c*255.0f)`.  Renamed
/// from `colorToColor8`.
pub fn floatColorToBytes(out: *[4]u8, src: *const [4]f32) void {
    out[0] = @trunc(src[0] * 255.0);
    out[1] = @trunc(src[1] * 255.0);
    out[2] = @trunc(src[2] * 255.0);
    out[3] = @trunc(src[3] * 255.0);
}

// ---- Channel bit-width expand / compress
// Bit-replicate expansion: an N-bit integer in `[0, 2^N − 1]`
// maps linearly onto `[0, 255]` without rounding.  The 1/2/4 cases
// use the closed forms (multiply, shift-or) that are cheaper than
// the general `(v << (8 - N)) | (v >> (2N - 8))` recipe; the 3/5/6
// cases use the recipe.  Compression is just `>> (8 - N)`.
// Both fns are comptime-parameterized - one body, one switch arm
// per N.  Donor: `sw_expand_NtoB` / `sw_compress_8toN` (lines
// 1464-1476), which were six separate fns each.

/// Expand an N-bit value (in the low N bits of `v`) to a full
/// 8-bit value covering `[0, 255]`.  `n` is comptime so the
/// switch collapses to one branch per call site.
pub fn expandToByte(comptime n: u3, v: u8) u8 {
    return switch (n) {
        1 => if (v != 0) 255 else 0,
        2 => v *% 85, // 2-bit max 3, 3*85 = 255
        3 => (v << 5) | (v << 2) | (v >> 1),
        4 => (v << 4) | v,
        5 => (v << 3) | (v >> 2),
        6 => (v << 2) | (v >> 4),
        else => @compileError("expandToByte: only widths 1..6 are supported"),
    };
}

/// Truncate an 8-bit value to its top N bits.  Inverse of
/// `expandToByte` (lossy).
pub fn compressByteTo(comptime n: u3, v: u8) u8 {
    return switch (n) {
        1 => v >> 7,
        2 => v >> 6,
        3 => v >> 5,
        4 => v >> 4,
        5 => v >> 3,
        6 => v >> 2,
        else => @compileError("compressByteTo: only widths 1..6 are supported"),
    };
}

// ---- IEEE 754 half-float (binary16) ↔ float (binary32)
// Donor: `sw_float_to_half_ui` / `sw_half_to_float_ui` (lines
// 1412-1462).  We do the bit-fiddling entirely in `u32` - the
// donor uses signed `int32_t` for one intermediate but the
// magnitude bounds are tight enough that unsigned arithmetic
// works without overflow (and avoids the `@bitCast(i32 ↔ u32)`
// dance Zig would otherwise force).
// Behavior matches the donor exactly:
//   - Subnormals (and inputs whose magnitude is too small to
//     represent normalized) flush to zero.
//   - Overflow saturates to ±infinity.
//   - Any NaN input becomes a quiet NaN (0x7e00).

pub fn floatToHalfBits(ui: u32) u16 {
    const s: u32 = (ui >> 16) & 0x8000;
    const em: u32 = ui & 0x7fffffff;

    const h: u32 = blk: {
        // NaN → qNaN.  Checked first: the overflow branch would
        // also fire (em >= 143<<23), so the NaN check overrides.
        if (em > (255 << 23)) {
            break :blk 0x7e00;
        }
        // Overflow → ±infinity.
        if (em >= (143 << 23)) {
            break :blk 0x7c00;
        }
        // Underflow / subnormal → zero.
        if (em < (113 << 23)) {
            break :blk 0;
        }
        // Normal: bias exponent (127 → 15, so subtract 112) and
        // round-to-nearest by adding 1 << 12 before the >> 13.
        break :blk (em - (112 << 23) + (1 << 12)) >> 13;
    };

    return @truncate(s | h);
}

pub fn halfToFloatBits(h: u16) u32 {
    const s: u32 = @as(u32, h & 0x8000) << 16;
    const em: u32 = h & 0x7fff;

    // Bias exponent back to f32 range and pad mantissa with zeros.
    var r: u32 = (em + (112 << 10)) << 13;
    // Subnormal half-float → flush to zero.
    if (em < (1 << 10)) {
        r = 0;
    }
    // Half-infinity / half-NaN: bump exponent to f32 inf/NaN by
    // adding the bias once more (NaN payload preserved as a
    // by-product of unifying the inf/NaN cases).
    if (em >= (31 << 10)) {
        r += (112 << 23);
    }

    return s | r;
}

/// Predicate: is `fmt` a color format (i.e., `read_color8` / etc.
/// know how to read or write it)?  Used by the comptime dispatch-
/// table builders to pick the slots to populate.
pub fn isColorFormat(fmt: PixelFormat) bool {
    return switch (fmt) {
        .unknown, .depth_d8, .depth_d16, .depth_d32 => false,
        else => true,
    };
}

/// Predicate: is `fmt` a depth format?
pub fn isDepthFormat(fmt: PixelFormat) bool {
    return switch (fmt) {
        .depth_d8, .depth_d16, .depth_d32 => true,
        else => false,
    };
}

// ---- Color readers (byte output)
// One comptime-specialized fn per output type.  The compiler
// monomorphizes each call site into the format-specific arm
// identical machine code to the 14 separate fns we used to ship,
// single source of truth for the format encodings.

/// Read one pixel from `src` at index `index` and return RGBA bytes.
/// `fmt` is comptime; the switch collapses to one arm per call site.
/// Calling with a non-color format is a compile error.
pub fn readColor8(
    comptime fmt: PixelFormat,
    src: []const u8,
    index: u32,
) [4]u8 {
    return switch (fmt) {
        .color_grayscale => blk: {
            const g: u8 = src[index];
            break :blk .{ g, g, g, 255 };
        },
        .color_grayalpha => blk: {
            const o: u32 = index * 2;
            const g: u8 = src[o];
            const a: u8 = src[o + 1];
            break :blk .{ g, g, g, a };
        },
        .color_r3g3b2 => blk: {
            const p: u8 = src[index];
            break :blk .{
                expandToByte(3, (p >> 5) & 0x07),
                expandToByte(3, (p >> 2) & 0x07),
                expandToByte(2, p & 0x03),
                255,
            };
        },
        .color_r5g6b5 => blk: {
            const ptr: *align(1) const u16 = @ptrCast(&src[index * 2]);
            const p: u16 = ptr.*;
            break :blk .{
                expandToByte(5, @truncate((p >> 11) & 0x1F)),
                expandToByte(6, @truncate((p >> 5) & 0x3F)),
                expandToByte(5, @truncate(p & 0x1F)),
                255,
            };
        },
        .color_r8g8b8 => blk: {
            const o: u32 = index * 3;
            break :blk .{ src[o], src[o + 1], src[o + 2], 255 };
        },
        .color_r5g5b5a1 => blk: {
            const ptr: *align(1) const u16 = @ptrCast(&src[index * 2]);
            const p: u16 = ptr.*;
            break :blk .{
                expandToByte(5, @truncate((p >> 11) & 0x1F)),
                expandToByte(5, @truncate((p >> 6) & 0x1F)),
                expandToByte(5, @truncate((p >> 1) & 0x1F)),
                expandToByte(1, @truncate(p & 0x01)),
            };
        },
        .color_r4g4b4a4 => blk: {
            const ptr: *align(1) const u16 = @ptrCast(&src[index * 2]);
            const p: u16 = ptr.*;
            break :blk .{
                expandToByte(4, @truncate((p >> 12) & 0x0F)),
                expandToByte(4, @truncate((p >> 8) & 0x0F)),
                expandToByte(4, @truncate((p >> 4) & 0x0F)),
                expandToByte(4, @truncate(p & 0x0F)),
            };
        },
        .color_r8g8b8a8 => blk: {
            const o: u32 = index * 4;
            break :blk .{ src[o], src[o + 1], src[o + 2], src[o + 3] };
        },
        .color_r32 => blk: {
            const ptr: *align(1) const f32 = @ptrCast(&src[index * 4]);
            const g: u8 = @trunc(ptr.* * 255.0);
            break :blk .{ g, g, g, 255 };
        },
        .color_r32g32b32 => blk: {
            const ptr: *align(1) const [3]f32 = @ptrCast(&src[index * 12]);
            break :blk .{
                @trunc(ptr[0] * 255.0),
                @trunc(ptr[1] * 255.0),
                @trunc(ptr[2] * 255.0),
                255,
            };
        },
        .color_r32g32b32a32 => blk: {
            const ptr: *align(1) const [4]f32 = @ptrCast(&src[index * 16]);
            break :blk .{
                @trunc(ptr[0] * 255.0),
                @trunc(ptr[1] * 255.0),
                @trunc(ptr[2] * 255.0),
                @trunc(ptr[3] * 255.0),
            };
        },
        .color_r16 => blk: {
            const ptr: *align(1) const u16 = @ptrCast(&src[index * 2]);
            const g: u8 = @trunc(halfToFloat(ptr.*) * 255.0);
            break :blk .{ g, g, g, 255 };
        },
        .color_r16g16b16 => blk: {
            const ptr: *align(1) const [3]u16 = @ptrCast(&src[index * 6]);
            break :blk .{
                @trunc(halfToFloat(ptr[0]) * 255.0),
                @trunc(halfToFloat(ptr[1]) * 255.0),
                @trunc(halfToFloat(ptr[2]) * 255.0),
                255,
            };
        },
        .color_r16g16b16a16 => blk: {
            const ptr: *align(1) const [4]u16 = @ptrCast(&src[index * 8]);
            break :blk .{
                @trunc(halfToFloat(ptr[0]) * 255.0),
                @trunc(halfToFloat(ptr[1]) * 255.0),
                @trunc(halfToFloat(ptr[2]) * 255.0),
                @trunc(halfToFloat(ptr[3]) * 255.0),
            };
        },
        .unknown, .depth_d8, .depth_d16, .depth_d32 => @compileError(
            "readColor8: " ++ @tagName(fmt) ++ " is not a color format",
        ),
    };
}

/// Read one pixel from `src` at index `index` and return RGBA floats
/// in `[0, 1]`.  Compile error for non-color formats.
pub fn readColor(
    comptime fmt: PixelFormat,
    src: []const u8,
    index: u32,
) [4]f32 {
    return switch (fmt) {
        .color_grayscale => blk: {
            const g: f32 = float(src[index]) * inv_255;
            break :blk .{ g, g, g, 1.0 };
        },
        .color_grayalpha => blk: {
            const o: u32 = index * 2;
            const g: f32 = float(src[o]) * inv_255;
            const a: f32 = float(src[o + 1]) * inv_255;
            break :blk .{ g, g, g, a };
        },
        // Packed-bitfield float readers delegate to the byte
        // readers and then normalize.  Donor structures the family
        // the same way.
        .color_r3g3b2,
        .color_r5g6b5,
        .color_r8g8b8,
        .color_r5g5b5a1,
        .color_r4g4b4a4,
        => blk: {
            const rgba8: [4]u8 = readColor8(fmt, src, index);
            var out: [4]f32 = undefined;
            byteColorToFloats(&out, &rgba8);
            break :blk out;
        },
        .color_r8g8b8a8 => blk: {
            const o: u32 = index * 4;
            break :blk .{
                float(src[o]) * inv_255,
                float(src[o + 1]) * inv_255,
                float(src[o + 2]) * inv_255,
                float(src[o + 3]) * inv_255,
            };
        },
        // Float-channel formats: pass through the f32s directly,
        // no multiplication.  Single-channel formats replicate to RGB.
        .color_r32 => blk: {
            const ptr: *align(1) const f32 = @ptrCast(&src[index * 4]);
            const v: f32 = ptr.*;
            break :blk .{ v, v, v, 1.0 };
        },
        .color_r32g32b32 => blk: {
            const ptr: *align(1) const [3]f32 = @ptrCast(&src[index * 12]);
            break :blk .{ ptr[0], ptr[1], ptr[2], 1.0 };
        },
        .color_r32g32b32a32 => blk: {
            const ptr: *align(1) const [4]f32 = @ptrCast(&src[index * 16]);
            break :blk .{ ptr[0], ptr[1], ptr[2], ptr[3] };
        },
        .color_r16 => blk: {
            const ptr: *align(1) const u16 = @ptrCast(&src[index * 2]);
            const v: f32 = halfToFloat(ptr.*);
            break :blk .{ v, v, v, 1.0 };
        },
        .color_r16g16b16 => blk: {
            const ptr: *align(1) const [3]u16 = @ptrCast(&src[index * 6]);
            break :blk .{
                halfToFloat(ptr[0]),
                halfToFloat(ptr[1]),
                halfToFloat(ptr[2]),
                1.0,
            };
        },
        .color_r16g16b16a16 => blk: {
            const ptr: *align(1) const [4]u16 = @ptrCast(&src[index * 8]);
            break :blk .{
                halfToFloat(ptr[0]),
                halfToFloat(ptr[1]),
                halfToFloat(ptr[2]),
                halfToFloat(ptr[3]),
            };
        },
        .unknown, .depth_d8, .depth_d16, .depth_d32 => @compileError(
            "readColor: " ++ @tagName(fmt) ++ " is not a color format",
        ),
    };
}

/// Write one pixel to `dst` at index `index` from RGBA bytes.
/// Compile error for non-color formats.
pub fn writeColor8(
    comptime fmt: PixelFormat,
    dst: []u8,
    color: *const [4]u8,
    index: u32,
) void {
    switch (fmt) {
        .color_grayscale => {
            dst[index] = luminanceFromBytes(color);
        },
        .color_grayalpha => {
            const o: u32 = index * 2;
            dst[o] = luminanceFromBytes(color);
            dst[o + 1] = color[3];
        },
        .color_r3g3b2 => {
            const r3: u8 = compressByteTo(3, color[0]);
            const g3: u8 = compressByteTo(3, color[1]);
            const b2: u8 = compressByteTo(2, color[2]);
            dst[index] = (r3 << 5) | (g3 << 2) | b2;
        },
        .color_r5g6b5 => {
            const r5: u16 = compressByteTo(5, color[0]);
            const g6: u16 = compressByteTo(6, color[1]);
            const b5: u16 = compressByteTo(5, color[2]);
            const ptr: *align(1) u16 = @ptrCast(&dst[index * 2]);
            ptr.* = (r5 << 11) | (g6 << 5) | b5;
        },
        .color_r8g8b8 => {
            const o: u32 = index * 3;
            dst[o] = color[0];
            dst[o + 1] = color[1];
            dst[o + 2] = color[2];
        },
        .color_r5g5b5a1 => {
            const r5: u16 = compressByteTo(5, color[0]);
            const g5: u16 = compressByteTo(5, color[1]);
            const b5: u16 = compressByteTo(5, color[2]);
            const a1: u16 = compressByteTo(1, color[3]);
            const ptr: *align(1) u16 = @ptrCast(&dst[index * 2]);
            ptr.* = (r5 << 11) | (g5 << 6) | (b5 << 1) | a1;
        },
        .color_r4g4b4a4 => {
            const r4: u16 = compressByteTo(4, color[0]);
            const g4: u16 = compressByteTo(4, color[1]);
            const b4: u16 = compressByteTo(4, color[2]);
            const a4: u16 = compressByteTo(4, color[3]);
            const ptr: *align(1) u16 = @ptrCast(&dst[index * 2]);
            ptr.* = (r4 << 12) | (g4 << 8) | (b4 << 4) | a4;
        },
        .color_r8g8b8a8 => {
            const o: u32 = index * 4;
            dst[o] = color[0];
            dst[o + 1] = color[1];
            dst[o + 2] = color[2];
            dst[o + 3] = color[3];
        },
        // Float-channel writers from byte-typed input: divide by
        // 255 to renormalize.  Single-channel formats luminance-
        // collapse to grayscale before write.
        .color_r32 => {
            const ptr: *align(1) f32 = @ptrCast(&dst[index * 4]);
            ptr.* = float(luminanceFromBytes(color)) * inv_255;
        },
        .color_r32g32b32 => {
            const ptr: *align(1) [3]f32 = @ptrCast(&dst[index * 12]);
            ptr[0] = float(color[0]) * inv_255;
            ptr[1] = float(color[1]) * inv_255;
            ptr[2] = float(color[2]) * inv_255;
        },
        .color_r32g32b32a32 => {
            const ptr: *align(1) [4]f32 = @ptrCast(&dst[index * 16]);
            ptr[0] = float(color[0]) * inv_255;
            ptr[1] = float(color[1]) * inv_255;
            ptr[2] = float(color[2]) * inv_255;
            ptr[3] = float(color[3]) * inv_255;
        },
        .color_r16 => {
            const ptr: *align(1) u16 = @ptrCast(&dst[index * 2]);
            const f: f32 = float(luminanceFromBytes(color)) * inv_255;
            ptr.* = floatToHalf(f);
        },
        .color_r16g16b16 => {
            const ptr: *align(1) [3]u16 = @ptrCast(&dst[index * 6]);
            ptr[0] = floatToHalf(float(color[0]) * inv_255);
            ptr[1] = floatToHalf(float(color[1]) * inv_255);
            ptr[2] = floatToHalf(float(color[2]) * inv_255);
        },
        .color_r16g16b16a16 => {
            const ptr: *align(1) [4]u16 = @ptrCast(&dst[index * 8]);
            ptr[0] = floatToHalf(float(color[0]) * inv_255);
            ptr[1] = floatToHalf(float(color[1]) * inv_255);
            ptr[2] = floatToHalf(float(color[2]) * inv_255);
            ptr[3] = floatToHalf(float(color[3]) * inv_255);
        },
        .unknown, .depth_d8, .depth_d16, .depth_d32 => @compileError(
            "writeColor8: " ++ @tagName(fmt) ++ " is not a color format",
        ),
    }
}

/// Write one pixel to `dst` at index `index` from RGBA floats in
/// `[0, 1]`.  Truncation matches the donor's
/// `(uint8_t)(c*255.0f)` - out-of-range inputs are a caller bug.
/// Compile error for non-color formats.
pub fn writeColor(
    comptime fmt: PixelFormat,
    dst: []u8,
    color: *const [4]f32,
    index: u32,
) void {
    switch (fmt) {
        .color_grayscale => {
            dst[index] = @trunc(luminanceFromFloats(color) * 255.0);
        },
        .color_grayalpha => {
            const o: u32 = index * 2;
            dst[o] = @trunc(luminanceFromFloats(color) * 255.0);
            dst[o + 1] = @trunc(color[3] * 255.0);
        },
        // Packed-bitfield float writers convert to byte-typed via
        // `floatColorToBytes`, then delegate.  Donor structures
        // the family the same way.
        .color_r3g3b2,
        .color_r5g6b5,
        .color_r5g5b5a1,
        .color_r4g4b4a4,
        => {
            var rgba8: [4]u8 = undefined;
            floatColorToBytes(&rgba8, color);
            writeColor8(fmt, dst, &rgba8, index);
        },
        .color_r8g8b8 => {
            const o: u32 = index * 3;
            dst[o] = @trunc(color[0] * 255.0);
            dst[o + 1] = @trunc(color[1] * 255.0);
            dst[o + 2] = @trunc(color[2] * 255.0);
        },
        .color_r8g8b8a8 => {
            const o: u32 = index * 4;
            dst[o] = @trunc(color[0] * 255.0);
            dst[o + 1] = @trunc(color[1] * 255.0);
            dst[o + 2] = @trunc(color[2] * 255.0);
            dst[o + 3] = @trunc(color[3] * 255.0);
        },
        // Float-channel float writers: pass through directly.
        // Single-channel formats luminance-collapse.  Donor: r32
        // stores `sw_luminance(color)` (no *255), matching the
        // r32 reader which is a passthrough float.
        .color_r32 => {
            const ptr: *align(1) f32 = @ptrCast(&dst[index * 4]);
            ptr.* = luminanceFromFloats(color);
        },
        .color_r32g32b32 => {
            const ptr: *align(1) [3]f32 = @ptrCast(&dst[index * 12]);
            ptr[0] = color[0];
            ptr[1] = color[1];
            ptr[2] = color[2];
        },
        .color_r32g32b32a32 => {
            const ptr: *align(1) [4]f32 = @ptrCast(&dst[index * 16]);
            ptr[0] = color[0];
            ptr[1] = color[1];
            ptr[2] = color[2];
            ptr[3] = color[3];
        },
        .color_r16 => {
            const ptr: *align(1) u16 = @ptrCast(&dst[index * 2]);
            ptr.* = floatToHalf(luminanceFromFloats(color));
        },
        .color_r16g16b16 => {
            const ptr: *align(1) [3]u16 = @ptrCast(&dst[index * 6]);
            ptr[0] = floatToHalf(color[0]);
            ptr[1] = floatToHalf(color[1]);
            ptr[2] = floatToHalf(color[2]);
        },
        .color_r16g16b16a16 => {
            const ptr: *align(1) [4]u16 = @ptrCast(&dst[index * 8]);
            ptr[0] = floatToHalf(color[0]);
            ptr[1] = floatToHalf(color[1]);
            ptr[2] = floatToHalf(color[2]);
            ptr[3] = floatToHalf(color[3]);
        },
        .unknown, .depth_d8, .depth_d16, .depth_d32 => @compileError(
            "writeColor: " ++ @tagName(fmt) ++ " is not a color format",
        ),
    }
}

// ---- Depth readers + writers
// D16/D32 use `*align(1) const T` casts so they work on byte-aligned
// buffers (no `@alignCast` assertion to panic on the framebuffer's
// u8-allocated depth storage).  The donor uses native-endian access
// (a plain `(uint16_t*)pixels[idx]` cast); since every supported
// target is little-endian, we match.

/// Read a normalized depth value (0..1 nominal) from `src` at
/// `index`.  Compile error for non-depth formats.
pub fn readDepth(
    comptime fmt: PixelFormat,
    src: []const u8,
    index: u32,
) f32 {
    return switch (fmt) {
        .depth_d8 => float(src[index]) * inv_255,
        .depth_d16 => blk: {
            const ptr: *align(1) const u16 = @ptrCast(&src[index * 2]);
            break :blk float(ptr.*) / 65535.0;
        },
        .depth_d32 => blk: {
            const ptr: *align(1) const f32 = @ptrCast(&src[index * 4]);
            break :blk ptr.*;
        },
        else => @compileError("readDepth: " ++ @tagName(fmt) ++ " is not a depth format"),
    };
}

/// Write a normalized depth value to `dst` at `index`.  Compile
/// error for non-depth formats.
pub fn writeDepth(
    comptime fmt: PixelFormat,
    dst: []u8,
    depth: f32,
    index: u32,
) void {
    switch (fmt) {
        .depth_d8 => {
            dst[index] = @trunc(depth * 255.0);
        },
        .depth_d16 => {
            const ptr: *align(1) u16 = @ptrCast(&dst[index * 2]);
            ptr.* = @trunc(depth * 65535.0);
        },
        .depth_d32 => {
            const ptr: *align(1) f32 = @ptrCast(&dst[index * 4]);
            ptr.* = depth;
        },
        else => @compileError("writeDepth: " ++ @tagName(fmt) ++ " is not a depth format"),
    }
}

// ---- Dispatch tables
// Each table is `EnumArray(PixelFormat, ?Fn)`.  Color tables have
// every color slot populated; depth tables fill `d8`/`d16`/`d32`;
// every other slot - including the `unknown` sentinel - stays
// `null`.  Reads use `.get(fmt)` so callers never index by raw int.
// The tables are built at comptime from the same comptime-
// specialized fns above.  Each populated slot points at a tiny
// anonymous-struct dispatch wrapper that monomorphizes the
// function for that one format.  Identical machine code to
// hand-writing 14 separate fn pointers, single source of truth.

pub const read_color8_table: std.enums.EnumArray(PixelFormat, ?ReadColor8Fn) = blk: {
    var t: std.enums.EnumArray(PixelFormat, ?ReadColor8Fn) = .initFill(null);
    for (std.enums.values(PixelFormat)) |fmt| {
        if (isColorFormat(fmt)) {
            t.set(fmt, &(struct {
                fn dispatch(out: *[4]u8, src: []const u8, idx: u32) void {
                    out.* = readColor8(fmt, src, idx);
                }
            }).dispatch);
        }
    }
    break :blk t;
};

pub const read_color_table: std.enums.EnumArray(PixelFormat, ?ReadColorFn) = blk: {
    var t: std.enums.EnumArray(PixelFormat, ?ReadColorFn) = .initFill(null);
    for (std.enums.values(PixelFormat)) |fmt| {
        if (isColorFormat(fmt)) {
            t.set(fmt, &(struct {
                fn dispatch(out: *[4]f32, src: []const u8, idx: u32) void {
                    out.* = readColor(fmt, src, idx);
                }
            }).dispatch);
        }
    }
    break :blk t;
};

pub const write_color8_table: std.enums.EnumArray(PixelFormat, ?WriteColor8Fn) = blk: {
    var t: std.enums.EnumArray(PixelFormat, ?WriteColor8Fn) = .initFill(null);
    for (std.enums.values(PixelFormat)) |fmt| {
        if (isColorFormat(fmt)) {
            t.set(fmt, &(struct {
                fn dispatch(dst: []u8, color: *const [4]u8, idx: u32) void {
                    writeColor8(fmt, dst, color, idx);
                }
            }).dispatch);
        }
    }
    break :blk t;
};

pub const write_color_table: std.enums.EnumArray(PixelFormat, ?WriteColorFn) = blk: {
    var t: std.enums.EnumArray(PixelFormat, ?WriteColorFn) = .initFill(null);
    for (std.enums.values(PixelFormat)) |fmt| {
        if (isColorFormat(fmt)) {
            t.set(fmt, &(struct {
                fn dispatch(dst: []u8, color: *const [4]f32, idx: u32) void {
                    writeColor(fmt, dst, color, idx);
                }
            }).dispatch);
        }
    }
    break :blk t;
};

pub const read_depth_table: std.enums.EnumArray(PixelFormat, ?ReadDepthFn) = blk: {
    var t: std.enums.EnumArray(PixelFormat, ?ReadDepthFn) = .initFill(null);
    for (std.enums.values(PixelFormat)) |fmt| {
        if (isDepthFormat(fmt)) {
            t.set(fmt, &(struct {
                fn dispatch(src: []const u8, idx: u32) f32 {
                    return readDepth(fmt, src, idx);
                }
            }).dispatch);
        }
    }
    break :blk t;
};

pub const write_depth_table: std.enums.EnumArray(PixelFormat, ?WriteDepthFn) = blk: {
    var t: std.enums.EnumArray(PixelFormat, ?WriteDepthFn) = .initFill(null);
    for (std.enums.values(PixelFormat)) |fmt| {
        if (isDepthFormat(fmt)) {
            t.set(fmt, &(struct {
                fn dispatch(dst: []u8, depth: f32, idx: u32) void {
                    writeDepth(fmt, dst, depth, idx);
                }
            }).dispatch);
        }
    }
    break :blk t;
};

// ============================================================================
// Tests
// ============================================================================

// ---- pixel format read/write tests
// Each format gets a tight round-trip test.  For lossless formats
// (R8G8B8A8) the round-trip is exact; for lossy ones (GRAYSCALE
// reduces RGB → luminance) we either pre-condition the input to be
// lossless (gray-only RGB) or verify the lossy mapping directly.

test "era I: helpers - luminance8 and luminance" {
    // Pure white: 255 * (77+150+29) / 256 = 255 * 256 / 256 = 255.
    try expectEqual(@as(u8, 255), luminanceFromBytes(&.{ 255, 255, 255, 0 }));
    // Pure black: 0.
    try expectEqual(@as(u8, 0), luminanceFromBytes(&.{ 0, 0, 0, 255 }));
    // Pure red contributes only 77/256 weight: floor(255 * 77 / 256) = 76.
    try expectEqual(@as(u8, 76), luminanceFromBytes(&.{ 255, 0, 0, 0 }));
    // Pure green: floor(255 * 150 / 256) = 149.
    try expectEqual(@as(u8, 149), luminanceFromBytes(&.{ 0, 255, 0, 0 }));
    // Pure blue: floor(255 * 29 / 256) = 28.
    try expectEqual(@as(u8, 28), luminanceFromBytes(&.{ 0, 0, 255, 0 }));

    // Float version: pure white = 0.299 + 0.587 + 0.114 = 1.0.
    try expectApproxEqAbs(@as(f32, 1.0), luminanceFromFloats(&.{ 1, 1, 1, 0 }), 1e-6);
    // Pure red = 0.299; green = 0.587; blue = 0.114.
    try expectApproxEqAbs(@as(f32, 0.299), luminanceFromFloats(&.{ 1, 0, 0, 0 }), 1e-6);
    try expectApproxEqAbs(@as(f32, 0.587), luminanceFromFloats(&.{ 0, 1, 0, 0 }), 1e-6);
    try expectApproxEqAbs(@as(f32, 0.114), luminanceFromFloats(&.{ 0, 0, 1, 0 }), 1e-6);
}

test "era I: color8ToColor normalizes 4 bytes to 4 floats" {
    var out: [4]f32 = undefined;
    byteColorToFloats(&out, &.{ 0, 127, 128, 255 });
    try expectApproxEqAbs(@as(f32, 0.0), out[0], 1e-6);
    try expectApproxEqAbs(@as(f32, 127.0 / 255.0), out[1], 1e-6);
    try expectApproxEqAbs(@as(f32, 128.0 / 255.0), out[2], 1e-6);
    try expectApproxEqAbs(@as(f32, 1.0), out[3], 1e-6);
}

// ---- GRAYSCALE format
test "era I: GRAYSCALE write_color8 + read_color8 round-trip" {
    // 1 byte per pixel.  Input must be gray (R=G=B) for exact roundtrip
    // since write_color8 reduces via luminance8.
    var buf: [4]u8 = @splat(0);

    // Write three gray pixels: 0, 128, 255.
    writeColor8(.color_grayscale, &buf, &.{ 0, 0, 0, 255 }, 0);
    writeColor8(.color_grayscale, &buf, &.{ 128, 128, 128, 255 }, 1);
    writeColor8(.color_grayscale, &buf, &.{ 255, 255, 255, 255 }, 2);

    var out: [4]u8 = undefined;
    out = readColor8(.color_grayscale, &buf, 0);
    try expectEqual([4]u8{ 0, 0, 0, 255 }, out);

    out = readColor8(.color_grayscale, &buf, 1);
    // luminance8(128, 128, 128) = 128 because the BT.601 weights sum to 256.
    try expectEqual([4]u8{ 128, 128, 128, 255 }, out);

    out = readColor8(.color_grayscale, &buf, 2);
    try expectEqual([4]u8{ 255, 255, 255, 255 }, out);
}

test "era I: GRAYSCALE write_color (float) + read_color round-trip" {
    var buf: [4]u8 = @splat(0);
    writeColor(.color_grayscale, &buf, &.{ 0.0, 0.0, 0.0, 1.0 }, 0);
    writeColor(.color_grayscale, &buf, &.{ 0.5, 0.5, 0.5, 1.0 }, 1);
    writeColor(.color_grayscale, &buf, &.{ 1.0, 1.0, 1.0, 1.0 }, 2);

    var out: [4]f32 = undefined;
    out = readColor(.color_grayscale, &buf, 0);
    try expectApproxEqAbs(@as(f32, 0.0), out[0], 1e-6);
    try expectApproxEqAbs(@as(f32, 1.0), out[3], 1e-6);

    out = readColor(.color_grayscale, &buf, 2);
    try expectApproxEqAbs(@as(f32, 1.0), out[0], 1e-6);
    try expectApproxEqAbs(@as(f32, 1.0), out[3], 1e-6);
}

// ---- GRAYALPHA format
test "era I: GRAYALPHA write_color8 + read_color8 round-trip" {
    // 2 bytes per pixel: gray, alpha.  Round-trip preserves separate alpha.
    var buf: [6]u8 = @splat(0);

    writeColor8(.color_grayalpha, &buf, &.{ 100, 100, 100, 50 }, 0);
    writeColor8(.color_grayalpha, &buf, &.{ 200, 200, 200, 128 }, 1);
    writeColor8(.color_grayalpha, &buf, &.{ 0, 0, 0, 255 }, 2);

    var out: [4]u8 = undefined;
    out = readColor8(.color_grayalpha, &buf, 0);
    // luminance8(g,g,g) = g exactly because the BT.601 weights
    // 77+150+29 sum to 256.
    try expectEqual([4]u8{ 100, 100, 100, 50 }, out);

    out = readColor8(.color_grayalpha, &buf, 1);
    try expectEqual([4]u8{ 200, 200, 200, 128 }, out);

    out = readColor8(.color_grayalpha, &buf, 2);
    try expectEqual([4]u8{ 0, 0, 0, 255 }, out);
}

// ---- R8G8B8 format
test "era I: R8G8B8 write_color8 + read_color8 preserves RGB; alpha pinned to 255" {
    var buf: [9]u8 = @splat(0);
    writeColor8(.color_r8g8b8, &buf, &.{ 255, 128, 64, 33 }, 0); // alpha 33 ignored
    writeColor8(.color_r8g8b8, &buf, &.{ 0, 255, 128, 100 }, 1);
    writeColor8(.color_r8g8b8, &buf, &.{ 200, 100, 50, 200 }, 2);

    var out: [4]u8 = undefined;
    out = readColor8(.color_r8g8b8, &buf, 0);
    try expectEqual([4]u8{ 255, 128, 64, 255 }, out);
    out = readColor8(.color_r8g8b8, &buf, 1);
    try expectEqual([4]u8{ 0, 255, 128, 255 }, out);
    out = readColor8(.color_r8g8b8, &buf, 2);
    try expectEqual([4]u8{ 200, 100, 50, 255 }, out);
}

test "era I: R8G8B8 write_color (float) + read_color preserves RGB" {
    var buf: [3]u8 = @splat(0);
    writeColor(.color_r8g8b8, &buf, &.{ 1.0, 0.5, 0.25, 0.0 }, 0);

    var out: [4]f32 = undefined;
    out = readColor(.color_r8g8b8, &buf, 0);
    try expectApproxEqAbs(@as(f32, 1.0), out[0], 1.0 / 255.0);
    try expectApproxEqAbs(@as(f32, 0.5), out[1], 1.0 / 255.0);
    try expectApproxEqAbs(@as(f32, 0.25), out[2], 1.0 / 255.0);
    try expectApproxEqAbs(@as(f32, 1.0), out[3], 1e-6); // alpha pinned
}

// ---- R8G8B8A8 format
test "era I: R8G8B8A8 write_color8 + read_color8 exact round-trip" {
    var buf: [16]u8 = @splat(0);

    const inputs = [_][4]u8{
        .{ 0, 0, 0, 0 },
        .{ 255, 128, 64, 32 },
        .{ 1, 2, 3, 4 },
        .{ 255, 255, 255, 255 },
    };
    for (inputs, 0..) |c, i| {
        writeColor8(.color_r8g8b8a8, &buf, &c, @intCast(i));
    }
    for (inputs, 0..) |expected, i| {
        var out: [4]u8 = undefined;
        out = readColor8(.color_r8g8b8a8, &buf, @intCast(i));
        try expectEqual(expected, out);
    }
}

test "era I: R8G8B8A8 write_color (float) + read_color round-trip" {
    var buf: [4]u8 = @splat(0);
    writeColor(.color_r8g8b8a8, &buf, &.{ 1.0, 0.75, 0.5, 0.25 }, 0);

    var out: [4]f32 = undefined;
    out = readColor(.color_r8g8b8a8, &buf, 0);
    try expectApproxEqAbs(@as(f32, 1.0), out[0], 1.0 / 255.0);
    try expectApproxEqAbs(@as(f32, 0.75), out[1], 1.0 / 255.0);
    try expectApproxEqAbs(@as(f32, 0.5), out[2], 1.0 / 255.0);
    try expectApproxEqAbs(@as(f32, 0.25), out[3], 1.0 / 255.0);
}

test "era I: R8G8B8A8 cross - write_color8 then read_color normalizes" {
    var buf: [4]u8 = @splat(0);
    writeColor8(.color_r8g8b8a8, &buf, &.{ 255, 0, 0, 128 }, 0);

    var out: [4]f32 = undefined;
    out = readColor(.color_r8g8b8a8, &buf, 0);
    try expectApproxEqAbs(@as(f32, 1.0), out[0], 1e-6);
    try expectApproxEqAbs(@as(f32, 0.0), out[1], 1e-6);
    try expectApproxEqAbs(@as(f32, 0.0), out[2], 1e-6);
    try expectApproxEqAbs(@as(f32, 128.0 / 255.0), out[3], 1e-6);
}

// ---- Depth formats
test "era I: D8 round-trip with 1/255 quantization" {
    var buf: [4]u8 = @splat(0);
    writeDepth(.depth_d8, &buf, 0.0, 0);
    writeDepth(.depth_d8, &buf, 0.5, 1);
    writeDepth(.depth_d8, &buf, 1.0, 2);

    try expectApproxEqAbs(@as(f32, 0.0), readDepth(.depth_d8, &buf, 0), 1.0 / 255.0);
    try expectApproxEqAbs(@as(f32, 0.5), readDepth(.depth_d8, &buf, 1), 1.0 / 255.0);
    try expectApproxEqAbs(@as(f32, 1.0), readDepth(.depth_d8, &buf, 2), 1.0 / 255.0);
}

test "era I: D16 round-trip with 1/65535 quantization" {
    var buf: [6]u8 = @splat(0);
    writeDepth(.depth_d16, &buf, 0.0, 0);
    writeDepth(.depth_d16, &buf, 0.5, 1);
    writeDepth(.depth_d16, &buf, 0.9999, 2);

    const eps: f32 = 1.0 / 65535.0;
    try expectApproxEqAbs(@as(f32, 0.0), readDepth(.depth_d16, &buf, 0), eps);
    try expectApproxEqAbs(@as(f32, 0.5), readDepth(.depth_d16, &buf, 1), eps);
    try expectApproxEqAbs(@as(f32, 0.9999), readDepth(.depth_d16, &buf, 2), eps);
}

test "era I: D32 round-trip is exact" {
    var buf: [12]u8 = @splat(0);
    writeDepth(.depth_d32, &buf, 0.0, 0);
    writeDepth(.depth_d32, &buf, 0.123456789, 1);
    writeDepth(.depth_d32, &buf, 1.0, 2);

    try expectEqual(@as(f32, 0.0), readDepth(.depth_d32, &buf, 0));
    try expectEqual(@as(f32, 0.123456789), readDepth(.depth_d32, &buf, 1));
    try expectEqual(@as(f32, 1.0), readDepth(.depth_d32, &buf, 2));
}

test "era I: D16 endianness is native (donor matches)" {
    // Write 0xAABB pattern via depth ≈ 0xAABB / 65535.
    var buf: [2]u8 = @splat(0);
    writeDepth(.depth_d16, &buf, @as(f32, 0xAABB) / 65535.0, 0);
    // On little-endian (every supported target), the low byte (BB)
    // is at offset 0 and high byte (AA) at offset 1.
    try expectEqual(@as(u8, 0xBB), buf[0]);
    try expectEqual(@as(u8, 0xAA), buf[1]);
}

// ---- Dispatch tables
test "era I: dispatch tables wire up every color + depth format" {
    // After the format-codec pass, every color slot has all four entries non-null
    // and every depth slot has both entries non-null.  The `unknown`
    // sentinel slot stays null in every table.
    const all_color = [_]PixelFormat{
        .color_grayscale,
        .color_grayalpha,
        .color_r3g3b2,
        .color_r5g6b5,
        .color_r8g8b8,
        .color_r5g5b5a1,
        .color_r4g4b4a4,
        .color_r8g8b8a8,
        .color_r32,
        .color_r32g32b32,
        .color_r32g32b32a32,
        .color_r16,
        .color_r16g16b16,
        .color_r16g16b16a16,
    };
    for (all_color) |fmt| {
        try expect(read_color8_table.get(fmt) != null);
        try expect(read_color_table.get(fmt) != null);
        try expect(write_color8_table.get(fmt) != null);
        try expect(write_color_table.get(fmt) != null);
    }
    const all_depth = [_]PixelFormat{ .depth_d8, .depth_d16, .depth_d32 };
    for (all_depth) |fmt| {
        try expect(read_depth_table.get(fmt) != null);
        try expect(write_depth_table.get(fmt) != null);
    }

    // The `unknown` sentinel slot is null in every table.
    try expectEqual(@as(?ReadColor8Fn, null), read_color8_table.get(.unknown));
    try expectEqual(@as(?ReadColorFn, null), read_color_table.get(.unknown));
    try expectEqual(@as(?WriteColor8Fn, null), write_color8_table.get(.unknown));
    try expectEqual(@as(?WriteColorFn, null), write_color_table.get(.unknown));
    try expectEqual(@as(?ReadDepthFn, null), read_depth_table.get(.unknown));
    try expectEqual(@as(?WriteDepthFn, null), write_depth_table.get(.unknown));

    // Color formats have null in the depth tables and vice versa.
    for (all_color) |fmt| {
        try expectEqual(@as(?ReadDepthFn, null), read_depth_table.get(fmt));
        try expectEqual(@as(?WriteDepthFn, null), write_depth_table.get(fmt));
    }
    for (all_depth) |fmt| {
        try expectEqual(@as(?ReadColor8Fn, null), read_color8_table.get(fmt));
        try expectEqual(@as(?ReadColorFn, null), read_color_table.get(fmt));
        try expectEqual(@as(?WriteColor8Fn, null), write_color8_table.get(fmt));
        try expectEqual(@as(?WriteColorFn, null), write_color_table.get(fmt));
    }
}

test "era I: dispatched call via table matches direct call" {
    // Sanity check that the function-pointer wired up in the table
    // is the same one we'd call directly - catches accidental
    // mismatches between table population and the format functions.
    var buf: [4]u8 = @splat(0);
    writeColor8(.color_r8g8b8a8, &buf, &.{ 10, 20, 30, 40 }, 0);

    const reader: ReadColor8Fn = read_color8_table.get(.color_r8g8b8a8).?;
    var out_dispatched: [4]u8 = undefined;
    reader(&out_dispatched, &buf, 0);

    var out_direct: [4]u8 = undefined;
    out_direct = readColor8(.color_r8g8b8a8, &buf, 0);

    try expectEqual(out_direct, out_dispatched);
}

// ---- helper tests
test "era I: expand_NtoB maps full N-bit range to 0..255 monotonically" {
    // For each width N, the smallest input (0) must map to 0 and the
    // largest (2^N − 1) must map to 255.  All values monotonic.
    try expectEqual(@as(u8, 0), expandToByte(1, 0));
    try expectEqual(@as(u8, 255), expandToByte(1, 1));

    try expectEqual(@as(u8, 0), expandToByte(2, 0));
    try expectEqual(@as(u8, 255), expandToByte(2, 3));
    try expectEqual(@as(u8, 85), expandToByte(2, 1));
    try expectEqual(@as(u8, 170), expandToByte(2, 2));

    try expectEqual(@as(u8, 0), expandToByte(3, 0));
    try expectEqual(@as(u8, 255), expandToByte(3, 7));

    try expectEqual(@as(u8, 0), expandToByte(4, 0));
    try expectEqual(@as(u8, 255), expandToByte(4, 15));
    try expectEqual(@as(u8, 17), expandToByte(4, 1)); // 0x11

    try expectEqual(@as(u8, 0), expandToByte(5, 0));
    try expectEqual(@as(u8, 255), expandToByte(5, 31));

    try expectEqual(@as(u8, 0), expandToByte(6, 0));
    try expectEqual(@as(u8, 255), expandToByte(6, 63));

    // Monotonicity sweep for the wider widths.
    var prev_5: u8 = expandToByte(5, 0);
    for (1..32) |i| {
        const cur: u8 = expandToByte(5, @intCast(i));
        try expect(cur >= prev_5);
        prev_5 = cur;
    }
}

test "era I: compress_8toN is the bit-truncate of the upper N bits" {
    // compress_8toN is just `v >> (8-N)`, i.e. take the top N bits.
    try expectEqual(@as(u8, 0), compressByteTo(1, 127));
    try expectEqual(@as(u8, 1), compressByteTo(1, 128));
    try expectEqual(@as(u8, 1), compressByteTo(1, 255));

    try expectEqual(@as(u8, 0), compressByteTo(3, 0));
    try expectEqual(@as(u8, 7), compressByteTo(3, 255));
    try expectEqual(@as(u8, 4), compressByteTo(3, 128));

    try expectEqual(@as(u8, 31), compressByteTo(5, 255));
    try expectEqual(@as(u8, 0), compressByteTo(5, 0));

    try expectEqual(@as(u8, 63), compressByteTo(6, 255));
}

test "era I: expand-then-compress is identity for in-range inputs" {
    // For every N-bit value v, compress8toN(expandNto8(v)) == v.
    // This is the round-trip property the formats rely on.
    for (0..2) |i| {
        try expectEqual(
            @as(u8, @intCast(i)),
            compressByteTo(1, expandToByte(1, @intCast(i))),
        );
    }
    for (0..4) |i| {
        try expectEqual(
            @as(u8, @intCast(i)),
            compressByteTo(2, expandToByte(2, @intCast(i))),
        );
    }
    for (0..8) |i| {
        try expectEqual(
            @as(u8, @intCast(i)),
            compressByteTo(3, expandToByte(3, @intCast(i))),
        );
    }
    for (0..16) |i| {
        try expectEqual(
            @as(u8, @intCast(i)),
            compressByteTo(4, expandToByte(4, @intCast(i))),
        );
    }
    for (0..32) |i| {
        try expectEqual(
            @as(u8, @intCast(i)),
            compressByteTo(5, expandToByte(5, @intCast(i))),
        );
    }
    for (0..64) |i| {
        try expectEqual(
            @as(u8, @intCast(i)),
            compressByteTo(6, expandToByte(6, @intCast(i))),
        );
    }
}

test "era I: half-float identity for representable values" {
    // Powers of 2 in [-65504, 65504] are exactly representable in
    // half-precision.  Round-trip must be exact for these.
    const exact = [_]f32{ 0.0, 1.0, -1.0, 0.5, 0.25, 0.125, 2.0, 4.0, 100.0, -100.0 };
    for (exact) |x| {
        const round_trip: f32 = halfToFloat(floatToHalf(x));
        try expectEqual(x, round_trip);
    }
}

test "era I: half-float approximate identity for fractional values" {
    // Non-power-of-2 fractions round to nearest half-precision.  Use
    // a small tolerance - half-precision has ~3 decimal digits of
    // precision.
    const cases = [_]f32{ 0.1, 0.3, 0.7, 0.9, 0.123, 0.456 };
    for (cases) |x| {
        const round_trip: f32 = halfToFloat(floatToHalf(x));
        try expectApproxEqAbs(x, round_trip, 0.001);
    }
}

test "era I: half-float overflow / underflow / NaN" {
    // Overflow → +inf encoding (0x7c00).
    try expectEqual(@as(u16, 0x7c00), floatToHalf(1.0e30));
    try expectEqual(@as(u16, 0xfc00), floatToHalf(-1.0e30));

    // Underflow (subnormal half) → flush to zero.  Donor matches.
    try expectEqual(@as(u16, 0), floatToHalf(1.0e-30));

    // NaN → qNaN encoding (0x7e00).
    const nan_f32: f32 = nan(f32);
    try expectEqual(@as(u16, 0x7e00), floatToHalf(nan_f32));
}

test "era I: colorToColor8 truncates float×255" {
    var out: [4]u8 = undefined;
    floatColorToBytes(&out, &.{ 0.0, 1.0, 0.5, 0.25 });
    try expectEqual([4]u8{ 0, 255, 127, 63 }, out);
}

// ---- packed-bitfield format round-trips
test "era I: R3G3B2 round-trip with quantization" {
    // R/G are 3-bit (max 7 distinct values), B is 2-bit (max 3 distinct).
    // Pick inputs at the bit-width quantization grid so write→read is exact.
    var buf: [4]u8 = @splat(0);

    // Exact-grid color: r5_grid = expand3to8(5) = 0xB6, g2_grid = expand3to8(2) = 0x49,
    // b3_grid = expand2to8(3) = 0xFF.
    const c_in = [4]u8{ 0xB6, 0x49, 0xFF, 99 }; // alpha ignored
    writeColor8(.color_r3g3b2, &buf, &c_in, 0);

    var c_out: [4]u8 = undefined;
    c_out = readColor8(.color_r3g3b2, &buf, 0);

    try expectEqual(@as(u8, 0xB6), c_out[0]);
    try expectEqual(@as(u8, 0x49), c_out[1]);
    try expectEqual(@as(u8, 0xFF), c_out[2]);
    try expectEqual(@as(u8, 255), c_out[3]); // alpha pinned
}

test "era I: R5G6B5 round-trip with quantization" {
    var buf: [4]u8 = @splat(0); // 2 bytes used
    const c_in = [4]u8{ 0xFF, 0x80, 0x00, 99 };
    writeColor8(.color_r5g6b5, &buf, &c_in, 0);

    var c_out: [4]u8 = undefined;
    c_out = readColor8(.color_r5g6b5, &buf, 0);

    // Quantization: r 0xFF → 5-bit 31 → expand → 0xFF.  g 0x80 → 6-bit 32
    // → expand6to8(32) = (32<<2)|(32>>4) = 0x80 | 0x02 = 0x82.  b 0 → 0.
    try expectEqual(@as(u8, 0xFF), c_out[0]);
    try expectEqual(@as(u8, 0x82), c_out[1]);
    try expectEqual(@as(u8, 0x00), c_out[2]);
    try expectEqual(@as(u8, 255), c_out[3]);
}

test "era I: R5G5B5A1 round-trip with quantization" {
    var buf: [4]u8 = @splat(0);
    // Alpha is 1-bit: any non-zero value rounds to 1, which expands to 255.
    const c_in = [4]u8{ 0xFF, 0x00, 0xFF, 200 };
    writeColor8(.color_r5g5b5a1, &buf, &c_in, 0);

    var c_out: [4]u8 = undefined;
    c_out = readColor8(.color_r5g5b5a1, &buf, 0);

    try expectEqual(@as(u8, 0xFF), c_out[0]);
    try expectEqual(@as(u8, 0x00), c_out[1]);
    try expectEqual(@as(u8, 0xFF), c_out[2]);
    try expectEqual(@as(u8, 255), c_out[3]); // alpha 200 ≥ 128 → 1 → 255

    // Sub-threshold alpha rounds down to 0.
    const c_low_a = [4]u8{ 0xFF, 0x00, 0xFF, 100 };
    writeColor8(.color_r5g5b5a1, &buf, &c_low_a, 0);
    c_out = readColor8(.color_r5g5b5a1, &buf, 0);
    try expectEqual(@as(u8, 0), c_out[3]);
}

test "era I: R4G4B4A4 round-trip with quantization" {
    var buf: [4]u8 = @splat(0);
    // 4-bit channels: top nibble survives, bottom bits truncated.
    // expand4to8(v) = v<<4 | v.  Round-trip: input 0xAB → compress 0xA → expand 0xAA.
    const c_in = [4]u8{ 0xAB, 0xCD, 0xEF, 0x12 };
    writeColor8(.color_r4g4b4a4, &buf, &c_in, 0);

    var c_out: [4]u8 = undefined;
    c_out = readColor8(.color_r4g4b4a4, &buf, 0);

    try expectEqual(@as(u8, 0xAA), c_out[0]);
    try expectEqual(@as(u8, 0xCC), c_out[1]);
    try expectEqual(@as(u8, 0xEE), c_out[2]);
    try expectEqual(@as(u8, 0x11), c_out[3]);
}

// ---- float-channel format round-trips
test "era I: R32 (single-channel float) round-trip" {
    // R32 is a luminance format: write_color8 luminance-collapses RGB
    // and stores as a normalized float; read_color8 multiplies back.
    var buf: [16]u8 = @splat(0);
    const c_in = [4]u8{ 100, 100, 100, 99 }; // already gray, alpha ignored
    writeColor8(.color_r32, &buf, &c_in, 0);

    var c_out: [4]u8 = undefined;
    c_out = readColor8(.color_r32, &buf, 0);

    try expectEqual(@as(u8, 100), c_out[0]);
    try expectEqual(@as(u8, 100), c_out[1]);
    try expectEqual(@as(u8, 100), c_out[2]);
    try expectEqual(@as(u8, 255), c_out[3]);
}

test "era I: R32G32B32A32 (float) round-trip via float reader/writer" {
    var buf: [32]u8 = @splat(0); // 16 bytes used
    const c_in = [4]f32{ 0.25, 0.5, 0.75, 1.0 };
    writeColor(.color_r32g32b32a32, &buf, &c_in, 0);

    var c_out: [4]f32 = undefined;
    c_out = readColor(.color_r32g32b32a32, &buf, 0);

    try expectEqual(c_in, c_out); // float passthrough is exact
}

test "era I: R32G32B32 (float) round-trip with alpha pinned to 1.0" {
    var buf: [16]u8 = @splat(0); // 12 bytes used
    const c_in = [4]f32{ 0.25, 0.5, 0.75, 0.4 }; // alpha will be dropped
    writeColor(.color_r32g32b32, &buf, &c_in, 0);

    var c_out: [4]f32 = undefined;
    c_out = readColor(.color_r32g32b32, &buf, 0);

    try expectEqual(@as(f32, 0.25), c_out[0]);
    try expectEqual(@as(f32, 0.5), c_out[1]);
    try expectEqual(@as(f32, 0.75), c_out[2]);
    try expectEqual(@as(f32, 1.0), c_out[3]);
}

test "era I: R16G16B16A16 (half-float) round-trip" {
    var buf: [16]u8 = @splat(0); // 8 bytes used
    // Use exactly representable half-precision values.
    const c_in = [4]f32{ 0.5, 0.25, 0.125, 1.0 };
    writeColor(.color_r16g16b16a16, &buf, &c_in, 0);

    var c_out: [4]f32 = undefined;
    c_out = readColor(.color_r16g16b16a16, &buf, 0);

    try expectEqual(c_in, c_out);
}

test "era I: R16 (half-float, single channel) round-trip via byte path" {
    var buf: [4]u8 = @splat(0); // 2 bytes used
    const c_in = [4]u8{ 128, 128, 128, 99 }; // gray
    writeColor8(.color_r16, &buf, &c_in, 0);

    var c_out: [4]u8 = undefined;
    c_out = readColor8(.color_r16, &buf, 0);

    // Half-float quantization at this value; allow ±2 LSB tolerance.
    const tol: i16 = 2;
    const got: i16 = @intCast(c_out[0]);
    const want: i16 = 128;
    try expect(@abs(got - want) <= tol);
    try expectEqual(c_out[0], c_out[1]);
    try expectEqual(c_out[0], c_out[2]);
    try expectEqual(@as(u8, 255), c_out[3]);
}

test "era I: dispatched call for R5G6B5 matches direct call" {
    // Same sanity check as the dispatched-vs-direct test, but
    // for a packed-bitfield format.
    var buf: [4]u8 = @splat(0);
    writeColor8(.color_r5g6b5, &buf, &.{ 0xFF, 0x80, 0x00, 0 }, 0);

    const reader: ReadColor8Fn = read_color8_table.get(.color_r5g6b5).?;
    var out_dispatched: [4]u8 = undefined;
    reader(&out_dispatched, &buf, 0);

    var out_direct: [4]u8 = undefined;
    out_direct = readColor8(.color_r5g6b5, &buf, 0);

    try expectEqual(out_direct, out_dispatched);
}

test "era I: write_color (float) for packed format matches write_color8 path" {
    // For R3G3B2, calling write_color (float input) should produce
    // the same bytes as colorToColor8 + write_color8.r3g3b2.
    var buf_float: [4]u8 = @splat(0);
    var buf_byte: [4]u8 = @splat(0);

    const c_f = [4]f32{ 0.7, 0.3, 0.5, 1.0 };
    writeColor(.color_r3g3b2, &buf_float, &c_f, 0);

    var c_b: [4]u8 = undefined;
    floatColorToBytes(&c_b, &c_f);
    writeColor8(.color_r3g3b2, &buf_byte, &c_b, 0);

    try expectEqual(buf_byte[0], buf_float[0]);
}
