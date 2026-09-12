//! lint:alias image
//! image — Image (CPU pixel buffer) type helpers + the full CPU
//! image-processing library (merged from drawing.textures in
//! GL-retirement P5): generators (color/checked/gradients/noise/
//! cellular), transforms (crop/resize×3/rotate/flip/blur/dither),
//! draws-into-image (pixels/lines/shapes/text), color ops, format
//! conversion, and PNG export glue.

const std = @import("std");
const eql = std.mem.eql;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const Allocator = std.mem.Allocator;
const zm = @import("zm");
const turnsFromRad = zm.turnsFromRad;
const float = zm.float;
const ceilPowerOfTwo = zm.ceilPowerOfTwo;
const clamp = zm.clamp;
const floatMax = zm.floatMax;
const floori = zm.floori;
const hypot = zm.hypot;
const int = zm.int;
const lerp = zm.lerp;
const maxInt = zm.maxInt;
const pi = zm.pi;
const radFromDeg = zm.radFromDeg;
const roundi = zm.roundi;
const signbit = zm.signbit;
const sqrt = zm.sqrt;
pub const types = @import("types.zig");
const errors = @import("errors.zig");

const Color = zm.Color;
pub const colorFromHSV = types.colorFromHSV;
pub const Image = types.Image;
const Rng = @import("runtime.zig").effects.rng.Rng;
const codecs = @import("codecs.zig");

const white: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
const black: Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };

fn rgba8Image(data: ?*anyopaque, width: i32, height: i32) Image {
    return .{
        .data = data,
        .width = width,
        .height = height,
        .mipmaps = 1,
        .format = @backingInt(types.PixelFormat.uncompressed_r8g8b8a8),
    };
}

/// Solid-colour RGBA8 image.
pub fn genImageColor(
    gpa: Allocator,
    width: i32,
    height: i32,
    color: Color,
) errors.ImageGenError!Image {
    if (width <= 0 or height <= 0) {
        return error.InvalidDimensions;
    }
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const pixels: []Color = try gpa.alloc(Color, w * h);
    errdefer gpa.free(pixels);
    for (0..w * h) |i| {
        pixels[i] = color;
    }
    return rgba8Image(@ptrCast(pixels.ptr), width, height);
}

/// Checkerboard of `col1`/`col2`, `checks_x`×`checks_y` cells.
pub fn genImageChecked(
    gpa: Allocator,
    width: i32,
    height: i32,
    checks_x: i32,
    checks_y: i32,
    col1: Color,
    col2: Color,
) errors.ImageGenError!Image {
    if (width <= 0 or height <= 0 or checks_x <= 0 or checks_y <= 0) {
        return error.InvalidDimensions;
    }
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const cx: usize = @intCast(checks_x);
    const cy: usize = @intCast(checks_y);
    const pixels: []Color = try gpa.alloc(Color, w * h);
    errdefer gpa.free(pixels);
    for (0..h) |y| {
        for (0..w) |x| {
            pixels[y * w + x] = if ((x / cx + y / cy) % 2 == 0) col1 else col2;
        }
    }
    return rgba8Image(@ptrCast(pixels.ptr), width, height);
}

/// White-noise binary image; `factor` in [0,1] sets the white/black ratio.
/// Uses an explicit `Rng` for reproducibility.
pub fn genImageWhiteNoise(
    gpa: Allocator,
    rng: Rng,
    width: i32,
    height: i32,
    factor: f32,
) errors.ImageGenError!Image {
    if (width <= 0 or height <= 0) {
        return error.InvalidDimensions;
    }
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const pixels: []Color = try gpa.alloc(Color, w * h);
    errdefer gpa.free(pixels);
    const threshold: i32 = @round(factor * 100.0);
    for (0..w * h) |i| {
        pixels[i] = if (rng.value(0, 99) < threshold) white else black;
    }
    return rgba8Image(@ptrCast(pixels.ptr), width, height);
}

inline fn perlinFade(t: f32) f32 {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

/// Ken Perlin's permutation table, doubled so `perm[v + 256]` never overflows.
const perlin_perm = [_]u8{
    151, 160, 137, 91,  90,  15,  131, 13,  201, 95,  96,  53,  194, 233, 7,   225,
    140, 36,  103, 30,  69,  142, 8,   99,  37,  240, 21,  10,  23,  190, 6,   148,
    247, 120, 234, 75,  0,   26,  197, 62,  94,  252, 219, 203, 117, 35,  11,  32,
    57,  177, 33,  88,  237, 149, 56,  87,  174, 20,  125, 136, 171, 168, 68,  175,
    74,  165, 71,  134, 139, 48,  27,  166, 77,  146, 158, 231, 83,  111, 229, 122,
    60,  211, 133, 230, 220, 105, 92,  41,  55,  46,  245, 40,  244, 102, 143, 54,
    65,  25,  63,  161, 1,   216, 80,  73,  209, 76,  132, 187, 208, 89,  18,  169,
    200, 196, 135, 130, 116, 188, 159, 86,  164, 100, 109, 198, 173, 186, 3,   64,
    52,  217, 226, 250, 124, 123, 5,   202, 38,  147, 118, 126, 255, 82,  85,  212,
    207, 206, 59,  227, 47,  16,  58,  17,  182, 189, 28,  42,  223, 183, 170, 213,
    119, 248, 152, 2,   44,  154, 163, 70,  221, 153, 101, 155, 167, 43,  172, 9,
    129, 22,  39,  253, 19,  98,  108, 110, 79,  113, 224, 232, 178, 185, 112, 104,
    218, 246, 97,  228, 251, 34,  242, 193, 238, 210, 144, 12,  191, 179, 162, 241,
    81,  51,  145, 235, 249, 14,  239, 107, 49,  192, 214, 31,  181, 199, 106, 157,
    184, 84,  204, 176, 115, 121, 50,  45,  127, 4,   150, 254, 138, 236, 205, 93,
    222, 114, 67,  29,  24,  72,  243, 141, 128, 195, 78,  66,  215, 61,  156, 180,
    151, 160, 137, 91,  90,  15,  131, 13,  201, 95,  96,  53,  194, 233, 7,   225,
    140, 36,  103, 30,  69,  142, 8,   99,  37,  240, 21,  10,  23,  190, 6,   148,
    247, 120, 234, 75,  0,   26,  197, 62,  94,  252, 219, 203, 117, 35,  11,  32,
    57,  177, 33,  88,  237, 149, 56,  87,  174, 20,  125, 136, 171, 168, 68,  175,
    74,  165, 71,  134, 139, 48,  27,  166, 77,  146, 158, 231, 83,  111, 229, 122,
    60,  211, 133, 230, 220, 105, 92,  41,  55,  46,  245, 40,  244, 102, 143, 54,
    65,  25,  63,  161, 1,   216, 80,  73,  209, 76,  132, 187, 208, 89,  18,  169,
    200, 196, 135, 130, 116, 188, 159, 86,  164, 100, 109, 198, 173, 186, 3,   64,
    52,  217, 226, 250, 124, 123, 5,   202, 38,  147, 118, 126, 255, 82,  85,  212,
    207, 206, 59,  227, 47,  16,  58,  17,  182, 189, 28,  42,  223, 183, 170, 213,
    119, 248, 152, 2,   44,  154, 163, 70,  221, 153, 101, 155, 167, 43,  172, 9,
    129, 22,  39,  253, 19,  98,  108, 110, 79,  113, 224, 232, 178, 185, 112, 104,
    218, 246, 97,  228, 251, 34,  242, 193, 238, 210, 144, 12,  191, 179, 162, 241,
    81,  51,  145, 235, 249, 14,  239, 107, 49,  192, 214, 31,  181, 199, 106, 157,
    184, 84,  204, 176, 115, 121, 50,  45,  127, 4,   150, 254, 138, 236, 205, 93,
    222, 114, 67,  29,  24,  72,  243, 141, 128, 195, 78,  66,  215, 61,  156, 180,
};

inline fn grad2(hash: u8, x: f32, y: f32) f32 {
    return switch (hash & 7) {
        0 => x + y,
        1 => -x + y,
        2 => x - y,
        3 => -x - y,
        4 => x,
        5 => -x,
        6 => y,
        else => -y,
    };
}

fn perlin2(x: f32, y: f32) f32 {
    const xi: i32 = floori(i32, x) & 255;
    const yi: i32 = floori(i32, y) & 255;
    const xf: f32 = x - @floor(x);
    const yf: f32 = y - @floor(y);
    const u: f32 = perlinFade(xf);
    const v: f32 = perlinFade(yf);

    const aa: u8 = perlin_perm[@as(usize, @intCast(perlin_perm[@intCast(xi)])) + @as(usize, @intCast(yi))];
    const ab: u8 = perlin_perm[@as(usize, @intCast(perlin_perm[@intCast(xi)])) + @as(usize, @intCast(yi)) + 1];
    const ba: u8 = perlin_perm[@as(usize, @intCast(perlin_perm[@intCast(xi + 1)])) + @as(usize, @intCast(yi))];
    const bb: u8 = perlin_perm[@as(usize, @intCast(perlin_perm[@intCast(xi + 1)])) + @as(usize, @intCast(yi)) + 1];

    const lerp_a: f32 = lerp(grad2(aa, xf, yf), grad2(ba, xf - 1, yf), u);
    const lerp_b: f32 = lerp(grad2(ab, xf, yf - 1), grad2(bb, xf - 1, yf - 1), u);
    return lerp(lerp_a, lerp_b, v);
}

/// Grayscale 2D Perlin noise. `offset_*` scroll the sample field; `scale`
/// sets feature size (higher = larger features). Deterministic.
pub fn genImagePerlinNoise(
    gpa: Allocator,
    width: i32,
    height: i32,
    offset_x: i32,
    offset_y: i32,
    scale: f32,
) errors.ImageGenError!Image {
    if (width <= 0 or height <= 0) {
        return error.InvalidDimensions;
    }
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const pixels: []Color = try gpa.alloc(Color, w * h);
    errdefer gpa.free(pixels);
    for (0..h) |iy| {
        for (0..w) |ix| {
            const sx: f32 = (float(@as(i32, @intCast(ix)) + offset_x) /
                float(width)) * scale;
            const sy: f32 = (float(@as(i32, @intCast(iy)) + offset_y) /
                float(height)) * scale;
            const n: f32 = perlin2(sx, sy);
            const v: u8 = @round(clamp((n * 0.5 + 0.5) * 255.0, 0.0, 255.0));
            pixels[iy * w + ix] = .{ .r = v, .g = v, .b = v, .a = 255 };
        }
    }
    return rgba8Image(@ptrCast(pixels.ptr), width, height);
}

const Vec2 = zm.Vec2;

/// Deterministic 2D integer hash for genImageCellular's per-cell seeds.
inline fn hash2(x: i32, y: i32, salt: u32) u32 {
    var h: u32 = @bitCast(x);
    h ^= @as(u32, @bitCast(y)) *% 0x9E3779B1;
    h ^= salt *% 0x85EBCA6B;
    h ^= h >> 16;
    h *%= 0x85EBCA6B;
    h ^= h >> 13;
    h *%= 0xC2B2AE35;
    h ^= h >> 16;
    return h;
}

/// Grayscale cellular (Worley) noise: each pixel's value is the distance to
/// the nearest random per-cell seed point, normalized. Deterministic.
pub fn genImageCellular(
    gpa: Allocator,
    width: i32,
    height: i32,
    tile_size: i32,
) errors.ImageGenError!Image {
    if (width <= 0 or height <= 0 or tile_size <= 0) {
        return error.InvalidDimensions;
    }
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const ts: i32 = tile_size;
    const ts_f: f32 = float(tile_size);
    const pixels: []Color = try gpa.alloc(Color, w * h);
    errdefer gpa.free(pixels);

    const cells_x: usize = (@as(usize, @intCast(width)) + @as(usize, @intCast(tile_size)) - 1) /
        @as(usize, @intCast(tile_size)) + 1;
    const cells_y: usize = (@as(usize, @intCast(height)) + @as(usize, @intCast(tile_size)) - 1) /
        @as(usize, @intCast(tile_size)) + 1;
    const seeds: []Vec2 = try gpa.alloc(Vec2, cells_x * cells_y);
    defer gpa.free(seeds);
    for (0..cells_y) |cy| {
        for (0..cells_x) |cx| {
            const h1: u32 = hash2(@intCast(cx), @intCast(cy), 0);
            const h2: u32 = hash2(@intCast(cx), @intCast(cy), 1);
            const fx: f32 = float(h1 & 0xFFFFFF) / @as(f32, 0x1000000);
            const fy: f32 = float(h2 & 0xFFFFFF) / @as(f32, 0x1000000);
            seeds[cy * cells_x + cx] = .{
                (float(@as(i32, @intCast(cx)) * ts)) + fx * ts_f,
                (float(@as(i32, @intCast(cy)) * ts)) + fy * ts_f,
            };
        }
    }

    const norm: f32 = ts_f * sqrt(2.0);
    for (0..h) |iy| {
        for (0..w) |ix| {
            const px: f32 = float(ix);
            const py: f32 = float(iy);
            const cell_x: i32 = @divTrunc(@as(i32, @intCast(ix)), ts);
            const cell_y: i32 = @divTrunc(@as(i32, @intCast(iy)), ts);
            var min_d2: f32 = floatMax(f32);
            for (0..3) |dj| {
                const dy: i32 = @as(i32, @intCast(dj)) - 1;
                for (0..3) |di| {
                    const dx: i32 = @as(i32, @intCast(di)) - 1;
                    const ncx: i32 = cell_x + dx;
                    const ncy: i32 = cell_y + dy;
                    if (ncx < 0 or ncy < 0) {
                        continue;
                    }
                    const ncx_u: usize = @intCast(ncx);
                    const ncy_u: usize = @intCast(ncy);
                    if (ncx_u >= cells_x or ncy_u >= cells_y) {
                        continue;
                    }
                    const seed: Vec2 = seeds[ncy_u * cells_x + ncx_u];
                    const sdx: f32 = seed[0] - px;
                    const sdy: f32 = seed[1] - py;
                    const d2: f32 = sdx * sdx + sdy * sdy;
                    if (d2 < min_d2) {
                        min_d2 = d2;
                    }
                }
            }
            const d: f32 = sqrt(min_d2) / norm;
            const v: u8 = @round(clamp(d * 255.0, 0.0, 255.0));
            pixels[iy * w + ix] = .{ .r = v, .g = v, .b = v, .a = 255 };
        }
    }
    return rgba8Image(@ptrCast(pixels.ptr), width, height);
}

// ---- Noise internals (Ken Perlin's reference permutation + 2D gradient) ----

// ============================================================================
// CPU image manipulation (in-place / allocate-and-swap), extracted from
// drawing.zig. RGBA8-focused — the formats the wgpu examples use; block-
// compressed formats are no-ops, matching the GL behaviour.
// ============================================================================

const gaussian_blur_iterations: i32 = 4;

inline fn imagePixelCount(image: *const Image) usize {
    return @intCast(image.width * image.height);
}

inline fn bytesPerPixel(format: i32) i32 {
    return switch (@as(types.PixelFormat, @fromBackingInt(@intCast(format)))) {
        .uncompressed_grayscale => 1,
        .uncompressed_gray_alpha => 2,
        .uncompressed_r5g6b5 => 2,
        .uncompressed_r5g5b5a1 => 2,
        .uncompressed_r4g4b4a4 => 2,
        .uncompressed_r8g8b8 => 3,
        .uncompressed_r8g8b8a8 => 4,
        .uncompressed_r32 => 4,
        .uncompressed_r32g32b32 => 12,
        .uncompressed_r32g32b32a32 => 16,
        else => 0,
    };
}

/// Total bytes of an Image's pixel buffer across all mipmap levels
/// (uncompressed formats). Returns 0 for unknown/compressed formats.
fn imageDataByteCount(image: Image) usize {
    var w: i32 = image.width;
    var h: i32 = image.height;
    var size: usize = 0;
    for (0..@intCast(image.mipmaps)) |_| {
        size += @intCast(w * h * bytesPerPixel(image.format));
        w = @max(@divTrunc(w, 2), 1);
        h = @max(@divTrunc(h, 2), 1);
    }
    return size;
}

/// Free an Image's pixel buffer (raylib `UnloadImage`). Pass the allocator the
/// image was created with.
pub fn unloadImage(gpa: Allocator, image: Image) void {
    if (image.data == null) {
        return;
    }
    const total: usize = imageDataByteCount(image);
    const buf: [*]u8 = @ptrCast(@alignCast(image.data));
    gpa.free(buf[0..total]);
}

/// Invert RGB of an RGBA8 image in place (alpha unchanged).
pub fn imageColorInvert(image: *Image) void {
    if (image.data == null or image.pixelFormat() != .uncompressed_r8g8b8a8) {
        return;
    }
    const data: [*]u8 = @ptrCast(image.data.?);
    const n: usize = imagePixelCount(image);
    for (0..n) |i| {
        data[i * 4 + 0] = 255 - data[i * 4 + 0];
        data[i * 4 + 1] = 255 - data[i * 4 + 1];
        data[i * 4 + 2] = 255 - data[i * 4 + 2];
    }
}

/// A grid cell's offset (in cells) to the nearest seed, for the 8SSEDT.
const EdtPt = struct { dx: i32, dy: i32 };

fn edtDist2(p: EdtPt) i64 {
    return @as(i64, p.dx) * p.dx + @as(i64, p.dy) * p.dy;
}

/// One 8SSEDT comparison step: if propagating neighbour `(nx,ny)`'s seed
/// (offset by `(ox,oy)`) to cell `i` is closer, take it.
fn edtCompare(
    grid: []EdtPt,
    w: usize,
    h: usize,
    i: usize,
    nx: i64,
    ny: i64,
    ox: i32,
    oy: i32,
) void {
    if (nx < 0 or ny < 0 or nx >= @as(i64, @intCast(w)) or ny >= @as(i64, @intCast(h))) {
        return;
    }
    const ni: usize = @intCast(ny * @as(i64, @intCast(w)) + nx);
    const cand: EdtPt = .{ .dx = grid[ni].dx + ox, .dy = grid[ni].dy + oy };
    if (edtDist2(cand) < edtDist2(grid[i])) {
        grid[i] = cand;
    }
}

/// 8-point sequential Euclidean distance transform: fills each cell with the
/// (dx,dy) offset to the nearest SEED cell (cells that started at (0,0)).
fn edt8(grid: []EdtPt, w: usize, h: usize) void {
    // Forward pass.
    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const i: usize = y * w + x;
            const xi: i64 = @intCast(x);
            const yi: i64 = @intCast(y);
            edtCompare(grid, w, h, i, xi - 1, yi, 1, 0);
            edtCompare(grid, w, h, i, xi, yi - 1, 0, 1);
            edtCompare(grid, w, h, i, xi - 1, yi - 1, 1, 1);
            edtCompare(grid, w, h, i, xi + 1, yi - 1, -1, 1);
        }
        var xr: isize = @as(isize, @intCast(w)) - 2;
        while (xr >= 0) : (xr -= 1) {
            const x2: usize = @intCast(xr);
            const i: usize = y * w + x2;
            edtCompare(grid, w, h, i, @as(i64, @intCast(x2)) + 1, @intCast(y), 1, 0);
        }
    }
    // Backward pass.
    var yb: isize = @as(isize, @intCast(h)) - 1;
    while (yb >= 0) : (yb -= 1) {
        const y2: usize = @intCast(yb);
        var xb: isize = @as(isize, @intCast(w)) - 1;
        while (xb >= 0) : (xb -= 1) {
            const x2: usize = @intCast(xb);
            const i: usize = y2 * w + x2;
            const xi: i64 = @intCast(x2);
            const yi: i64 = @intCast(y2);
            edtCompare(grid, w, h, i, xi + 1, yi, 1, 0);
            edtCompare(grid, w, h, i, xi, yi + 1, 0, 1);
            edtCompare(grid, w, h, i, xi - 1, yi + 1, 1, 1);
            edtCompare(grid, w, h, i, xi + 1, yi + 1, -1, 1);
        }
        var xf: usize = 1;
        while (xf < w) : (xf += 1) {
            const i: usize = y2 * w + xf;
            edtCompare(grid, w, h, i, @as(i64, @intCast(xf)) - 1, @intCast(y2), 1, 0);
        }
    }
}

/// Convert a COVERAGE atlas (RGB white, alpha = glyph coverage) IN PLACE into a
/// signed-distance-field atlas (RGB white, alpha = SDF). The edge (coverage
/// crossing 50%) maps to alpha 0.5; interior rises toward 1, exterior falls
/// toward 0, linearly over ±`spread` pixels. This is the raylib SDF convention
/// (distance in the alpha channel, 0.5 = edge) so a `smoothstep(0.5±w, a)`
/// fragment shader renders it crisp at any scale. Pure CPU (a signed 8SSEDT) —
/// unit-testable headless. RGBA8 image required; `spread` in pixels (> 0).
pub fn coverageToSdf(gpa: Allocator, image: Image, spread: f32) !void {
    if (image.data == null or image.pixelFormat() != .uncompressed_r8g8b8a8 or
        image.width <= 0 or image.height <= 0)
    {
        return;
    }
    const w: usize = @intCast(image.width);
    const h: usize = @intCast(image.height);
    const n: usize = w * h;
    const data: [*]u8 = @ptrCast(image.data.?);

    const inf_pt: EdtPt = .{ .dx = 20000, .dy = 20000 };
    // grid_in seeds on INSIDE cells → distance to nearest inside (for outside cells).
    // grid_out seeds on OUTSIDE cells → distance to nearest outside (for inside cells).
    const grid_in: []EdtPt = try gpa.alloc(EdtPt, n);
    defer gpa.free(grid_in);
    const grid_out: []EdtPt = try gpa.alloc(EdtPt, n);
    defer gpa.free(grid_out);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const inside: bool = data[i * 4 + 3] >= 128;
        grid_in[i] = if (inside) .{ .dx = 0, .dy = 0 } else inf_pt;
        grid_out[i] = if (inside) inf_pt else .{ .dx = 0, .dy = 0 };
    }
    edt8(grid_in, w, h);
    edt8(grid_out, w, h);

    const spread_safe: f32 = @max(spread, 0.0001);
    i = 0;
    while (i < n) : (i += 1) {
        const cov_u: u8 = data[i * 4 + 3];
        const inside: bool = cov_u >= 128;
        // distance to the edge = distance to the nearest opposite-region cell.
        const d2: i64 = if (inside) edtDist2(grid_out[i]) else edtDist2(grid_in[i]);
        const dist: f32 = @sqrt(@as(f32, @floatFromInt(d2)));
        var signed: f32 = if (inside) dist else -dist;
        // Anti-aliased sub-texel refinement. The binary 8SSEDT only knows the
        // edge to ±1 texel — that quantization is what makes magnified curves
        // look faceted. But the SOURCE coverage is anti-aliased: a texel that is
        // fraction c inside sits ~(c - 0.5) px from the true edge. For texels on
        // or beside the boundary, trust that sub-texel value instead of the
        // integer distance; farther texels keep the propagated distance.
        if (dist <= 1.5) {
            const cov: f32 = @as(f32, @floatFromInt(cov_u)) / 255.0;
            signed = (cov - 0.5) * 2.0;
        }
        const norm: f32 = 0.5 + signed / (2.0 * spread_safe);
        const a: f32 = std.math.clamp(norm, 0.0, 1.0);
        data[i * 4 + 0] = 255;
        data[i * 4 + 1] = 255;
        data[i * 4 + 2] = 255;
        data[i * 4 + 3] = @intFromFloat(@round(a * 255.0));
    }
}

test "coverageToSdf: filled square has 0.5 edge, >0.5 inside, <0.5 outside" {
    const w: usize = 16;
    const h: usize = 16;
    var buf: [w * h * 4]u8 = undefined;
    // an 8x8 filled square centred in a 16x16 field
    for (0..h) |y| {
        for (0..w) |x| {
            const inside: bool = (x >= 4 and x < 12 and y >= 4 and y < 12);
            const b: usize = (y * w + x) * 4;
            buf[b + 0] = 255;
            buf[b + 1] = 255;
            buf[b + 2] = 255;
            buf[b + 3] = if (inside) 255 else 0;
        }
    }
    const img: Image = .{
        .data = @ptrCast(&buf),
        .width = @intCast(w),
        .height = @intCast(h),
        .mipmaps = 1,
        .format = @backingInt(types.PixelFormat.uncompressed_r8g8b8a8),
    };
    try coverageToSdf(std.testing.allocator, img, 4.0);
    const at = struct {
        fn a(b: []const u8, x: usize, y: usize) u8 {
            return b[(y * 16 + x) * 4 + 3];
        }
    }.a;
    // deep interior (centre) is brighter than an edge cell, which is brighter
    // than a far-outside cell — the SDF is monotone across the boundary.
    try expect(at(&buf, 7, 7) > at(&buf, 4, 7));
    try expect(at(&buf, 4, 7) >= 120 and at(&buf, 4, 7) <= 160); // near the edge ~0.5
    try expect(at(&buf, 0, 0) < at(&buf, 4, 7)); // far outside is darkest
    try expect(at(&buf, 7, 7) > 128); // interior above the edge level
}

/// Metrics from a raylib-style bitmap-font scan.
pub const SpriteFontLayout = struct {
    char_spacing: u32,
    line_spacing: u32,
    char_height: u32,
    /// Number of glyphs written into `out_recs` / `out_vals`.
    count: u32,
};

pub const SpriteFontError = error{ InvalidImage, NoGlyphs };

/// True if the RGBA8 pixel at flat index `i` (pixel index, not byte) equals key.
fn spriteFontKeyMatch(data: [*]const u8, i: usize, key: Color) bool {
    const b: usize = i * 4;
    return data[b + 0] == key.r and data[b + 1] == key.g and
        data[b + 2] == key.b and data[b + 3] == key.a;
}

/// Segment a raylib-style bitmap-font image into glyph rectangles — a faithful
/// port of raylib's `LoadFontFromImage` scan, with NO GPU dependency so it is
/// unit-testable headless. Glyphs sit on a `key`-coloured background; the first
/// non-key pixel (row-major) gives the shared `charSpacing`/`lineSpacing`
/// border, the first glyph column gives `charHeight`, then each line band is
/// walked left-to-right splitting glyphs on key columns. Fills `out_recs` /
/// `out_vals` (glyph value = `first_char + index`), capped at the smaller of
/// the two slice lengths, and returns the layout. RGBA8 image required.
pub fn segmentSpriteFont(
    image: Image,
    key: Color,
    first_char: i32,
    out_recs: []Rectangle,
    out_vals: []i32,
) SpriteFontError!SpriteFontLayout {
    if (image.width <= 0 or image.height <= 0 or image.data == null or
        image.pixelFormat() != .uncompressed_r8g8b8a8)
    {
        return SpriteFontError.InvalidImage;
    }
    const w: usize = @intCast(image.width);
    const h: usize = @intCast(image.height);
    const data: [*]const u8 = @ptrCast(image.data.?);
    const cap: usize = @min(out_recs.len, out_vals.len);

    // Border = first non-key pixel (row-major).
    var char_spacing: usize = 0;
    var line_spacing: usize = 0;
    var found: bool = false;
    {
        var y: usize = 0;
        scan: while (y < h) : (y += 1) {
            var x: usize = 0;
            while (x < w) : (x += 1) {
                if (!spriteFontKeyMatch(data, y * w + x, key)) {
                    char_spacing = x;
                    line_spacing = y;
                    found = true;
                    break :scan;
                }
            }
        }
    }
    if (!found or char_spacing == 0 or line_spacing == 0) {
        return SpriteFontError.NoGlyphs;
    }

    // charHeight: down from the first glyph's top-left until key.
    var char_height: usize = 0;
    while (line_spacing + char_height < h and
        !spriteFontKeyMatch(data, (line_spacing + char_height) * w + char_spacing, key)) : (char_height += 1)
    {}
    if (char_height == 0) {
        return SpriteFontError.NoGlyphs;
    }

    var count: usize = 0;
    var line: usize = 0;
    while (line_spacing + line * (char_height + line_spacing) < h) : (line += 1) {
        const band_y: usize = line_spacing + (char_height + line_spacing) * line;
        var xp: usize = char_spacing;
        while (xp < w and !spriteFontKeyMatch(data, band_y * w + xp, key)) {
            if (count >= cap) {
                break;
            }
            var cw: usize = 0;
            while (xp + cw < w and !spriteFontKeyMatch(data, band_y * w + xp + cw, key)) : (cw += 1) {}
            out_vals[count] = first_char + @as(i32, @intCast(count));
            out_recs[count] = .{
                .x = @floatFromInt(xp),
                .y = @floatFromInt(band_y),
                .width = @floatFromInt(cw),
                .height = @floatFromInt(char_height),
            };
            count += 1;
            xp += cw + char_spacing;
        }
    }
    if (count == 0) {
        return SpriteFontError.NoGlyphs;
    }
    return .{
        .char_spacing = @intCast(char_spacing),
        .line_spacing = @intCast(line_spacing),
        .char_height = @intCast(char_height),
        .count = @intCast(count),
    };
}

test "segmentSpriteFont: 2 glyphs, 1px key border" {
    // 8x5 RGBA8: 1px magenta border/separators, two glyphs (w=2 and w=3),
    // charHeight=3. Layout (K=key, G=glyph):
    //   row0: K K K K K K K K
    //   row1: K G G K G G G K
    //   row2..3 same as row1
    //   row4: K K K K K K K K
    const K = [4]u8{ 255, 0, 255, 255 };
    const G = [4]u8{ 10, 20, 30, 255 };
    const w: usize = 8;
    const h: usize = 5;
    var buf: [w * h * 4]u8 = undefined;
    for (0..h) |y| {
        for (0..w) |x| {
            const glyph: bool = (y >= 1 and y <= 3) and
                ((x >= 1 and x <= 2) or (x >= 4 and x <= 6));
            const c: [4]u8 = if (glyph) G else K;
            @memcpy(buf[(y * w + x) * 4 ..][0..4], &c);
        }
    }
    const img: Image = .{
        .data = &buf,
        .width = @intCast(w),
        .height = @intCast(h),
        .mipmaps = 1,
        .format = @backingInt(types.PixelFormat.uncompressed_r8g8b8a8),
    };
    const key: Color = .{ .r = 255, .g = 0, .b = 255, .a = 255 };
    var recs: [16]Rectangle = undefined;
    var vals: [16]i32 = undefined;
    const lay: SpriteFontLayout = try segmentSpriteFont(img, key, 32, &recs, &vals);
    try expectEqual(@as(u32, 1), lay.char_spacing);
    try expectEqual(@as(u32, 1), lay.line_spacing);
    try expectEqual(@as(u32, 3), lay.char_height);
    try expectEqual(@as(u32, 2), lay.count);
    try expectEqual(@as(i32, 32), vals[0]);
    try expectEqual(@as(i32, 33), vals[1]);
    try expectEqual(@as(f32, 1), recs[0].x);
    try expectEqual(@as(f32, 1), recs[0].y);
    try expectEqual(@as(f32, 2), recs[0].width);
    try expectEqual(@as(f32, 3), recs[0].height);
    try expectEqual(@as(f32, 4), recs[1].x);
    try expectEqual(@as(f32, 3), recs[1].width);
}

test "segmentSpriteFont: all-key image errors" {
    const K = [4]u8{ 255, 0, 255, 255 };
    var buf: [4 * 4 * 4]u8 = undefined;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        @memcpy(buf[i * 4 ..][0..4], &K);
    }
    const img: Image = .{
        .data = &buf,
        .width = 4,
        .height = 4,
        .mipmaps = 1,
        .format = @backingInt(types.PixelFormat.uncompressed_r8g8b8a8),
    };
    var recs: [4]Rectangle = undefined;
    var vals: [4]i32 = undefined;
    try expectError(
        SpriteFontError.NoGlyphs,
        segmentSpriteFont(img, .{ .r = 255, .g = 0, .b = 255, .a = 255 }, 32, &recs, &vals),
    );
}

/// Premultiply RGB by alpha in place (RGBA8). Used before box-blurring so the
/// averaging doesn't bleed unrelated RGB across alpha edges.
fn imageAlphaPremultiply(image: *Image) void {
    if (image.data == null or image.pixelFormat() != .uncompressed_r8g8b8a8) {
        return;
    }
    const data: [*]u8 = @ptrCast(image.data.?);
    const n: usize = imagePixelCount(image);
    for (0..n) |i| {
        const a = float(data[i * 4 + 3]) / 255.0;
        data[i * 4 + 0] = @round(float(data[i * 4 + 0]) * a);
        data[i * 4 + 1] = @round(float(data[i * 4 + 1]) * a);
        data[i * 4 + 2] = @round(float(data[i * 4 + 2]) * a);
    }
}

/// Deep-copy an Image (all mipmap levels). The returned Image owns its pixel
/// buffer independently; free it with `unloadImage` using the same allocator.
pub fn imageCopy(gpa: Allocator, image: Image) errors.ImageGenError!Image {
    if (image.data == null) {
        return error.InvalidDimensions;
    }
    const size: usize = imageDataByteCount(image);
    const new_pixels: []u8 = try gpa.alloc(u8, size);
    errdefer gpa.free(new_pixels);
    @memcpy(new_pixels, @as([*]const u8, @ptrCast(image.data))[0..size]);
    return .{
        .data = @ptrCast(new_pixels.ptr),
        .width = image.width,
        .height = image.height,
        .mipmaps = image.mipmaps,
        .format = image.format,
    };
}

/// Rotate an image 90° clockwise in place (allocate-and-swap). Pass the same
/// allocator the image was created with.
pub fn imageRotateCW(gpa: Allocator, image: *Image) Allocator.Error!void {
    if (image.data == null or image.width == 0 or image.height == 0) {
        return;
    }
    const bpp_i: i32 = bytesPerPixel(image.format);
    if (bpp_i == 0) {
        return;
    }
    const bpp: usize = @intCast(bpp_i);
    const w: usize = @intCast(image.width);
    const h: usize = @intCast(image.height);

    const new_pixels: []u8 = try gpa.alloc(u8, w * h * bpp);
    errdefer gpa.free(new_pixels);
    const rotated: [*]u8 = new_pixels.ptr;
    const src: [*]const u8 = @ptrCast(image.data.?);
    for (0..h) |y| {
        for (0..w) |x| {
            // (x, y) source → (h-y-1, x) destination (rotate 90 CW).
            const dst_idx: usize = (x * h + (h - y - 1)) * bpp;
            const src_idx: usize = (y * w + x) * bpp;
            for (0..bpp) |k| {
                rotated[dst_idx + k] = src[src_idx + k];
            }
        }
    }
    unloadImage(gpa, image.*);
    image.data = @ptrCast(new_pixels.ptr);
    const tmp: i32 = image.width;
    image.width = image.height;
    image.height = tmp;
}

/// Gaussian blur (separable box blur, 4 iterations) of an RGBA8 image in place.
pub fn imageBlurGaussian(
    gpa: Allocator,
    image: *Image,
    blurSize: i32,
) Allocator.Error!void {
    if (image.data == null or image.width == 0 or image.height == 0) {
        return;
    }
    if (image.pixelFormat() != .uncompressed_r8g8b8a8) {
        return;
    }
    if (blurSize < 1) {
        return;
    }
    imageAlphaPremultiply(image);

    const w: usize = @intCast(image.width);
    const h: usize = @intCast(image.height);
    const pixel_count: usize = w * h;

    const buf1: []f32 = try gpa.alloc(f32, pixel_count * 4);
    defer gpa.free(buf1);
    const buf2: []f32 = try gpa.alloc(f32, pixel_count * 4);
    defer gpa.free(buf2);

    const img_data: [*]u8 = @ptrCast(image.data.?);
    for (0..pixel_count) |i| {
        buf1[i * 4 + 0] = @floatFromInt(img_data[i * 4 + 0]);
        buf1[i * 4 + 1] = @floatFromInt(img_data[i * 4 + 1]);
        buf1[i * 4 + 2] = @floatFromInt(img_data[i * 4 + 2]);
        buf1[i * 4 + 3] = @floatFromInt(img_data[i * 4 + 3]);
    }

    const bs: i32 = blurSize;
    for (0..@intCast(gaussian_blur_iterations)) |_| {
        // ---- Horizontal pass (buf1 → buf2) ----
        for (0..@intCast(image.height)) |rowu| {
            const row: i32 = @intCast(rowu);
            var avg_r: f32 = 0;
            var avg_g: f32 = 0;
            var avg_b: f32 = 0;
            var avg_a: f32 = 0;
            var conv_size: i32 = bs;
            const r_off: usize = @intCast(row * image.width);

            var k: i32 = 0;
            while (k < bs and k < image.width) : (k += 1) {
                const idx = (r_off + @as(usize, @intCast(k))) * 4;
                avg_r += buf1[idx + 0];
                avg_g += buf1[idx + 1];
                avg_b += buf1[idx + 2];
                avg_a += buf1[idx + 3];
            }

            for (0..@intCast(image.width)) |xu| {
                const x: i32 = @intCast(xu);
                if (x - bs - 1 >= 0) {
                    const idx = (r_off + @as(usize, @intCast(x - bs - 1))) * 4;
                    avg_r -= buf1[idx + 0];
                    avg_g -= buf1[idx + 1];
                    avg_b -= buf1[idx + 2];
                    avg_a -= buf1[idx + 3];
                    conv_size -= 1;
                }
                if (x + bs < image.width) {
                    const idx = (r_off + @as(usize, @intCast(x + bs))) * 4;
                    avg_r += buf1[idx + 0];
                    avg_g += buf1[idx + 1];
                    avg_b += buf1[idx + 2];
                    avg_a += buf1[idx + 3];
                    conv_size += 1;
                }
                const cs_f: f32 = float(conv_size);
                const idx = (r_off + @as(usize, @intCast(x))) * 4;
                buf2[idx + 0] = avg_r / cs_f;
                buf2[idx + 1] = avg_g / cs_f;
                buf2[idx + 2] = avg_b / cs_f;
                buf2[idx + 3] = avg_a / cs_f;
            }
        }

        // ---- Vertical pass (buf2 → buf1) ----
        for (0..@intCast(image.width)) |colu| {
            const col: i32 = @intCast(colu);
            var avg_r: f32 = 0;
            var avg_g: f32 = 0;
            var avg_b: f32 = 0;
            var avg_a: f32 = 0;
            var conv_size: i32 = bs;

            var k: i32 = 0;
            while (k < bs and k < image.height) : (k += 1) {
                const idx = (@as(usize, @intCast(k)) * w + @as(usize, @intCast(col))) * 4;
                avg_r += buf2[idx + 0];
                avg_g += buf2[idx + 1];
                avg_b += buf2[idx + 2];
                avg_a += buf2[idx + 3];
            }

            for (0..@intCast(image.height)) |yu| {
                const y: i32 = @intCast(yu);
                if (y - bs - 1 >= 0) {
                    const idx = (@as(usize, @intCast(y - bs - 1)) * w + @as(usize, @intCast(col))) * 4;
                    avg_r -= buf2[idx + 0];
                    avg_g -= buf2[idx + 1];
                    avg_b -= buf2[idx + 2];
                    avg_a -= buf2[idx + 3];
                    conv_size -= 1;
                }
                if (y + bs < image.height) {
                    const idx = (@as(usize, @intCast(y + bs)) * w + @as(usize, @intCast(col))) * 4;
                    avg_r += buf2[idx + 0];
                    avg_g += buf2[idx + 1];
                    avg_b += buf2[idx + 2];
                    avg_a += buf2[idx + 3];
                    conv_size += 1;
                }
                const cs_f: f32 = float(conv_size);
                const idx = (@as(usize, @intCast(y)) * w + @as(usize, @intCast(col))) * 4;
                buf1[idx + 0] = avg_r / cs_f;
                buf1[idx + 1] = avg_g / cs_f;
                buf1[idx + 2] = avg_b / cs_f;
                buf1[idx + 3] = avg_a / cs_f;
            }
        }
    }

    // Reverse-premultiply and write back to image.data.
    for (0..pixel_count) |i| {
        const a: f32 = buf1[i * 4 + 3];
        if (a == 0.0) {
            img_data[i * 4 + 0] = 0;
            img_data[i * 4 + 1] = 0;
            img_data[i * 4 + 2] = 0;
            img_data[i * 4 + 3] = 0;
        } else {
            const inv_a: f32 = 255.0 / a;
            img_data[i * 4 + 0] = @trunc(@min(255.0, buf1[i * 4 + 0] * inv_a));
            img_data[i * 4 + 1] = @trunc(@min(255.0, buf1[i * 4 + 1] * inv_a));
            img_data[i * 4 + 2] = @trunc(@min(255.0, buf1[i * 4 + 2] * inv_a));
            img_data[i * 4 + 3] = @trunc(@min(255.0, a));
        }
    }
}

test "image: invert + rotateCW + copy round-trip" {
    const a: Allocator = std.testing.allocator;
    var img: Image = try genImageColor(a, 3, 2, .{ .r = 10, .g = 20, .b = 30, .a = 255 });
    defer unloadImage(a, img);

    imageColorInvert(&img);
    const px: [*]Color = @ptrCast(@alignCast(img.data.?));
    try expectEqual(@as(u8, 245), px[0].r); // 255-10
    try expectEqual(@as(u8, 255), px[0].a); // alpha unchanged

    const dup: Image = try imageCopy(a, img);
    defer unloadImage(a, dup);
    try expectEqual(img.width, dup.width);

    try imageRotateCW(a, &img); // 3x2 -> 2x3
    try expectEqual(@as(i32, 2), img.width);
    try expectEqual(@as(i32, 3), img.height);
}

test "image: genImageColor fills RGBA8" {
    const img: Image = try genImageColor(std.testing.allocator, 4, 3, .{ .r = 10, .g = 20, .b = 30, .a = 255 });
    const px: [*]Color = @ptrCast(@alignCast(img.data.?));
    const n: usize = @as(usize, @intCast(img.width)) * @as(usize, @intCast(img.height));
    defer std.testing.allocator.free(px[0..n]);
    try expectEqual(@as(i32, 4), img.width);
    try expectEqual(@as(i32, 3), img.height);
    try expectEqual(@as(u8, 20), px[5].g);
}

test "image: perlin noise is deterministic + in range" {
    const a: Image = try genImagePerlinNoise(std.testing.allocator, 8, 8, 0, 0, 4.0);
    const pa: [*]Color = @ptrCast(@alignCast(a.data.?));
    const na: usize = @as(usize, @intCast(a.width)) * @as(usize, @intCast(a.height));
    defer std.testing.allocator.free(pa[0..na]);
    const b: Image = try genImagePerlinNoise(std.testing.allocator, 8, 8, 0, 0, 4.0);
    const pb: [*]Color = @ptrCast(@alignCast(b.data.?));
    const nb: usize = @as(usize, @intCast(b.width)) * @as(usize, @intCast(b.height));
    defer std.testing.allocator.free(pb[0..nb]);
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        try expectEqual(pa[i].r, pb[i].r); // reproducible
    }
}

// ===========================================================================
// CPU image-processing library — MOVED from drawing.zig's `textures`
// namespace (GL-retirement P5).  Pure-CPU raylib image ops: gradients,
// noise, crops, resizes, rotations, draws-into-image, color transforms.
// The 12 GL-texture fns of that namespace died with the GL backend
// (wgpu_app owns texture upload/RTT); 10 fns that already existed here
// kept this file's versions.
// ===========================================================================

const z = struct {
    pub const colorFromHSV = types.colorFromHSV;
    pub const Rectangle = types.Rectangle;
    pub const Texture = types.Texture;
    pub const Image = types.Image;
    pub const RenderTexture = types.RenderTexture;
    pub const NPatchInfo = types.NPatchInfo;
};

const Vec = zm.Vec;
const Rectangle = z.Rectangle;
const Texture = z.Texture;

// rlgl externs (same surface as shapes.zig)
// rlgl entry points are reached through `rl` which forwards directly to
// rlgl.zig via @import.  See ZIGGIFY_NOTES.md Session N+3 for why we
// don't use `extern fn` declarations for cross-module calls anymore.

// Texture drawing
/// Draw a texture with full control: source rect, destination rect,
/// rotation pivot (origin, relative to dest top-left), and rotation
/// in radians.
pub fn drawTexturePro(
    gl: anytype,
    texture: Texture,
    source_in: Rectangle,
    dest_in: Rectangle,
    origin: Vec2,
    rotation_rad: f32,
    tint: Color,
) void {
    if (texture.id == 0) {
        return;
    }
    var source: Rectangle = source_in;
    var dest: Rectangle = dest_in;
    const w: f32 = float(texture.width);
    const h: f32 = float(texture.height);

    var flip_x: bool = false;
    if (source.width < 0) {
        flip_x = true;
        source.width *= -1;
    }
    if (source.height < 0) {
        source.y -= source.height;
    }
    if (dest.width < 0) {
        dest.width *= -1;
    }
    if (dest.height < 0) {
        dest.height *= -1;
    }

    var top_left: Vec2 = undefined;
    var top_right: Vec2 = undefined;
    var bottom_left: Vec2 = undefined;
    var bottom_right: Vec2 = undefined;

    if (rotation_rad == 0.0) {
        const x: f32 = dest.x - origin[0];
        const y: f32 = dest.y - origin[1];
        top_left = .{ x, y };
        top_right = .{ x + dest.width, y };
        bottom_left = .{ x, y + dest.height };
        bottom_right = .{ x + dest.width, y + dest.height };
    } else {
        const sinr: f32 = @sin(rotation_rad);
        const cosr: f32 = @cos(rotation_rad);
        const x: f32 = dest.x;
        const y: f32 = dest.y;
        const dx: f32 = -origin[0];
        const dy: f32 = -origin[1];
        top_left = .{ x + dx * cosr - dy * sinr, y + dx * sinr + dy * cosr };
        top_right = .{ x + (dx + dest.width) * cosr - dy * sinr, y + (dx + dest.width) * sinr + dy * cosr };
        bottom_left = .{ x + dx * cosr - (dy + dest.height) * sinr, y + dx * sinr + (dy + dest.height) * cosr };
        bottom_right = .{
            x + (dx + dest.width) * cosr - (dy + dest.height) * sinr,
            y + (dx + dest.width) * sinr + (dy + dest.height) * cosr,
        };
    }

    gl.setTexture(texture.id);
    gl.begin(.quads);
    gl.color4ub(tint.r, tint.g, tint.b, tint.a);
    gl.normal3f(0, 0, 1);

    // Top-left
    if (flip_x) {
        gl.texCoord2f((source.x + source.width) / w, source.y / h);
    } else {
        gl.texCoord2f(source.x / w, source.y / h);
    }
    gl.vertex2f(top_left[0], top_left[1]);
    // Bottom-left
    if (flip_x) {
        gl.texCoord2f((source.x + source.width) / w, (source.y + source.height) / h);
    } else {
        gl.texCoord2f(source.x / w, (source.y + source.height) / h);
    }
    gl.vertex2f(bottom_left[0], bottom_left[1]);
    // Bottom-right
    if (flip_x) {
        gl.texCoord2f(source.x / w, (source.y + source.height) / h);
    } else {
        gl.texCoord2f((source.x + source.width) / w, (source.y + source.height) / h);
    }
    gl.vertex2f(bottom_right[0], bottom_right[1]);
    // Top-right
    if (flip_x) {
        gl.texCoord2f(source.x / w, source.y / h);
    } else {
        gl.texCoord2f((source.x + source.width) / w, source.y / h);
    }
    gl.vertex2f(top_right[0], top_right[1]);

    gl.end();
    // NOTE: deliberately NO `gl.setTexture(0)` reset here. Resetting to the
    // white material after every textured quad turned a glyph run into one
    // flush+draw PER GLYPH (drawCodepoint calls this per glyph), because the
    // atlas→white swap flushes the staged geometry. Every draw fn binds its
    // OWN material up front (shapes bind white, text binds the atlas), so the
    // reset was redundant; dropping it lets consecutive same-texture quads
    // (a whole text run, a sprite sheet) batch into one draw.
}

/// Draw a texture with rotation (radians) and uniform scale.
pub fn drawTextureRotated(
    gl: anytype,
    texture: Texture,
    position: Vec2,
    rotation_rad: f32,
    scale: f32,
    tint: Color,
) void {
    const w: f32 = float(texture.width);
    const h: f32 = float(texture.height);
    const source: Rectangle = .{ .x = 0, .y = 0, .width = w, .height = h };
    const dest: Rectangle = .{ .x = position[0], .y = position[1], .width = w * scale, .height = h * scale };
    drawTexturePro(gl, texture, source, dest, .{ 0, 0 }, rotation_rad, tint);
}

/// Draw a texture at (posX, posY).
pub fn drawTexture(
    gl: anytype,
    texture: Texture,
    posX: i32,
    posY: i32,
    tint: Color,
) void {
    drawTextureRotated(gl, texture, .{ @floatFromInt(posX), @floatFromInt(posY) }, 0, 1.0, tint);
}

/// Draw a texture at a Vec2 position.
pub fn drawTextureV(
    gl: anytype,
    texture: Texture,
    position: Vec2,
    tint: Color,
) void {
    drawTextureRotated(gl, texture, position, 0, 1.0, tint);
}

/// Draw a sub-rectangle of a texture at `position`.
pub fn drawTextureRec(
    gl: anytype,
    texture: Texture,
    source: Rectangle,
    position: Vec2,
    tint: Color,
) void {
    const dest: Rectangle = .{
        .x = position[0],
        .y = position[1],
        .width = @abs(source.width),
        .height = @abs(source.height),
    };
    drawTexturePro(gl, texture, source, dest, .{ 0, 0 }, 0.0, tint);
}

// Texture validity helpers
pub fn isTextureValid(texture: Texture) bool {
    return texture.id > 0;
}

pub fn isImageValid(image: z.Image) bool {
    return image.data != null and image.width > 0 and image.height > 0 and image.format > 0;
}

pub fn isRenderTextureValid(target: z.RenderTexture) bool {
    return target.id > 0 and target.texture.id > 0 and target.depth.id > 0;
}

// Color helpers (pure functions)
/// Compare two colors for component-wise equality.
pub fn colorIsEqual(col1: Color, col2: Color) bool {
    return col1.r == col2.r and col1.g == col2.g and col1.b == col2.b and col1.a == col2.a;
}

/// Apply a normalized alpha [0, 1] to an existing color (replaces alpha
/// channel; leaves RGB unchanged).
pub fn fade(color: Color, alpha_in: f32) Color {
    return color.fade(alpha_in);
}

/// Pack a Color into a 0xRRGGBBAA hex int.
pub fn colorToInt(color: Color) i32 {
    return @bitCast(color.toHex());
}

/// Convert a Color to four floats in [0, 1].
pub fn colorNormalize(color: Color) Vec {
    return color.toVec();
}

/// Convert four normalized floats back to Color.
pub fn colorFromNormalized(normalized: Vec) Color {
    return Color.fromVec(normalized); // fromVec clamps to [0,1] (raylib semantics)
}

/// Convert a Color to HSV. Hue in [0, 360], saturation/value in [0, 1].
pub fn colorToHSV(color: Color) Vec {
    var hsv: Vec = color.toHSV(); // 0..1 from zm
    hsv[0] *= 360.0; // raylib hue is degrees
    return hsv;
}

/// Multiply two colors component-wise (each channel scaled by the
/// corresponding tint channel / 255).
pub fn colorTint(color: Color, tint: Color) Color {
    return .{
        .r = @intCast(@divFloor(@as(i32, color.r) * @as(i32, tint.r), 255)),
        .g = @intCast(@divFloor(@as(i32, color.g) * @as(i32, tint.g), 255)),
        .b = @intCast(@divFloor(@as(i32, color.b) * @as(i32, tint.b), 255)),
        .a = @intCast(@divFloor(@as(i32, color.a) * @as(i32, tint.a), 255)),
    };
}

/// Adjust brightness in [-1, 1]. Negative values darken, positive lighten.
pub fn colorBrightness(color: Color, factor_in: f32) Color {
    var factor: f32 = factor_in;
    if (factor > 1.0) {
        factor = 1.0;
    }
    if (factor < -1.0) {
        factor = -1.0;
    }
    var r = float(color.r);
    var g = float(color.g);
    var b = float(color.b);
    if (factor < 0) {
        const f: f32 = 1.0 + factor;
        r *= f;
        g *= f;
        b *= f;
    } else {
        r = (255 - r) * factor + r;
        g = (255 - g) * factor + g;
        b = (255 - b) * factor + b;
    }
    return .{ .r = @trunc(r), .g = @trunc(g), .b = @trunc(b), .a = color.a };
}

/// Adjust contrast in [-1, 1]. Pivots around 0.5 (mid-gray).
pub fn colorContrast(color: Color, contrast_in: f32) Color {
    var contrast: f32 = contrast_in;
    if (contrast < -1.0) {
        contrast = -1.0;
    }
    if (contrast > 1.0) {
        contrast = 1.0;
    }
    contrast = (1.0 + contrast);
    contrast *= contrast;

    const adjustChannel = struct {
        fn go(channel: u8, c: f32) u8 {
            var p = float(channel) / 255.0;
            p -= 0.5;
            p *= c;
            p += 0.5;
            p *= 255.0;
            if (p < 0) p = 0;
            if (p > 255) p = 255;
            return @trunc(p);
        }
    }.go;

    return .{
        .r = adjustChannel(color.r, contrast),
        .g = adjustChannel(color.g, contrast),
        .b = adjustChannel(color.b, contrast),
        .a = color.a,
    };
}

/// Replace alpha channel with normalized alpha [0, 1].
pub fn colorAlpha(color: Color, alpha_in: f32) Color {
    return color.alpha(alpha_in);
}

/// Alpha-blend `src` (with `tint` applied) onto `dst`. Uses 8-bit
/// integer math, matching raylib's COLORALPHABLEND_INTEGERS path.
pub fn colorAlphaBlend(
    dst: Color,
    src_in: Color,
    tint: Color,
) Color {
    var src: Color = src_in;
    src.r = @intCast((@as(i32, src.r) * (@as(i32, tint.r) + 1)) >> 8);
    src.g = @intCast((@as(i32, src.g) * (@as(i32, tint.g) + 1)) >> 8);
    src.b = @intCast((@as(i32, src.b) * (@as(i32, tint.b) + 1)) >> 8);
    src.a = @intCast((@as(i32, src.a) * (@as(i32, tint.a) + 1)) >> 8);

    if (src.a == 0) {
        return dst;
    }
    if (src.a == 255) {
        return src;
    }

    const alpha: i32 = @as(i32, src.a) + 1;
    var result: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    result.a = @intCast((alpha * 256 + @as(i32, dst.a) * (256 - alpha)) >> 8);
    if (result.a > 0) {
        const ra = @as(i32, result.a);
        result.r = @intCast(
            @divFloor(@as(i32, src.r) * alpha * 256 + @as(i32, dst.r) * @as(i32, dst.a) * (256 - alpha), ra) >> 8,
        );
        result.g = @intCast(
            @divFloor(@as(i32, src.g) * alpha * 256 + @as(i32, dst.g) * @as(i32, dst.a) * (256 - alpha), ra) >> 8,
        );
        result.b = @intCast(
            @divFloor(@as(i32, src.b) * alpha * 256 + @as(i32, dst.b) * @as(i32, dst.a) * (256 - alpha), ra) >> 8,
        );
    }
    return result;
}

/// Linearly interpolate between two colors. `factor` is clamped to [0, 1].
pub fn colorLerp(color1: Color, color2: Color, factor_in: f32) Color {
    return color1.lerp(color2, clamp(factor_in, 0.0, 1.0));
}

/// Unpack a 0xRRGGBBAA hex value into a Color.
pub fn getColor(hexValue: u32) Color {
    return .{
        .r = @intCast((hexValue >> 24) & 0xff),
        .g = @intCast((hexValue >> 16) & 0xff),
        .b = @intCast((hexValue >> 8) & 0xff),
        .a = @intCast(hexValue & 0xff),
    };
}

// Pixel-format helpers
/// Compute byte size of an image with given dimensions and pixel format.
/// Behaviour matches raylib's `GetPixelDataSize` (rtextures.c) - the
/// HDR-format bpp values (R32=32, R16=16, R32G32B32=96, …) are
/// raylib's, NOT what an earlier zimr version had (which mistakenly
/// returned 8 bpp for R32/R16 and 32 bpp for R32G32B32 / R16G16B16A16).
pub fn getPixelDataSize(width: i32, height: i32, format: i32) i32 {
    const fmt: types.PixelFormat = @fromBackingInt(@intCast(format));
    const bpp: i32 = switch (fmt) {
        .uncompressed_grayscale => 8,
        .uncompressed_gray_alpha,
        .uncompressed_r5g6b5,
        .uncompressed_r5g5b5a1,
        .uncompressed_r4g4b4a4,
        .uncompressed_r16,
        => 16,
        .uncompressed_r8g8b8 => 24,
        .uncompressed_r8g8b8a8,
        .uncompressed_r32,
        => 32,
        .uncompressed_r16g16b16 => 48, // 16 × 3
        .uncompressed_r16g16b16a16 => 64, // 16 × 4
        .uncompressed_r32g32b32 => 96, // 32 × 3
        .uncompressed_r32g32b32a32 => 128, // 32 × 4
        // Compressed-block formats are 4-bpp or 8-bpp at the
        // 4×4-block level; row/column rounding handled below.
        .compressed_dxt1_rgb,
        .compressed_dxt1_rgba,
        .compressed_etc1_rgb,
        .compressed_etc2_rgb,
        .compressed_pvrt_rgb,
        .compressed_pvrt_rgba,
        => 4,
        .compressed_dxt3_rgba,
        .compressed_dxt5_rgba,
        .compressed_etc2_eac_rgba,
        .compressed_astc_4x4_rgba,
        => 8,
        .compressed_astc_8x8_rgba => 2,
    };

    var dataSize: i32 = @divFloor(width * height * bpp, 8);

    // Compressed formats are stored in 4×4 blocks; round dims up.
    const is_compressed: bool = switch (fmt) {
        .compressed_dxt1_rgb,
        .compressed_dxt1_rgba,
        .compressed_dxt3_rgba,
        .compressed_dxt5_rgba,
        .compressed_etc1_rgb,
        .compressed_etc2_rgb,
        .compressed_etc2_eac_rgba,
        .compressed_pvrt_rgb,
        .compressed_pvrt_rgba,
        .compressed_astc_4x4_rgba,
        .compressed_astc_8x8_rgba,
        => true,
        else => false,
    };
    if (is_compressed and (@mod(width, 4) != 0 or @mod(height, 4) != 0)) {
        const new_w: i32 = ((@divFloor(width, 4)) + 1) * 4;
        const new_h: i32 = ((@divFloor(height, 4)) + 1) * 4;
        dataSize = @divFloor(new_w * new_h * bpp, 8);
    }
    return dataSize;
}

// Image software-draw functions
//
// These all operate on `Image` pixel buffers in CPU memory (not GPU
// textures). Common case: prepare an Image with custom drawing, then
// upload to GPU via LoadTextureFromImage. Pixel format dispatch covers
// the three formats used 99% of the time in practice; rare formats
// (compressed, half-float) are silently skipped.

// Pixel format constants (matching raylib's PixelFormat enum).

/// Set a single pixel in an Image, dispatching on `dst.format`. Out-of-
/// bounds writes silently no-op (matches raylib's bounds-check).
pub fn imageDrawPixel(
    dst: *Image,
    x: i32,
    y: i32,
    color: Color,
) void {
    if (dst.data == null) {
        return;
    }
    if (x < 0 or x >= dst.width or y < 0 or y >= dst.height) {
        return;
    }
    const idx: usize = @intCast(y * dst.width + x);
    const data: [*]u8 = @ptrCast(dst.data.?);
    switch (dst.pixelFormat()) {
        .uncompressed_grayscale => {
            // Luma weights = 0.299 R + 0.587 G + 0.114 B
            const r = float(color.r) / 255.0;
            const g = float(color.g) / 255.0;
            const b = float(color.b) / 255.0;
            data[idx] = @trunc((r * 0.299 + g * 0.587 + b * 0.114) * 255.0);
        },
        .uncompressed_gray_alpha => {
            const r = float(color.r) / 255.0;
            const g = float(color.g) / 255.0;
            const b = float(color.b) / 255.0;
            data[idx * 2 + 0] = @trunc((r * 0.299 + g * 0.587 + b * 0.114) * 255.0);
            data[idx * 2 + 1] = color.a;
        },
        .uncompressed_r8g8b8 => {
            data[idx * 3 + 0] = color.r;
            data[idx * 3 + 1] = color.g;
            data[idx * 3 + 2] = color.b;
        },
        .uncompressed_r8g8b8a8 => {
            data[idx * 4 + 0] = color.r;
            data[idx * 4 + 1] = color.g;
            data[idx * 4 + 2] = color.b;
            data[idx * 4 + 3] = color.a;
        },
        else => {}, // Unsupported format → silent no-op
    }
}

pub fn imageDrawPixelV(
    dst: *Image,
    position: Vec2,
    color: Color,
) void {
    imageDrawPixel(dst, @trunc(position[0]), @trunc(position[1]), color);
}

/// Bresenham-style line draw using fixed-point step. Same algorithm as
/// raylib's ImageDrawLine.
pub fn imageDrawLine(
    dst: *Image,
    startPosX: i32,
    startPosY: i32,
    endPosX: i32,
    endPosY: i32,
    color: Color,
) void {
    var short_len: i32 = endPosY - startPosY;
    var long_len: i32 = endPosX - startPosX;
    var y_longer: bool = false;
    if (@abs(short_len) > @abs(long_len)) {
        const tmp: i32 = short_len;
        short_len = long_len;
        long_len = tmp;
        y_longer = true;
    }
    const end_val: i32 = long_len;
    var sgn_inc: i32 = 1;
    if (long_len < 0) {
        long_len = -long_len;
        sgn_inc = -1;
    }
    // Fixed-point increment in 16.16. Avoids floats; matches raylib.
    const dec_inc: i32 = if (long_len == 0) 0 else @divFloor(short_len << 16, long_len);
    var i: i32 = 0;
    var j: i32 = 0;
    while (i != end_val) : ({
        i += sgn_inc;
        j += dec_inc;
    }) {
        if (y_longer) {
            imageDrawPixel(dst, startPosX + (j >> 16), startPosY + i, color);
        } else {
            imageDrawPixel(dst, startPosX + i, startPosY + (j >> 16), color);
        }
    }
}

pub fn imageDrawLineV(
    dst: *Image,
    start: Vec2,
    end: Vec2,
    color: Color,
) void {
    const x1: i32 = @round(start[0]);
    const y1: i32 = @round(start[1]);
    const x2: i32 = @round(end[0]);
    const y2: i32 = @round(end[1]);
    imageDrawLine(dst, x1, y1, x2, y2, color);
}

/// Thick line: fills a band of `thick` parallel 1px lines.
pub fn imageDrawLineThick(
    dst: *Image,
    start: Vec2,
    end: Vec2,
    thick: i32,
    color: Color,
) void {
    const x1: i32 = @round(start[0]);
    const y1: i32 = @round(start[1]);
    const x2: i32 = @round(end[0]);
    const y2: i32 = @round(end[1]);
    const dx: f32 = float(x2 - x1);
    const dy: f32 = float(y2 - y1);
    if (dx != 0 and @abs(dy / dx) < 1) {
        // Horizontal-dominant: stack lines vertically.
        const wy: i32 = thick - 1;
        // Lines at +0..+(wy+1)/2 below the centerline.
        for (0..@intCast(@divFloor(wy + 1, 2) + 1)) |iu| {
            const i: i32 = @intCast(iu);
            imageDrawLine(dst, x1, y1 + i, x2, y2 + i, color);
        }
        // Lines at -1..-wy/2 above the centerline.
        for (1..@intCast(@divFloor(wy, 2) + 1)) |iu| {
            const i: i32 = @intCast(iu);
            imageDrawLine(dst, x1, y1 - i, x2, y2 - i, color);
        }
    } else if (dy != 0) {
        // Vertical-dominant: stack lines horizontally.
        const wx: i32 = thick - 1;
        for (0..@intCast(@divFloor(wx + 1, 2) + 1)) |iu| {
            const i: i32 = @intCast(iu);
            imageDrawLine(dst, x1 + i, y1, x2 + i, y2, color);
        }
        for (1..@intCast(@divFloor(wx, 2) + 1)) |iu| {
            const i: i32 = @intCast(iu);
            imageDrawLine(dst, x1 - i, y1, x2 - i, y2, color);
        }
    }
}

/// Filled rectangle, with bounds clamping.
pub fn imageDrawRectangleRec(
    dst: *Image,
    rec_in: Rectangle,
    color: Color,
) void {
    if (dst.data == null or dst.width == 0 or dst.height == 0) {
        return;
    }
    var rec: Rectangle = rec_in;
    if (rec.x < 0) {
        rec.width += rec.x;
        rec.x = 0;
    }
    if (rec.y < 0) {
        rec.height += rec.y;
        rec.y = 0;
    }
    if (rec.width < 0) {
        rec.width = 0;
    }
    if (rec.height < 0) {
        rec.height = 0;
    }
    const fw = float(dst.width);
    const fh = float(dst.height);
    if ((rec.x + rec.width) >= fw) {
        rec.width = fw - rec.x;
    }
    if ((rec.y + rec.height) >= fh) {
        rec.height = fh - rec.y;
    }
    const x0: i32 = @trunc(rec.x);
    const y0: i32 = @trunc(rec.y);
    const w: i32 = @trunc(rec.width);
    const h: i32 = @trunc(rec.height);
    for (0..@intCast(h)) |yu| {
        for (0..@intCast(w)) |xu| {
            imageDrawPixel(dst, x0 + @as(i32, @intCast(xu)), y0 + @as(i32, @intCast(yu)), color);
        }
    }
}

pub fn imageDrawRectangle(
    dst: *Image,
    posX: i32,
    posY: i32,
    width: i32,
    height: i32,
    color: Color,
) void {
    imageDrawRectangleRec(
        dst,
        .{
            .x = @floatFromInt(posX),
            .y = @floatFromInt(posY),
            .width = @floatFromInt(width),
            .height = @floatFromInt(height),
        },
        color,
    );
}

pub fn imageDrawRectangleV(
    dst: *Image,
    position: Vec2,
    size: Vec2,
    color: Color,
) void {
    imageDrawRectangle(
        dst,
        @trunc(position[0]),
        @trunc(position[1]),
        @trunc(size[0]),
        @trunc(size[1]),
        color,
    );
}

/// Hollow rectangle outline (4 thick edges).
pub fn imageDrawRectangleLines(
    dst: *Image,
    rec: Rectangle,
    thick: i32,
    color: Color,
) void {
    const t = float(thick);
    imageDrawRectangleRec(dst, .{ .x = rec.x, .y = rec.y, .width = rec.width, .height = t }, color);
    imageDrawRectangleRec(
        dst,
        .{ .x = rec.x, .y = rec.y + rec.height - t, .width = rec.width, .height = t },
        color,
    );
    imageDrawRectangleRec(dst, .{ .x = rec.x, .y = rec.y, .width = t, .height = rec.height }, color);
    imageDrawRectangleRec(
        dst,
        .{ .x = rec.x + rec.width - t, .y = rec.y, .width = t, .height = rec.height },
        color,
    );
}

/// Filled circle via Bresenham midpoint algorithm.
pub fn imageDrawCircle(
    dst: *Image,
    centerX: i32,
    centerY: i32,
    radius: i32,
    color: Color,
) void {
    var x: i32 = 0;
    var y: i32 = radius;
    var d: i32 = 3 - 2 * radius;
    while (y >= x) {
        // Each iteration draws four horizontal scanlines (top/bottom of x and y).
        imageDrawRectangle(dst, centerX - x, centerY + y, x * 2, 1, color);
        imageDrawRectangle(dst, centerX - x, centerY - y, x * 2, 1, color);
        imageDrawRectangle(dst, centerX - y, centerY + x, y * 2, 1, color);
        imageDrawRectangle(dst, centerX - y, centerY - x, y * 2, 1, color);
        x += 1;
        if (d > 0) {
            y -= 1;
            d += 4 * (x - y) + 10;
        } else {
            d += 4 * x + 6;
        }
    }
}

pub fn imageDrawCircleV(
    dst: *Image,
    center: Vec2,
    radius: i32,
    color: Color,
) void {
    imageDrawCircle(dst, @trunc(center[0]), @trunc(center[1]), radius, color);
}

/// Hollow circle outline (8-symmetry Bresenham).
pub fn imageDrawCircleLines(
    dst: *Image,
    centerX: i32,
    centerY: i32,
    radius: i32,
    color: Color,
) void {
    var x: i32 = 0;
    var y: i32 = radius;
    var d: i32 = 3 - 2 * radius;
    while (y >= x) {
        imageDrawPixel(dst, centerX + x, centerY + y, color);
        imageDrawPixel(dst, centerX - x, centerY + y, color);
        imageDrawPixel(dst, centerX + x, centerY - y, color);
        imageDrawPixel(dst, centerX - x, centerY - y, color);
        imageDrawPixel(dst, centerX + y, centerY + x, color);
        imageDrawPixel(dst, centerX - y, centerY + x, color);
        imageDrawPixel(dst, centerX + y, centerY - x, color);
        imageDrawPixel(dst, centerX - y, centerY - x, color);
        x += 1;
        if (d > 0) {
            y -= 1;
            d += 4 * (x - y) + 10;
        } else {
            d += 4 * x + 6;
        }
    }
}

pub fn imageDrawCircleLinesV(
    dst: *Image,
    center: Vec2,
    radius: i32,
    color: Color,
) void {
    imageDrawCircleLines(dst, @trunc(center[0]), @trunc(center[1]), radius, color);
}

/// Read the pixel at (x, y) from an Image.  Out-of-bounds returns
/// `Color{0,0,0,0}` (transparent black).  Mirrors raylib's
/// `GetImageColor`.  Format dispatch matches the supported set in
/// `imageDrawPixel`.
pub fn getImageColor(
    image: Image,
    x: i32,
    y: i32,
) Color {
    if (image.data == null or x < 0 or y < 0 or x >= image.width or y >= image.height) {
        return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    }
    const data: [*]const u8 = @ptrCast(image.data.?);
    const idx: usize = @intCast(y * image.width + x);
    return switch (image.pixelFormat()) {
        .uncompressed_grayscale => .{ .r = data[idx], .g = data[idx], .b = data[idx], .a = 255 },
        .uncompressed_gray_alpha => .{
            .r = data[idx * 2],
            .g = data[idx * 2],
            .b = data[idx * 2],
            .a = data[idx * 2 + 1],
        },
        .uncompressed_r8g8b8 => .{
            .r = data[idx * 3 + 0],
            .g = data[idx * 3 + 1],
            .b = data[idx * 3 + 2],
            .a = 255,
        },
        .uncompressed_r8g8b8a8 => .{
            .r = data[idx * 4 + 0],
            .g = data[idx * 4 + 1],
            .b = data[idx * 4 + 2],
            .a = data[idx * 4 + 3],
        },
        else => .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    };
}

/// Read a pixel from a raw byte pointer in the given format and convert to
/// 8-bit RGBA Color.
pub fn getPixelColor(srcPtr: *anyopaque, format: i32) Color {
    const src: [*]const u8 = @ptrCast(srcPtr);
    var color = Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    switch (@as(types.PixelFormat, @fromBackingInt(@intCast(format)))) {
        .uncompressed_grayscale => {
            color = .{ .r = src[0], .g = src[0], .b = src[0], .a = 255 };
        },
        .uncompressed_gray_alpha => {
            color = .{ .r = src[0], .g = src[0], .b = src[0], .a = src[1] };
        },
        .uncompressed_r5g6b5 => {
            const p: *const u16 = @ptrCast(@alignCast(srcPtr));
            color.r = @intCast(@divFloor((@as(i32, p.*) >> 11) * 255, 31));
            color.g = @intCast(@divFloor(((@as(i32, p.*) >> 5) & 0x3f) * 255, 63));
            color.b = @intCast(@divFloor((@as(i32, p.*) & 0x1f) * 255, 31));
            color.a = 255;
        },
        .uncompressed_r5g5b5a1 => {
            const p: *const u16 = @ptrCast(@alignCast(srcPtr));
            color.r = @intCast(@divFloor((@as(i32, p.*) >> 11) * 255, 31));
            color.g = @intCast(@divFloor(((@as(i32, p.*) >> 6) & 0x1f) * 255, 31));
            color.b = @intCast(@divFloor(((@as(i32, p.*) >> 1) & 0x1f) * 255, 31));
            color.a = if ((p.* & 1) != 0) 255 else 0;
        },
        .uncompressed_r4g4b4a4 => {
            const p: *const u16 = @ptrCast(@alignCast(srcPtr));
            color.r = @intCast(@divFloor((@as(i32, p.*) >> 12) * 255, 15));
            color.g = @intCast(@divFloor(((@as(i32, p.*) >> 8) & 0x0f) * 255, 15));
            color.b = @intCast(@divFloor(((@as(i32, p.*) >> 4) & 0x0f) * 255, 15));
            color.a = @intCast(@divFloor((@as(i32, p.*) & 0x0f) * 255, 15));
        },
        .uncompressed_r8g8b8a8 => {
            color = .{ .r = src[0], .g = src[1], .b = src[2], .a = src[3] };
        },
        .uncompressed_r8g8b8 => {
            color = .{ .r = src[0], .g = src[1], .b = src[2], .a = 255 };
        },
        .uncompressed_r32 => {
            const p: *const f32 = @ptrCast(@alignCast(srcPtr));
            const v: u8 = @round(p.* * 255.0);
            color = .{ .r = v, .g = v, .b = v, .a = 255 };
        },
        .uncompressed_r32g32b32 => {
            const p: [*]const f32 = @ptrCast(@alignCast(srcPtr));
            color = .{
                .r = @trunc(p[0] * 255.0),
                .g = @trunc(p[1] * 255.0),
                .b = @trunc(p[2] * 255.0),
                .a = 255,
            };
        },
        .uncompressed_r32g32b32a32 => {
            const p: [*]const f32 = @ptrCast(@alignCast(srcPtr));
            color = .{
                .r = @trunc(p[0] * 255.0),
                .g = @trunc(p[1] * 255.0),
                .b = @trunc(p[2] * 255.0),
                .a = @trunc(p[3] * 255.0),
            };
        },
        else => {},
    }
    return color;
}

/// Composite a source Image onto a destination Image with optional
/// tint.  The source rectangle `src_rec` is sampled from `src`; the
/// destination rectangle `dst_rec` defines where it lands in `dst`.
/// **Limitation:** when source and destination rectangles have
/// different dimensions, this implementation falls back to
/// nearest-neighbor scaling.  A high-quality bilinear resampler
/// is deferred to a future `imageResize` and will upgrade this
/// fast path automatically once available.
/// Source rectangles outside `src` bounds are clipped.  Destination
/// rectangles partially outside `dst` are clipped.  Tinted source
/// pixels are alpha-blended onto the destination via
/// `colorAlphaBlend`.
pub fn imageDraw(
    dst: *Image,
    src: Image,
    src_rec_in: Rectangle,
    dst_rec_in: Rectangle,
    tint: Color,
) void {
    if (dst.data == null or dst.width == 0 or dst.height == 0) {
        return;
    }
    if (src.data == null or src.width == 0 or src.height == 0) {
        return;
    }

    var src_rec: Rectangle = src_rec_in;
    var dst_rec: Rectangle = dst_rec_in;

    // ---- Clip the source rectangle to source bounds ----
    if (src_rec.x < 0) {
        src_rec.width += src_rec.x;
        src_rec.x = 0;
    }
    if (src_rec.y < 0) {
        src_rec.height += src_rec.y;
        src_rec.y = 0;
    }
    const src_w_f: f32 = float(src.width);
    const src_h_f: f32 = float(src.height);
    if (src_rec.x + src_rec.width > src_w_f) {
        src_rec.width = src_w_f - src_rec.x;
    }
    if (src_rec.y + src_rec.height > src_h_f) {
        src_rec.height = src_h_f - src_rec.y;
    }
    if (src_rec.width <= 0 or src_rec.height <= 0) {
        return;
    }

    // ---- Clip the destination rectangle to dst bounds ----
    // Adjust src offsets to mirror destination clamping when we crop
    // off the top/left.  Scale factors stay constant.
    const sx_scale: f32 = src_rec.width / dst_rec.width;
    const sy_scale: f32 = src_rec.height / dst_rec.height;
    if (dst_rec.x < 0) {
        src_rec.x -= dst_rec.x * sx_scale;
        src_rec.width += dst_rec.x * sx_scale;
        dst_rec.width += dst_rec.x;
        dst_rec.x = 0;
    }
    if (dst_rec.y < 0) {
        src_rec.y -= dst_rec.y * sy_scale;
        src_rec.height += dst_rec.y * sy_scale;
        dst_rec.height += dst_rec.y;
        dst_rec.y = 0;
    }
    const dst_w_f: f32 = float(dst.width);
    const dst_h_f: f32 = float(dst.height);
    if (dst_rec.x + dst_rec.width > dst_w_f) {
        dst_rec.width = dst_w_f - dst_rec.x;
    }
    if (dst_rec.y + dst_rec.height > dst_h_f) {
        dst_rec.height = dst_h_f - dst_rec.y;
    }
    if (dst_rec.width <= 0 or dst_rec.height <= 0) {
        return;
    }

    // ---- Walk every dest pixel; sample source via nearest-neighbor ----
    // (For same-size copies this degenerates to a 1:1 sample which is
    // pixel-exact.)
    const dx0: i32 = @trunc(dst_rec.x);
    const dy0: i32 = @trunc(dst_rec.y);
    const dx_end: i32 = @trunc(dst_rec.x + dst_rec.width);
    const dy_end: i32 = @trunc(dst_rec.y + dst_rec.height);

    const src_data: [*]const u8 = @ptrCast(src.data.?);
    const src_bpp_bits: i32 = switch (src.pixelFormat()) {
        .uncompressed_grayscale => 8,
        .uncompressed_gray_alpha => 16,
        .uncompressed_r8g8b8 => 24,
        .uncompressed_r8g8b8a8 => 32,
        else => return, // Unsupported source format
    };
    const src_bpp: usize = @intCast(@divFloor(src_bpp_bits, 8));

    // When the dest is smaller than the source (downscaling — e.g. drawing a
    // device-pixel-baked glyph at a smaller logical size), one nearest sample
    // drops thin strokes and aliases badly. Box-average the source footprint of
    // each dest pixel instead. For 1:1 or upscaling the box is a single pixel, so
    // this stays a nearest sample.
    const src_per_dst_x: f32 = if (dst_rec.width > 0) src_rec.width / dst_rec.width else 1.0;
    const src_per_dst_y: f32 = if (dst_rec.height > 0) src_rec.height / dst_rec.height else 1.0;
    const box_average: bool = src_per_dst_x > 1.25 or src_per_dst_y > 1.25;

    for (@intCast(dy0)..@intCast(dy_end)) |dyu| {
        const dy: i32 = @intCast(dyu);
        const t_y = (float(dy) - dst_rec.y) / dst_rec.height;
        const sy_f: f32 = src_rec.y + t_y * src_rec.height;

        for (@intCast(dx0)..@intCast(dx_end)) |dxu| {
            const dx: i32 = @intCast(dxu);
            const t_x = (float(dx) - dst_rec.x) / dst_rec.width;
            const sx_f: f32 = src_rec.x + t_x * src_rec.width;

            var src_color: Color = undefined;
            if (box_average) {
                var acc_r: u32 = 0;
                var acc_g: u32 = 0;
                var acc_b: u32 = 0;
                var acc_a: u32 = 0;
                var count: u32 = 0;
                const by_end: f32 = sy_f + src_per_dst_y;
                var by: i32 = @trunc(sy_f);
                while (float(by) < by_end) : (by += 1) {
                    const bx_end: f32 = sx_f + src_per_dst_x;
                    var bx: i32 = @trunc(sx_f);
                    while (float(bx) < bx_end) : (bx += 1) {
                        const bxc: i32 = clamp(bx, 0, src.width - 1);
                        const byc: i32 = clamp(by, 0, src.height - 1);
                        const bidx: usize = @as(usize, @intCast(byc * src.width + bxc)) * src_bpp;
                        const bcol = getPixelColor(
                            @constCast(@as(*const anyopaque, @ptrCast(&src_data[bidx]))),
                            src.format,
                        );
                        acc_r += bcol.r;
                        acc_g += bcol.g;
                        acc_b += bcol.b;
                        acc_a += bcol.a;
                        count += 1;
                    }
                }
                if (count == 0) {
                    count = 1;
                }
                src_color = .{
                    .r = @intCast(acc_r / count),
                    .g = @intCast(acc_g / count),
                    .b = @intCast(acc_b / count),
                    .a = @intCast(acc_a / count),
                };
            } else {
                const sxc: i32 = clamp(floori(i32, sx_f), 0, src.width - 1);
                const syc: i32 = clamp(floori(i32, sy_f), 0, src.height - 1);
                const src_byte_off: usize = @as(usize, @intCast(syc * src.width + sxc)) * src_bpp;
                src_color = getPixelColor(
                    @constCast(@as(*const anyopaque, @ptrCast(&src_data[src_byte_off]))),
                    src.format,
                );
            }

            // Read existing dst color.
            const dst_color: Color = getImageColor(dst.*, dx, dy);

            // Blend src ⊗ tint onto dst.
            const blended: Color = colorAlphaBlend(dst_color, src_color, tint);
            imageDrawPixel(dst, dx, dy, blended);
        }
    }
}

/// Fill the entire image with a single color. Uses doubling-copy for
/// O(n log n) writes after the first pixel - same trick as raylib.
pub fn imageClearBackground(dst: *Image, color: Color) void {
    if (dst.data == null or dst.width == 0 or dst.height == 0) {
        return;
    }
    imageDrawPixel(dst, 0, 0, color);
    const bpp_bits: i32 = switch (dst.pixelFormat()) {
        .uncompressed_grayscale => 8,
        .uncompressed_gray_alpha => 16,
        .uncompressed_r8g8b8 => 24,
        .uncompressed_r8g8b8a8 => 32,
        else => return,
    };
    const bpp: usize = @intCast(@divFloor(bpp_bits, 8));
    const total: usize = @intCast(dst.width * dst.height);
    const data: [*]u8 = @ptrCast(dst.data.?);
    var i: usize = 1;
    while (i < total) : (i *= 2) {
        const copy = @min(i, total - i);
        @memcpy(data[i * bpp ..][0 .. copy * bpp], data[0 .. copy * bpp]);
    }
}

// Image color manipulation - full-image pixel ops
//
// These walk every pixel in the image and apply a per-pixel transform.
// Only the R8G8B8A8 fast path is implemented here; for other formats
// we'd want to round-trip through Color, but practical raylib usage
// converts to R8G8B8A8 first.

/// Multiply every RGB pixel by `color` (alpha unchanged).
pub fn imageColorTint(image: *Image, color: Color) void {
    if (image.data == null or image.pixelFormat() != .uncompressed_r8g8b8a8) {
        return;
    }
    const data: [*]u8 = @ptrCast(image.data.?);
    const n: usize = imagePixelCount(image);
    for (0..n) |i| {
        data[i * 4 + 0] = @intCast(@divFloor(@as(i32, data[i * 4 + 0]) * @as(i32, color.r), 255));
        data[i * 4 + 1] = @intCast(@divFloor(@as(i32, data[i * 4 + 1]) * @as(i32, color.g), 255));
        data[i * 4 + 2] = @intCast(@divFloor(@as(i32, data[i * 4 + 2]) * @as(i32, color.b), 255));
        data[i * 4 + 3] = @intCast(@divFloor(@as(i32, data[i * 4 + 3]) * @as(i32, color.a), 255));
    }
}

/// Convert to grayscale using luma weights.
pub fn imageColorGrayscale(image: *Image) void {
    if (image.data == null or image.pixelFormat() != .uncompressed_r8g8b8a8) {
        return;
    }
    const data: [*]u8 = @ptrCast(image.data.?);
    const n: usize = imagePixelCount(image);
    for (0..n) |i| {
        const r = float(data[i * 4 + 0]) / 255.0;
        const g = float(data[i * 4 + 1]) / 255.0;
        const b = float(data[i * 4 + 2]) / 255.0;
        const gray: u8 = @round((r * 0.299 + g * 0.587 + b * 0.114) * 255.0);
        data[i * 4 + 0] = gray;
        data[i * 4 + 1] = gray;
        data[i * 4 + 2] = gray;
    }
}

/// Adjust brightness in [-255, 255]. Add to each channel, clamp.
pub fn imageColorBrightness(image: *Image, brightness: i32) void {
    if (image.data == null or image.pixelFormat() != .uncompressed_r8g8b8a8) {
        return;
    }
    const data: [*]u8 = @ptrCast(image.data.?);
    const n: usize = imagePixelCount(image);
    for (0..n) |i| {
        const ch: [3]u8 = .{ data[i * 4 + 0], data[i * 4 + 1], data[i * 4 + 2] };
        for (0..3) |k| {
            var v: i32 = @as(i32, ch[k]) + brightness;
            if (v < 0) {
                v = 0;
            }
            if (v > 255) {
                v = 255;
            }
            data[i * 4 + k] = @intCast(v);
        }
    }
}

/// Replace one color with another. Match is bytewise-exact.
pub fn imageColorReplace(
    image: *Image,
    color: Color,
    replace: Color,
) void {
    if (image.data == null or image.pixelFormat() != .uncompressed_r8g8b8a8) {
        return;
    }
    const data: [*]u8 = @ptrCast(image.data.?);
    const n: usize = imagePixelCount(image);
    for (0..n) |i| {
        if (data[i * 4 + 0] == color.r and data[i * 4 + 1] == color.g and
            data[i * 4 + 2] == color.b and data[i * 4 + 3] == color.a)
        {
            data[i * 4 + 0] = replace.r;
            data[i * 4 + 1] = replace.g;
            data[i * 4 + 2] = replace.b;
            data[i * 4 + 3] = replace.a;
        }
    }
}

// imageAlphaMask / imageAlphaCrop / getImageAlphaBorder - Roadmap Step 8
//
// raylib's C versions rely on `ImageFormat` (a generic format
// converter we don't have yet - that lives in Step 12).  We give the
// most useful subset:
//   - getImageAlphaBorder: works on any RGBA8/GRAY_ALPHA Image.
//   - imageAlphaCrop: any RGBA8/GRAY_ALPHA Image, delegates to
//     getImageAlphaBorder + imageCrop.
//   - imageAlphaMask: requires the destination Image already be
//     RGBA8 (the C version coerces; we leave format conversion as a
//     pre-step the caller does once we ship `imageFormat`).
// The "mask must be GRAYSCALE-formatted" requirement is enforced
// callers can `loadImage` from a single-channel PNG or build one
// procedurally.

/// Compute the bounding rectangle of pixels whose alpha exceeds
/// `threshold * 255`.  Useful for trimming transparent borders.
/// Returns a zero-area rectangle for fully transparent (or fully
/// below-threshold) images.
pub fn getImageAlphaBorder(image: Image, threshold: f32) Rectangle {
    if (image.data == null or image.width == 0 or image.height == 0) {
        return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    }
    const cutoff: u8 = @round(clamp(threshold * 255.0, 0.0, 255.0));

    // Initialize to "impossible" min/max so we can detect "no opaque
    // pixel found" and return a zero rect.
    var x_min: i32 = maxInt(i32);
    var x_max: i32 = -1;
    var y_min: i32 = maxInt(i32);
    var y_max: i32 = -1;

    for (0..@intCast(image.height)) |yu| {
        const y: i32 = @intCast(yu);
        for (0..@intCast(image.width)) |xu| {
            const x: i32 = @intCast(xu);
            const c: Color = getImageColor(image, x, y);
            if (c.a > cutoff) {
                if (x < x_min) {
                    x_min = x;
                }
                if (x > x_max) {
                    x_max = x;
                }
                if (y < y_min) {
                    y_min = y;
                }
                if (y > y_max) {
                    y_max = y;
                }
            }
        }
    }

    if (x_max == -1) {
        return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    }
    return .{
        .x = @floatFromInt(x_min),
        .y = @floatFromInt(y_min),
        .width = @floatFromInt(x_max + 1 - x_min),
        .height = @floatFromInt(y_max + 1 - y_min),
    };
}

/// Free an Image's pixel buffer with `gpa`.  Internal helper for the
/// in-place transforms (resize, crop, rotate, etc.) that allocate a
/// new buffer and discard the old one - same byte-count derivation
/// as `unloadImage`, but as a separate function so it can be called
/// at the right moment in the swap sequence.
fn freeImageData(gpa: Allocator, image: Image) void {
    if (image.data == null) {
        return;
    }
    const total_bytes: usize = imageDataByteCount(image);
    const buf: [*]u8 = @ptrCast(@alignCast(image.data));
    gpa.free(buf[0..total_bytes]);
}

/// Crop an image to a sub-rectangle, in place.  Out-of-bounds rect
/// is silently clamped to the image extents; if the rect is entirely
/// outside, the call is a no-op (matches raylib semantics).  Pass
/// the same allocator the image was created with - the old pixel
/// buffer is freed after the new (cropped) buffer is built.
pub fn imageCrop(
    gpa: Allocator,
    image: *Image,
    crop_in: Rectangle,
) Allocator.Error!void {
    if (image.data == null or image.width == 0 or image.height == 0) {
        return;
    }
    if (image.pixelFormat().isCompressed()) {
        return;
    }

    var crop: Rectangle = crop_in;
    // Clamp negative offsets - clip the rect from the top/left, not
    // shifting it.
    if (crop.x < 0) {
        crop.width += crop.x;
        crop.x = 0;
    }
    if (crop.y < 0) {
        crop.height += crop.y;
        crop.y = 0;
    }
    // Clamp right/bottom edges inside the image.
    const iw: f32 = float(image.width);
    const ih: f32 = float(image.height);
    if (crop.x + crop.width > iw) {
        crop.width = iw - crop.x;
    }
    if (crop.y + crop.height > ih) {
        crop.height = ih - crop.y;
    }
    if (crop.x > iw or crop.y > ih or crop.width <= 0 or crop.height <= 0) {
        return;
    }

    const bpp: usize = @intCast(getPixelDataSize(1, 1, image.format));
    const cw: usize = @trunc(crop.width);
    const ch: usize = @trunc(crop.height);
    const cx: usize = @trunc(crop.x);
    const cy: usize = @trunc(crop.y);
    const sw: usize = @intCast(image.width);

    const new_pixels: []u8 = try gpa.alloc(u8, cw * ch * bpp);
    errdefer gpa.free(new_pixels);
    const dst: [*]u8 = new_pixels.ptr;
    const src: [*]const u8 = @ptrCast(image.data);

    for (0..ch) |y| {
        const dst_off: usize = y * cw * bpp;
        const src_off: usize = ((y + cy) * sw + cx) * bpp;
        @memcpy(dst[dst_off .. dst_off + cw * bpp], src[src_off .. src_off + cw * bpp]);
    }

    freeImageData(gpa, image.*);
    image.data = @ptrCast(new_pixels.ptr);
    image.width = @intCast(cw);
    image.height = @intCast(ch);
}

/// Crop the image down to its non-transparent pixel bounds.  Pixels
/// with `alpha <= threshold * 255` are considered transparent for
/// the purposes of cropping.  No-op if the image is already tight or
/// fully transparent.
pub fn imageAlphaCrop(
    gpa: Allocator,
    image: *Image,
    threshold: f32,
) Allocator.Error!void {
    if (image.data == null or image.width == 0 or image.height == 0) {
        return;
    }
    const crop: z.Rectangle = getImageAlphaBorder(image.*, threshold);
    if (crop.width != 0 and crop.height != 0) {
        try imageCrop(gpa, image, crop);
    }
}

/// Apply a grayscale `mask`'s pixels as the alpha channel of `image`.
/// Requirements:
///   - `image.format` must be `PIXELFORMAT_UNCOMPRESSED_R8G8B8A8`
///     (call `imageFormat` first if it isn't).
///   - `mask.format` must be `PIXELFORMAT_UNCOMPRESSED_GRAYSCALE`.
///   - `image` and `mask` must have the same dimensions.
/// Mismatches are silent no-ops (raylib logs a warning; `traceLog`
/// here is pending an allocator-explicit pass that clarifies the
/// trace_log dispatch).
pub fn imageAlphaMask(image: *Image, mask: Image) void {
    if (image.data == null or mask.data == null) {
        return;
    }
    if (image.width != mask.width or image.height != mask.height) {
        return;
    }
    if (image.pixelFormat() != .uncompressed_r8g8b8a8) {
        return;
    }
    if (mask.pixelFormat() != .uncompressed_grayscale) {
        return;
    }

    const img_data: [*]u8 = @ptrCast(image.data.?);
    const mask_data: [*]const u8 = @ptrCast(mask.data.?);
    const n: usize = @intCast(image.width * image.height);
    for (0..n) |i| {
        // Replace alpha channel with mask intensity.
        img_data[i * 4 + 3] = mask_data[i];
    }
}

// imageBlurGaussian / imageKernelConvolution / imageDither - Roadmap Step 9
//
// Blur uses raylib's box-blur-iterations approach (4 iterations of
// horizontal + vertical box blur converges to a Gaussian).  For each
// iteration: precompute the running sum at the row's start, then
// slide the window, subtracting the leaving pixel and adding the
// entering pixel - O(width × height) per iteration regardless of
// blur size.

/// Apply an arbitrary square convolution kernel to an RGBA8 image.
/// `kernelSize` is the side length (must be odd: 3, 5, 7, ...).
/// Edges replicate the nearest valid pixel (clamp-to-edge).  `gpa`
/// is used only for a scratch buffer; image data is mutated in place.
/// `kernel` is a flat row-major odd×odd matrix; pass e.g. a 3×3
/// kernel as `&[_]f32{ 0, -1, 0, -1, 5, -1, 0, -1, 0 }`.
pub fn imageKernelConvolution(
    gpa: Allocator,
    image: *Image,
    kernel: []const f32,
) Allocator.Error!void {
    if (image.data == null or image.width == 0 or image.height == 0) {
        return;
    }
    if (image.pixelFormat() != .uncompressed_r8g8b8a8) {
        return;
    }
    // Kernel must be square (s × s) with odd s ≥ 1.  Equivalently,
    // `kernel.len` is an odd perfect square.
    const kernel_size_f: f32 = @sqrt(float(kernel.len));
    const kernelSize: i32 = @trunc(kernel_size_f);
    if (kernelSize < 1 or @mod(kernelSize, 2) != 1) {
        return;
    }
    if (@as(usize, @intCast(kernelSize * kernelSize)) != kernel.len) {
        return;
    }

    const w: i32 = image.width;
    const h: i32 = image.height;
    const pixel_count: usize = @intCast(w * h);
    const out: []u8 = try gpa.alloc(u8, pixel_count * 4);
    defer gpa.free(out);

    const half: i32 = @divFloor(kernelSize, 2);
    const ks: usize = @intCast(kernelSize);

    for (0..@intCast(h)) |yu| {
        const y: i32 = @intCast(yu);
        for (0..@intCast(w)) |xu| {
            const x: i32 = @intCast(xu);
            var acc_r: f32 = 0;
            var acc_g: f32 = 0;
            var acc_b: f32 = 0;
            var acc_a: f32 = 0;

            // Iterate the kernel rows/cols by index, then derive the
            // signed offset (`kx`/`ky` ∈ [-half, +half]) from it.
            for (0..ks) |krow| {
                const ky: i32 = @as(i32, @intCast(krow)) - half;
                for (0..ks) |kcol| {
                    const kx: i32 = @as(i32, @intCast(kcol)) - half;
                    // Clamp sample position to image bounds.
                    var sx: i32 = x + kx;
                    var sy: i32 = y + ky;
                    if (sx < 0) {
                        sx = 0;
                    }
                    if (sx >= w) {
                        sx = w - 1;
                    }
                    if (sy < 0) {
                        sy = 0;
                    }
                    if (sy >= h) {
                        sy = h - 1;
                    }

                    const c: Color = getImageColor(image.*, sx, sy);
                    const weight: f32 = kernel[krow * ks + kcol];
                    acc_r += float(c.r) * weight;
                    acc_g += float(c.g) * weight;
                    acc_b += float(c.b) * weight;
                    acc_a += float(c.a) * weight;
                }
            }

            const out_idx: usize = @intCast((y * w + x) * 4);
            out[out_idx + 0] = @trunc(clamp(acc_r, 0.0, 255.0));
            out[out_idx + 1] = @trunc(clamp(acc_g, 0.0, 255.0));
            out[out_idx + 2] = @trunc(clamp(acc_b, 0.0, 255.0));
            out[out_idx + 3] = @trunc(clamp(acc_a, 0.0, 255.0));
        }
    }

    // Copy out → image.data
    const dst: [*]u8 = @ptrCast(image.data.?);
    @memcpy(dst[0 .. pixel_count * 4], out[0 .. pixel_count * 4]);
}

/// Floyd-Steinberg dither an RGBA8 image down to the specified bit
/// depth per channel.  Output pixel format is determined by the
/// per-channel bit depths:
///   - rBpp + gBpp + bBpp + aBpp == 16 → R5G6B5 (or R5G5B5A1, R4G4B4A4)
///   - others → unchanged (function is a no-op for unsupported combos)
/// Error diffusion: 7/16 right, 3/16 below-left, 5/16 below, 1/16
/// below-right (classic Floyd-Steinberg coefficients).
pub fn imageDither(
    gpa: Allocator,
    image: *Image,
    rBpp: i32,
    gBpp: i32,
    bBpp: i32,
    aBpp: i32,
) Allocator.Error!void {
    if (image.data == null or image.width == 0 or image.height == 0) {
        return;
    }
    if (image.pixelFormat() != .uncompressed_r8g8b8a8) {
        return;
    }
    const total_bpp: i32 = rBpp + gBpp + bBpp + aBpp;
    if (total_bpp != 16) {
        return; // Only common 16-bit formats supported.
    }

    const w: usize = @intCast(image.width);
    const h: usize = @intCast(image.height);
    const n: usize = w * h;

    // Scratch error buffer (f32 per channel).
    const fbuf: []f32 = try gpa.alloc(f32, n * 4);
    defer gpa.free(fbuf);

    const data: [*]u8 = @ptrCast(image.data.?);
    for (0..n) |i| {
        fbuf[i * 4 + 0] = @floatFromInt(data[i * 4 + 0]);
        fbuf[i * 4 + 1] = @floatFromInt(data[i * 4 + 1]);
        fbuf[i * 4 + 2] = @floatFromInt(data[i * 4 + 2]);
        fbuf[i * 4 + 3] = @floatFromInt(data[i * 4 + 3]);
    }

    const r_levels: f32 = float((@as(i32, 1) << @intCast(rBpp)) - 1);
    const g_levels: f32 = float((@as(i32, 1) << @intCast(gBpp)) - 1);
    const b_levels: f32 = float((@as(i32, 1) << @intCast(bBpp)) - 1);
    const a_levels: f32 = if (aBpp == 0) 1.0 else @floatFromInt((@as(i32, 1) << @intCast(aBpp)) - 1);

    for (0..h) |y| {
        for (0..w) |x| {
            const idx: usize = (y * w + x) * 4;
            const old_r: f32 = fbuf[idx + 0];
            const old_g: f32 = fbuf[idx + 1];
            const old_b: f32 = fbuf[idx + 2];
            const old_a: f32 = fbuf[idx + 3];

            // Quantize each channel to the target bit depth.
            const new_r: f32 = @round(old_r * r_levels / 255.0) * 255.0 / r_levels;
            const new_g: f32 = @round(old_g * g_levels / 255.0) * 255.0 / g_levels;
            const new_b: f32 = @round(old_b * b_levels / 255.0) * 255.0 / b_levels;
            const new_a: f32 = if (aBpp == 0) 255.0 else @round(old_a * a_levels / 255.0) * 255.0 / a_levels;

            data[idx + 0] = @trunc(clamp(new_r, 0.0, 255.0));
            data[idx + 1] = @trunc(clamp(new_g, 0.0, 255.0));
            data[idx + 2] = @trunc(clamp(new_b, 0.0, 255.0));
            data[idx + 3] = @trunc(clamp(new_a, 0.0, 255.0));

            // Diffuse error to neighbors.
            const err_r: f32 = old_r - new_r;
            const err_g: f32 = old_g - new_g;
            const err_b: f32 = old_b - new_b;
            const err_a: f32 = if (aBpp == 0) 0.0 else old_a - new_a;

            // 7/16 → (x+1, y)
            if (x + 1 < w) {
                const ni: usize = (y * w + x + 1) * 4;
                fbuf[ni + 0] += err_r * (7.0 / 16.0);
                fbuf[ni + 1] += err_g * (7.0 / 16.0);
                fbuf[ni + 2] += err_b * (7.0 / 16.0);
                fbuf[ni + 3] += err_a * (7.0 / 16.0);
            }
            // 3/16 → (x-1, y+1)
            if (y + 1 < h and x > 0) {
                const ni: usize = ((y + 1) * w + x - 1) * 4;
                fbuf[ni + 0] += err_r * (3.0 / 16.0);
                fbuf[ni + 1] += err_g * (3.0 / 16.0);
                fbuf[ni + 2] += err_b * (3.0 / 16.0);
                fbuf[ni + 3] += err_a * (3.0 / 16.0);
            }
            // 5/16 → (x, y+1)
            if (y + 1 < h) {
                const ni: usize = ((y + 1) * w + x) * 4;
                fbuf[ni + 0] += err_r * (5.0 / 16.0);
                fbuf[ni + 1] += err_g * (5.0 / 16.0);
                fbuf[ni + 2] += err_b * (5.0 / 16.0);
                fbuf[ni + 3] += err_a * (5.0 / 16.0);
            }
            // 1/16 → (x+1, y+1)
            if (y + 1 < h and x + 1 < w) {
                const ni: usize = ((y + 1) * w + x + 1) * 4;
                fbuf[ni + 0] += err_r * (1.0 / 16.0);
                fbuf[ni + 1] += err_g * (1.0 / 16.0);
                fbuf[ni + 2] += err_b * (1.0 / 16.0);
                fbuf[ni + 3] += err_a * (1.0 / 16.0);
            }
        }
    }
}

/// Flip image vertically in place.
pub fn imageFlipVertical(image: *Image) void {
    if (image.data == null) {
        return;
    }
    const bpp_bits: i32 = switch (image.pixelFormat()) {
        .uncompressed_grayscale => 8,
        .uncompressed_gray_alpha => 16,
        .uncompressed_r8g8b8 => 24,
        .uncompressed_r8g8b8a8 => 32,
        else => return,
    };
    const bpp: usize = @intCast(@divFloor(bpp_bits, 8));
    const w: usize = @intCast(image.width);
    const h: usize = @intCast(image.height);
    const stride: usize = w * bpp;
    const data: [*]u8 = @ptrCast(image.data.?);
    for (0..h / 2) |y| {
        for (0..stride) |x| {
            const top: usize = y * stride + x;
            const bot: usize = (h - 1 - y) * stride + x;
            const tmp: u8 = data[top];
            data[top] = data[bot];
            data[bot] = tmp;
        }
    }
}

/// Flip image horizontally in place.
pub fn imageFlipHorizontal(image: *Image) void {
    if (image.data == null) {
        return;
    }
    const bpp_bits: i32 = switch (image.pixelFormat()) {
        .uncompressed_grayscale => 8,
        .uncompressed_gray_alpha => 16,
        .uncompressed_r8g8b8 => 24,
        .uncompressed_r8g8b8a8 => 32,
        else => return,
    };
    const bpp: usize = @intCast(@divFloor(bpp_bits, 8));
    const w: usize = @intCast(image.width);
    const h: usize = @intCast(image.height);
    const stride: usize = w * bpp;
    const data: [*]u8 = @ptrCast(image.data.?);
    for (0..h) |y| {
        for (0..w / 2) |x| {
            for (0..bpp) |k| {
                const left: usize = y * stride + x * bpp + k;
                const right: usize = y * stride + (w - 1 - x) * bpp + k;
                const tmp: u8 = data[left];
                data[left] = data[right];
                data[right] = tmp;
            }
        }
    }
}

// Pixel format conversion (raw pointer in/out)
const r5g5b5a1_alpha_threshold: u8 = 50;

/// Write a Color to a raw byte pointer in the given pixel format.
pub fn setPixelColor(
    dstPtr: *anyopaque,
    color: Color,
    format: i32,
) void {
    const dst: [*]u8 = @ptrCast(dstPtr);
    switch (@as(types.PixelFormat, @fromBackingInt(@intCast(format)))) {
        .uncompressed_grayscale => {
            const r = float(color.r) / 255.0;
            const g = float(color.g) / 255.0;
            const b = float(color.b) / 255.0;
            dst[0] = @trunc((r * 0.299 + g * 0.587 + b * 0.114) * 255.0);
        },
        .uncompressed_gray_alpha => {
            const r = float(color.r) / 255.0;
            const g = float(color.g) / 255.0;
            const b = float(color.b) / 255.0;
            dst[0] = @trunc((r * 0.299 + g * 0.587 + b * 0.114) * 255.0);
            dst[1] = color.a;
        },
        .uncompressed_r5g6b5 => {
            const p: *u16 = @ptrCast(@alignCast(dstPtr));
            const r = roundi(u16, float(color.r) / 255.0 * 31.0);
            const g = roundi(u16, float(color.g) / 255.0 * 63.0);
            const b = roundi(u16, float(color.b) / 255.0 * 31.0);
            p.* = (r << 11) | (g << 5) | b;
        },
        .uncompressed_r5g5b5a1 => {
            const p: *u16 = @ptrCast(@alignCast(dstPtr));
            const r = roundi(u16, float(color.r) / 255.0 * 31.0);
            const g = roundi(u16, float(color.g) / 255.0 * 31.0);
            const b = roundi(u16, float(color.b) / 255.0 * 31.0);
            const a: u16 = if (color.a > r5g5b5a1_alpha_threshold) 1 else 0;
            p.* = (r << 11) | (g << 6) | (b << 1) | a;
        },
        .uncompressed_r4g4b4a4 => {
            const p: *u16 = @ptrCast(@alignCast(dstPtr));
            const r = roundi(u16, float(color.r) / 255.0 * 15.0);
            const g = roundi(u16, float(color.g) / 255.0 * 15.0);
            const b = roundi(u16, float(color.b) / 255.0 * 15.0);
            const a = roundi(u16, float(color.a) / 255.0 * 15.0);
            p.* = (r << 12) | (g << 8) | (b << 4) | a;
        },
        .uncompressed_r8g8b8 => {
            dst[0] = color.r;
            dst[1] = color.g;
            dst[2] = color.b;
        },
        .uncompressed_r8g8b8a8 => {
            dst[0] = color.r;
            dst[1] = color.g;
            dst[2] = color.b;
            dst[3] = color.a;
        },
        else => {},
    }
}

// 9-patch / 3-patch texture drawing
const NPatchInfo = z.NPatchInfo;
const npatch_nine_patch: i32 = 0;
const npatch_three_patch_vertical: i32 = 1;
const npatch_three_patch_horizontal: i32 = 2;

// rlPushMatrix / rlPopMatrix / rlTranslatef / rlRotatef live in
// rlgl.zig (pure CPU).  Reached via the `rl` alias above; no extern
// declarations needed.

/// Helper: emit one quad with raylib's CCW winding, texture coords first.
inline fn nPatchQuad(
    gl: anytype,
    coord_a_x: f32,
    coord_a_y: f32,
    vert_a_x: f32,
    vert_a_y: f32,
    coord_b_x: f32,
    coord_b_y: f32,
    vert_b_x: f32,
    vert_b_y: f32,
    coord_c_x: f32,
    coord_c_y: f32,
    vert_c_x: f32,
    vert_c_y: f32,
    coord_d_x: f32,
    coord_d_y: f32,
    vert_d_x: f32,
    vert_d_y: f32,
) void {
    gl.texCoord2f(coord_a_x, coord_a_y);
    gl.vertex2f(vert_a_x, vert_a_y);
    gl.texCoord2f(coord_b_x, coord_b_y);
    gl.vertex2f(vert_b_x, vert_b_y);
    gl.texCoord2f(coord_c_x, coord_c_y);
    gl.vertex2f(vert_c_x, vert_c_y);
    gl.texCoord2f(coord_d_x, coord_d_y);
    gl.vertex2f(vert_d_x, vert_d_y);
}

/// Draw a texture using N-patch info (3-patch H/V or 9-patch). Stretches
/// the center while preserving the corner/border regions at native size.
pub fn drawTextureNPatch(
    gl: anytype,
    texture: Texture,
    info_in: NPatchInfo,
    dest: Rectangle,
    origin: Vec2,
    rotation_rad: f32,
    tint: Color,
) void {
    if (texture.id == 0) {
        return;
    }
    var info: NPatchInfo = info_in;
    const w: f32 = float(texture.width);
    const h: f32 = float(texture.height);

    var patch_w: f32 = if (int(i32, dest.width) <= 0) 0 else dest.width;
    var patch_h: f32 = if (int(i32, dest.height) <= 0) 0 else dest.height;
    if (info.source.width < 0) {
        info.source.x -= info.source.width;
    }
    if (info.source.height < 0) {
        info.source.y -= info.source.height;
    }
    if (info.layout == npatch_three_patch_horizontal) {
        patch_h = info.source.height;
    }
    if (info.layout == npatch_three_patch_vertical) {
        patch_w = info.source.width;
    }

    var draw_center: bool = true;
    var draw_middle: bool = true;
    var left: f32 = float(info.left);
    var top: f32 = float(info.top);
    var right: f32 = float(info.right);
    var bottom: f32 = float(info.bottom);

    // Shrink left/right borders if the patch is narrower than the borders
    // combined; otherwise the lateral sides would overlap.
    if (patch_w <= (left + right) and info.layout != npatch_three_patch_vertical) {
        draw_center = false;
        left = (left / (left + right)) * patch_w;
        right = patch_w - left;
    }
    if (patch_h <= (top + bottom) and info.layout != npatch_three_patch_horizontal) {
        draw_middle = false;
        top = (top / (top + bottom)) * patch_h;
        bottom = patch_h - top;
    }

    // Quad corner positions and source UV coords.
    const va_x: f32 = 0;
    const va_y: f32 = 0;
    const vb_x: f32 = left;
    const vb_y: f32 = top;
    const vc_x: f32 = patch_w - right;
    const vc_y: f32 = patch_h - bottom;
    const vd_x: f32 = patch_w;
    const vd_y: f32 = patch_h;

    const ca_x: f32 = info.source.x / w;
    const ca_y: f32 = info.source.y / h;
    const cb_x: f32 = (info.source.x + left) / w;
    const cb_y: f32 = (info.source.y + top) / h;
    const cc_x: f32 = (info.source.x + info.source.width - right) / w;
    const cc_y: f32 = (info.source.y + info.source.height - bottom) / h;
    const cd_x: f32 = (info.source.x + info.source.width) / w;
    const cd_y: f32 = (info.source.y + info.source.height) / h;

    gl.setTexture(texture.id);
    gl.pushMatrix();
    gl.translate(dest.x, dest.y, 0);
    // `gl.rotate` takes turns; this module's API is still radians, so the crossing is here.
    gl.rotate(turnsFromRad(rotation_rad), 0, 0, 1);
    gl.translate(-origin[0], -origin[1], 0);
    gl.begin(.quads);
    gl.color4ub(tint.r, tint.g, tint.b, tint.a);
    gl.normal3f(0, 0, 1);

    if (info.layout == npatch_nine_patch) {
        // Top-left corner.
        nPatchQuad(
            gl,
            ca_x,
            cb_y,
            va_x,
            vb_y,
            cb_x,
            cb_y,
            vb_x,
            vb_y,
            cb_x,
            ca_y,
            vb_x,
            va_y,
            ca_x,
            ca_y,
            va_x,
            va_y,
        );
        if (draw_center) {
            // Top-center (stretched horizontally between left and right corners).
            nPatchQuad(
                gl,
                cb_x,
                cb_y,
                vb_x,
                vb_y,
                cc_x,
                cb_y,
                vc_x,
                vb_y,
                cc_x,
                ca_y,
                vc_x,
                va_y,
                cb_x,
                ca_y,
                vb_x,
                va_y,
            );
        }
        // Top-right corner.
        nPatchQuad(
            gl,
            cc_x,
            cb_y,
            vc_x,
            vb_y,
            cd_x,
            cb_y,
            vd_x,
            vb_y,
            cd_x,
            ca_y,
            vd_x,
            va_y,
            cc_x,
            ca_y,
            vc_x,
            va_y,
        );
        if (draw_middle) {
            // Middle-left edge (stretched vertically).
            nPatchQuad(
                gl,
                ca_x,
                cc_y,
                va_x,
                vc_y,
                cb_x,
                cc_y,
                vb_x,
                vc_y,
                cb_x,
                cb_y,
                vb_x,
                vb_y,
                ca_x,
                cb_y,
                va_x,
                vb_y,
            );
            if (draw_center) {
                // Middle-center (stretched both axes).
                nPatchQuad(
                    gl,
                    cb_x,
                    cc_y,
                    vb_x,
                    vc_y,
                    cc_x,
                    cc_y,
                    vc_x,
                    vc_y,
                    cc_x,
                    cb_y,
                    vc_x,
                    vb_y,
                    cb_x,
                    cb_y,
                    vb_x,
                    vb_y,
                );
            }
            // Middle-right edge.
            nPatchQuad(
                gl,
                cc_x,
                cc_y,
                vc_x,
                vc_y,
                cd_x,
                cc_y,
                vd_x,
                vc_y,
                cd_x,
                cb_y,
                vd_x,
                vb_y,
                cc_x,
                cb_y,
                vc_x,
                vb_y,
            );
        }
        // Bottom row.
        nPatchQuad(
            gl,
            ca_x,
            cd_y,
            va_x,
            vd_y,
            cb_x,
            cd_y,
            vb_x,
            vd_y,
            cb_x,
            cc_y,
            vb_x,
            vc_y,
            ca_x,
            cc_y,
            va_x,
            vc_y,
        );
        if (draw_center) {
            nPatchQuad(
                gl,
                cb_x,
                cd_y,
                vb_x,
                vd_y,
                cc_x,
                cd_y,
                vc_x,
                vd_y,
                cc_x,
                cc_y,
                vc_x,
                vc_y,
                cb_x,
                cc_y,
                vb_x,
                vc_y,
            );
        }
        nPatchQuad(
            gl,
            cc_x,
            cd_y,
            vc_x,
            vd_y,
            cd_x,
            cd_y,
            vd_x,
            vd_y,
            cd_x,
            cc_y,
            vd_x,
            vc_y,
            cc_x,
            cc_y,
            vc_x,
            vc_y,
        );
    } else if (info.layout == npatch_three_patch_vertical) {
        // Top, middle, bottom - full-width patches.
        nPatchQuad(
            gl,
            ca_x,
            cb_y,
            va_x,
            vb_y,
            cd_x,
            cb_y,
            vd_x,
            vb_y,
            cd_x,
            ca_y,
            vd_x,
            va_y,
            ca_x,
            ca_y,
            va_x,
            va_y,
        );
        if (draw_center) {
            nPatchQuad(
                gl,
                ca_x,
                cc_y,
                va_x,
                vc_y,
                cd_x,
                cc_y,
                vd_x,
                vc_y,
                cd_x,
                cb_y,
                vd_x,
                vb_y,
                ca_x,
                cb_y,
                va_x,
                vb_y,
            );
        }
        nPatchQuad(
            gl,
            ca_x,
            cd_y,
            va_x,
            vd_y,
            cd_x,
            cd_y,
            vd_x,
            vd_y,
            cd_x,
            cc_y,
            vd_x,
            vc_y,
            ca_x,
            cc_y,
            va_x,
            vc_y,
        );
    } else if (info.layout == npatch_three_patch_horizontal) {
        nPatchQuad(
            gl,
            ca_x,
            cd_y,
            va_x,
            vd_y,
            cb_x,
            cd_y,
            vb_x,
            vd_y,
            cb_x,
            ca_y,
            vb_x,
            va_y,
            ca_x,
            ca_y,
            va_x,
            va_y,
        );
        if (draw_center) {
            nPatchQuad(
                gl,
                cb_x,
                cd_y,
                vb_x,
                vd_y,
                cc_x,
                cd_y,
                vc_x,
                vd_y,
                cc_x,
                ca_y,
                vc_x,
                va_y,
                cb_x,
                ca_y,
                vb_x,
                va_y,
            );
        }
        nPatchQuad(
            gl,
            cc_x,
            cd_y,
            vc_x,
            vd_y,
            cd_x,
            cd_y,
            vd_x,
            vd_y,
            cd_x,
            ca_y,
            vd_x,
            va_y,
            cc_x,
            ca_y,
            vc_x,
            va_y,
        );
    }

    gl.end();
    gl.popMatrix();
    gl.setTexture(0);
}

/// Rotate image 90° counter-clockwise.  Pass the same allocator the
/// image was created with.
pub fn imageRotateCCW(
    gpa: Allocator,
    image: *Image,
) Allocator.Error!void {
    if (image.data == null or image.width == 0 or image.height == 0) {
        return;
    }
    const bpp_i: i32 = bytesPerPixel(image.format);
    if (bpp_i == 0) {
        return;
    }
    const bpp: usize = @intCast(bpp_i);
    const w: usize = @intCast(image.width);
    const h: usize = @intCast(image.height);

    const new_pixels: []u8 = try gpa.alloc(u8, w * h * bpp);
    errdefer gpa.free(new_pixels);
    const rotated: [*]u8 = new_pixels.ptr;
    const src: [*]const u8 = @ptrCast(image.data.?);
    for (0..h) |y| {
        for (0..w) |x| {
            // (x, y) source → (y, w-x-1) destination (rotate 90 CCW).
            const dst_idx: usize = (x * h + y) * bpp;
            const src_idx: usize = (y * w + (w - x - 1)) * bpp;
            for (0..bpp) |k| {
                rotated[dst_idx + k] = src[src_idx + k];
            }
        }
    }
    freeImageData(gpa, image.*);
    image.data = @ptrCast(new_pixels.ptr);
    const tmp: i32 = image.width;
    image.width = image.height;
    image.height = tmp;
}

/// Rotate an image by an arbitrary angle in radians.  Output Image
/// dimensions grow to fit the rotated content (no clipping).  Areas
/// outside the source are zero-filled.  Sampling is bilinear.
/// Reallocates `image.data`; the old buffer is freed via `gpa`.
/// No-op for compressed pixel formats.
pub fn imageRotate(
    gpa: Allocator,
    image: *Image,
    angle_rad: f32,
) Allocator.Error!void {
    if (image.data == null or image.width == 0 or image.height == 0) {
        return;
    }
    const bpp_i: i32 = bytesPerPixel(image.format);
    if (bpp_i == 0) {
        return;
    }
    const bpp: usize = @intCast(bpp_i);

    const rad: f32 = angle_rad;
    const sin_r: f32 = @sin(rad);
    const cos_r: f32 = @cos(rad);

    const src_w_f: f32 = float(image.width);
    const src_h_f: f32 = float(image.height);
    // Output dimensions: bounding box of the rotated source.
    const new_w_f: f32 = @abs(src_w_f * cos_r) + @abs(src_h_f * sin_r);
    const new_h_f: f32 = @abs(src_h_f * cos_r) + @abs(src_w_f * sin_r);
    const new_w: i32 = @trunc(new_w_f);
    const new_h: i32 = @trunc(new_h_f);
    const new_w_u: usize = @intCast(new_w);
    const new_h_u: usize = @intCast(new_h);

    const new_pixels: []u8 = try gpa.alloc(u8, new_w_u * new_h_u * bpp);
    errdefer gpa.free(new_pixels);
    const rotated: [*]u8 = new_pixels.ptr;
    // Zero-fill (output pixels outside source stay transparent).
    @memset(new_pixels, 0);

    const src: [*]const u8 = @ptrCast(image.data.?);
    const src_w: usize = @intCast(image.width);

    for (0..@intCast(new_h)) |yu| {
        const y: i32 = @intCast(yu);
        for (0..@intCast(new_w)) |xu| {
            const x: i32 = @intCast(xu);
            // Inverse-map: for each output pixel (x, y), where in the
            // source did it come from?  We rotate around both centers.
            const fx: f32 = float(x);
            const fy: f32 = float(y);
            const half_new_w: f32 = new_w_f / 2.0;
            const half_new_h: f32 = new_h_f / 2.0;
            const old_x_f: f32 = (fx - half_new_w) * cos_r + (fy - half_new_h) * sin_r + src_w_f / 2.0;
            const old_y_f: f32 = (fy - half_new_h) * cos_r - (fx - half_new_w) * sin_r + src_h_f / 2.0;

            if (old_x_f < 0 or old_x_f >= src_w_f or old_y_f < 0 or old_y_f >= src_h_f) {
                continue;
            }

            const x1: i32 = @floor(old_x_f);
            const y1: i32 = @floor(old_y_f);
            const x2: i32 = if (x1 + 1 < image.width) x1 + 1 else image.width - 1;
            const y2: i32 = if (y1 + 1 < image.height) y1 + 1 else image.height - 1;

            const px: f32 = old_x_f - float(x1);
            const py: f32 = old_y_f - float(y1);

            const x1_u: usize = @intCast(x1);
            const y1_u: usize = @intCast(y1);
            const x2_u: usize = @intCast(x2);
            const y2_u: usize = @intCast(y2);
            const dst_off: usize = (@as(usize, @intCast(y)) * new_w_u + @as(usize, @intCast(x))) * bpp;

            // Bilinear sample, channel-by-channel.
            for (0..bpp) |i| {
                const f1: f32 = float(src[(y1_u * src_w + x1_u) * bpp + i]);
                const f2: f32 = float(src[(y1_u * src_w + x2_u) * bpp + i]);
                const f3: f32 = float(src[(y2_u * src_w + x1_u) * bpp + i]);
                const f4: f32 = float(src[(y2_u * src_w + x2_u) * bpp + i]);
                const val: f32 = f1 * (1 - px) * (1 - py) + f2 * px * (1 - py) + f3 * (1 - px) * py + f4 * px * py;
                rotated[dst_off + i] = @trunc(clamp(val, 0.0, 255.0));
            }
        }
    }

    freeImageData(gpa, image.*);
    image.data = @ptrCast(new_pixels.ptr);
    image.width = new_w;
    image.height = new_h;
}

// Image alpha clear / contrast / triangle drawing
/// Clear pixels below an alpha threshold to a fill color.
pub fn imageAlphaClear(
    image: *Image,
    color: Color,
    threshold: f32,
) void {
    if (image.data == null or image.pixelFormat() != .uncompressed_r8g8b8a8) {
        return;
    }
    const data: [*]u8 = @ptrCast(image.data.?);
    const n: usize = imagePixelCount(image);
    const cutoff: u8 = @round(255.0 * threshold);
    for (0..n) |i| {
        if (data[i * 4 + 3] <= cutoff) {
            data[i * 4 + 0] = color.r;
            data[i * 4 + 1] = color.g;
            data[i * 4 + 2] = color.b;
            data[i * 4 + 3] = color.a;
        }
    }
}

/// Adjust contrast in-place. `contrast` in [-100, 100].
pub fn imageColorContrast(image: *Image, contrast_in: f32) void {
    if (image.data == null or image.pixelFormat() != .uncompressed_r8g8b8a8) {
        return;
    }
    var contrast: f32 = contrast_in;
    if (contrast < -100) {
        contrast = -100;
    }
    if (contrast > 100) {
        contrast = 100;
    }
    contrast = (100.0 + contrast) / 100.0;
    contrast *= contrast;
    const data: [*]u8 = @ptrCast(image.data.?);
    const n: usize = imagePixelCount(image);
    for (0..n) |i| {
        for (0..3) |k| {
            var p = float(data[i * 4 + k]) / 255.0;
            p -= 0.5;
            p *= contrast;
            p += 0.5;
            p *= 255.0;
            if (p < 0) {
                p = 0;
            }
            if (p > 255) {
                p = 255;
            }
            data[i * 4 + k] = @trunc(p);
        }
    }
}

/// Draw a filled triangle in image, with edge-walked scanlines.
/// Uses raylib's "edge function" / barycentric algorithm.
pub fn imageDrawTriangle(
    dst: *Image,
    v1: Vec2,
    v2: Vec2,
    v3: Vec2,
    color: Color,
) void {
    if (dst.data == null) {
        return;
    }
    // Compute bounding box of the triangle, then test each pixel by sign.
    var minx: i32 = @floor(@min(@min(v1[0], v2[0]), v3[0]));
    var miny: i32 = @floor(@min(@min(v1[1], v2[1]), v3[1]));
    var maxx: i32 = @ceil(@max(@max(v1[0], v2[0]), v3[0]));
    var maxy: i32 = @ceil(@max(@max(v1[1], v2[1]), v3[1]));
    // Clamp bbox to image dims (matches raylib's
    // ImageDrawTriangle - without this the pre-clamp the inner
    // loop iterates over off-screen pixels too).
    if (minx < 0) {
        minx = 0;
    }
    if (miny < 0) {
        miny = 0;
    }
    if (maxx >= dst.width) {
        maxx = dst.width - 1;
    }
    if (maxy >= dst.height) {
        maxy = dst.height - 1;
    }
    if (maxx < minx or maxy < miny) {
        return;
    }

    for (@intCast(miny)..@intCast(maxy + 1)) |yu| {
        const y: i32 = @intCast(yu);
        for (@intCast(minx)..@intCast(maxx + 1)) |xu| {
            const x: i32 = @intCast(xu);
            const px = float(x) + 0.5;
            const py = float(y) + 0.5;
            // Barycentric sign tests; positive in all three means inside.
            const w0: f32 = (v2[0] - v1[0]) * (py - v1[1]) - (v2[1] - v1[1]) * (px - v1[0]);
            const w1: f32 = (v3[0] - v2[0]) * (py - v2[1]) - (v3[1] - v2[1]) * (px - v2[0]);
            const w2: f32 = (v1[0] - v3[0]) * (py - v3[1]) - (v1[1] - v3[1]) * (px - v3[0]);
            if ((w0 >= 0 and w1 >= 0 and w2 >= 0) or (w0 <= 0 and w1 <= 0 and w2 <= 0)) {
                imageDrawPixel(dst, x, y, color);
            }
        }
    }
}

/// Draw a triangle with per-vertex colors interpolated across the
/// face - the barycentric Gouraud-shading equivalent for software
/// raster.
/// `c1`/`c2`/`c3` are blended at each pixel using normalized
/// barycentric weights derived from the same edge functions
/// `imageDrawTriangle` already uses.  Behaves like raylib's
/// `ImageDrawTriangleEx`.
/// Degenerate triangle (zero area) → silent no-op.
pub fn imageDrawTriangleGradient(
    dst: *Image,
    v1: Vec2,
    v2: Vec2,
    v3: Vec2,
    c1: Color,
    c2: Color,
    c3: Color,
) void {
    if (dst.data == null) {
        return;
    }
    var minx: i32 = @floor(@min(@min(v1[0], v2[0]), v3[0]));
    var miny: i32 = @floor(@min(@min(v1[1], v2[1]), v3[1]));
    var maxx: i32 = @ceil(@max(@max(v1[0], v2[0]), v3[0]));
    var maxy: i32 = @ceil(@max(@max(v1[1], v2[1]), v3[1]));
    // Clamp bbox to image bounds (matches raylib's
    // ImageDrawTriangle pattern; saves iterating over off-screen
    // pixels).
    if (minx < 0) {
        minx = 0;
    }
    if (miny < 0) {
        miny = 0;
    }
    if (maxx >= dst.width) {
        maxx = dst.width - 1;
    }
    if (maxy >= dst.height) {
        maxy = dst.height - 1;
    }
    if (maxx < minx or maxy < miny) {
        return;
    }

    // Total signed area × 2.  Used as the divisor so the per-pixel
    // sub-areas (w0, w1, w2) normalize to barycentrics in [0, 1].
    const denom: f32 = (v2[0] - v1[0]) * (v3[1] - v1[1]) - (v2[1] - v1[1]) * (v3[0] - v1[0]);
    if (denom == 0) {
        return;
    } // degenerate
    const inv_denom: f32 = 1.0 / denom;

    for (@intCast(miny)..@intCast(maxy + 1)) |yu| {
        const y: i32 = @intCast(yu);
        for (@intCast(minx)..@intCast(maxx + 1)) |xu| {
            const x: i32 = @intCast(xu);
            const px = float(x) + 0.5;
            const py = float(y) + 0.5;

            // Edge functions - same pattern as imageDrawTriangle.  Sign
            // depends on winding; we accept both positive and negative
            // consistent triples (matches the flat-color version).
            const w0: f32 = (v2[0] - v1[0]) * (py - v1[1]) - (v2[1] - v1[1]) * (px - v1[0]);
            const w1: f32 = (v3[0] - v2[0]) * (py - v2[1]) - (v3[1] - v2[1]) * (px - v2[0]);
            const w2: f32 = (v1[0] - v3[0]) * (py - v3[1]) - (v1[1] - v3[1]) * (px - v3[0]);

            const inside_pos: bool = w0 >= 0 and w1 >= 0 and w2 >= 0;
            const inside_neg: bool = w0 <= 0 and w1 <= 0 and w2 <= 0;
            if (!inside_pos and !inside_neg) {
                continue;
            }

            // Convert edge functions → barycentrics for v1, v2, v3.  In
            // canonical form, b1+b2+b3 = 1.  Mapping derived from the
            // edge-function-to-area relation:  b3 corresponds to the
            // edge opposite v3, i.e. the v1→v2 edge - which is `w0`.
            const b3: f32 = w0 * inv_denom;
            const b1: f32 = w1 * inv_denom;
            const b2: f32 = w2 * inv_denom;

            // Blend the three colors.  Channel-wise scalar mix.
            const r = b1 * float(c1.r) + b2 * float(c2.r) + b3 * float(c3.r);
            const g = b1 * float(c1.g) + b2 * float(c2.g) + b3 * float(c3.g);
            const b_chan = b1 * float(c1.b) + b2 * float(c2.b) + b3 * float(c3.b);
            const a = b1 * float(c1.a) + b2 * float(c2.a) + b3 * float(c3.a);

            const blended = Color{
                .r = @trunc(clamp(r, 0.0, 255.0)),
                .g = @trunc(clamp(g, 0.0, 255.0)),
                .b = @trunc(clamp(b_chan, 0.0, 255.0)),
                .a = @trunc(clamp(a, 0.0, 255.0)),
            };
            imageDrawPixel(dst, x, y, blended);
        }
    }
}

pub fn imageDrawTriangleLines(
    dst: *Image,
    v1: Vec2,
    v2: Vec2,
    v3: Vec2,
    color: Color,
) void {
    imageDrawLineV(dst, v1, v2, color);
    imageDrawLineV(dst, v2, v3, color);
    imageDrawLineV(dst, v3, v1, color);
}

/// Triangle fan: triangles share `points[0]`.
pub fn imageDrawTriangleFan(
    dst: *Image,
    points: []const Vec2,
    color: Color,
) void {
    if (points.len < 3) {
        return;
    }
    for (1..points.len - 1) |i| {
        imageDrawTriangle(dst, points[0], points[i], points[i + 1], color);
    }
}

/// Triangle strip: each new vertex extends the previous two.
pub fn imageDrawTriangleStrip(
    dst: *Image,
    points: []const Vec2,
    color: Color,
) void {
    if (points.len < 3) {
        return;
    }
    for (2..points.len) |i| {
        imageDrawTriangle(dst, points[i - 2], points[i - 1], points[i], color);
    }
}

// ===========================================================================
// Image lifecycle + simple generators + sub-image extraction
// ===========================================================================
// All Image data buffers are owned by the libc allocator (raylib's
// RL_FREE = free). Generators allocate; unloaders free. `imageCopy` and
// `imageFromImage` deep-copy pixel data so the result is independent of
// the source.

// `rlTextureParameters` lives in rlgl_gpu now (Phase 12 port).

/// Errors returned by `exportImageToMemory`.
pub const ExportImageError = Allocator.Error || error{
    /// The image's `data` pointer is null or `width`/`height` is zero.
    InvalidImage,
    /// The requested `file_type` isn't supported by zimr's encoder.
    /// Currently only ".png" is supported on the web target.
    UnsupportedFileType,
    /// Pixel format isn't trivially convertible to RGBA8 - typically
    /// a GPU-block-compressed format (DXT/ETC/PVRT/ASTC).
    UnsupportedPixelFormat,
};

const PixelFormat = types.PixelFormat;

/// Encode `image` to bytes in the format named by `file_type` (e.g.
/// `".png"`).  Returns owned bytes the caller must `gpa.free`
/// matches raylib's `ExportImageToMemory(image, fileType, *fileSize)`
/// shape but slice-shape instead of pointer + out-size.
/// Currently supports `.png` only on the web target.  Other formats
/// (BMP, TGA, JPG, QOI) would each need their own encoder; we have
/// only PNG internally because that's what `getClipboardImage` /
/// `setWindowIcon` round-trip through.
/// The image is normalised to RGBA8 in a scratch buffer before
/// encoding (we don't mutate `image`).  Compressed inputs return
/// `error.UnsupportedPixelFormat`.
pub fn exportImageToMemory(
    gpa: Allocator,
    image: Image,
    file_type: []const u8,
) ExportImageError![]u8 {
    if (image.data == null or image.width <= 0 or image.height <= 0) {
        return error.InvalidImage;
    }
    if (!eql(u8, file_type, ".png") and
        !eql(u8, file_type, "png"))
    {
        return error.UnsupportedFileType;
    }
    const fmt: PixelFormat = @fromBackingInt(@intCast(image.format));
    if (fmt.isCompressed()) {
        return error.UnsupportedPixelFormat;
    }

    // Convert to RGBA8 in a scratch buffer.  We do this through
    // get/setPixelColor on a fresh buffer - same path imageFormat
    // takes when it converts in place.
    const w: usize = @intCast(image.width);
    const h: usize = @intCast(image.height);
    const rgba_len: usize = w * h * 4;
    const rgba: []u8 = try gpa.alloc(u8, rgba_len);
    defer gpa.free(rgba);
    const src: [*]const u8 = @ptrCast(@alignCast(image.data));
    const src_pixel_size: usize = @intCast(getPixelDataSize(image.width, image.height, image.format));
    const px_stride: usize = src_pixel_size / (w * h);
    for (0..w * h) |i| {
        const c: Color = getPixelColor(@constCast(src[i * px_stride .. (i + 1) * px_stride].ptr), image.format);
        rgba[i * 4 + 0] = c.r;
        rgba[i * 4 + 1] = c.g;
        rgba[i * 4 + 2] = c.b;
        rgba[i * 4 + 3] = c.a;
    }

    const codecs_mod = codecs;
    return codecs_mod.png.encode(
        gpa,
        rgba,
        @intCast(image.width),
        @intCast(image.height),
    ) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.UnsupportedPixelFormat,
    };
}

/// Extract a single channel from a multi-channel image as a new
/// grayscale image.  Channel index: 0=R, 1=G, 2=B, 3=A.
/// raylib: `ImageFromChannel(Image image, int selectedChannel)`.
/// The output is `uncompressed_grayscale` (1 byte/pixel).  Source
/// channels beyond the source format's actual channel count return
/// 255 (fully opaque) - matches raylib.
pub fn imageFromChannel(
    gpa: Allocator,
    image: Image,
    selected_channel: i32,
) ExportImageError!Image {
    if (image.data == null or image.width <= 0 or image.height <= 0) {
        return error.InvalidImage;
    }
    const fmt: PixelFormat = @fromBackingInt(@intCast(image.format));
    if (fmt.isCompressed()) {
        return error.UnsupportedPixelFormat;
    }
    const w: usize = @intCast(image.width);
    const h: usize = @intCast(image.height);
    const out: []u8 = try gpa.alloc(u8, w * h);
    errdefer gpa.free(out);
    const src: [*]const u8 = @ptrCast(@alignCast(image.data));
    const src_pixel_size: usize = @intCast(getPixelDataSize(image.width, image.height, image.format));
    const px_stride: usize = src_pixel_size / (w * h);
    for (0..w * h) |i| {
        const c: Color = getPixelColor(@constCast(src[i * px_stride .. (i + 1) * px_stride].ptr), image.format);
        const v: u8 = switch (selected_channel) {
            0 => c.r,
            1 => c.g,
            2 => c.b,
            3 => c.a,
            else => 255,
        };
        out[i] = v;
    }
    return .{
        .data = @ptrCast(out.ptr),
        .width = image.width,
        .height = image.height,
        .mipmaps = 1,
        .format = @backingInt(PixelFormat.uncompressed_grayscale),
    };
}

/// Generate a mipmap chain for `image` in place.  Each level is a
/// 2× box-filter downscale of the previous level until we reach
/// 1×1 (or a 1×N / N×1 strip stops shrinking on one axis).
/// raylib: `ImageMipmaps(Image *image)`.
/// On success `image.data` points at a fresh allocation containing
/// the original level-0 followed by all generated levels, packed
/// contiguously.  Caller must `unloadImage(gpa, image)` with the
/// SAME allocator.  The original `image.data` is freed.
/// Compressed formats return `error.UnsupportedPixelFormat`.  Only
/// uncompressed RGBA8 is currently supported (the most common
/// case for textures used as mip pyramids).  Other uncompressed
/// formats are converted to RGBA8 first via the caller's choice
/// of `imageFormat`.
pub fn imageMipmaps(
    gpa: Allocator,
    image: *Image,
) ExportImageError!void {
    if (image.data == null or image.width <= 0 or image.height <= 0) {
        return error.InvalidImage;
    }
    const fmt: PixelFormat = @fromBackingInt(@intCast(image.format));
    if (fmt.isCompressed()) {
        return error.UnsupportedPixelFormat;
    }
    if (fmt != .uncompressed_r8g8b8a8) {
        // Caller should imageFormat(.uncompressed_r8g8b8a8) first.
        // Refusing here keeps the implementation simple - matches
        // the most common use case (texture mip-chain).
        return error.UnsupportedPixelFormat;
    }
    // Count desired levels (until both axes hit 1).
    var level_count: i32 = 1;
    var lw: i32 = image.width;
    var lh: i32 = image.height;
    while (lw > 1 or lh > 1) {
        lw = @max(lw >> 1, 1);
        lh = @max(lh >> 1, 1);
        level_count += 1;
    }
    if (image.mipmaps >= level_count) {
        return;
    } // already mipped

    // Compute total byte count for the new packed buffer.
    var total: usize = 0;
    lw = image.width;
    lh = image.height;
    for (0..@intCast(level_count)) |_| {
        total += @intCast(getPixelDataSize(lw, lh, image.format));
        lw = @max(lw >> 1, 1);
        lh = @max(lh >> 1, 1);
    }
    const out: []u8 = try gpa.alloc(u8, total);
    errdefer gpa.free(out);

    // Copy level 0 verbatim from the source.
    const src: [*]const u8 = @ptrCast(@alignCast(image.data));
    const level0_bytes: usize = @intCast(getPixelDataSize(image.width, image.height, image.format));
    @memcpy(out[0..level0_bytes], src[0..level0_bytes]);

    // Box-filter downscale, level n → level n+1.  Each pixel of the
    // destination averages the four-pixel block above it in the
    // source level.  Edge pixels for odd dimensions just clamp the
    // sampling - same approach raylib's ImageMipmaps takes.
    var cursor_in: usize = 0;
    var cursor_out: usize = level0_bytes;
    var prev_w: i32 = image.width;
    var prev_h: i32 = image.height;
    for (1..@intCast(level_count)) |_| {
        const cur_w: i32 = @max(prev_w >> 1, 1);
        const cur_h: i32 = @max(prev_h >> 1, 1);
        const cw: usize = @intCast(cur_w);
        const ch: usize = @intCast(cur_h);
        const pw: usize = @intCast(prev_w);
        for (0..ch) |y| {
            for (0..cw) |x| {
                const sx0: u64 = @min(x * 2, pw - 1);
                const sx1: u64 = @min(x * 2 + 1, pw - 1);
                const sy0 = @min(y * 2, @as(usize, @intCast(prev_h)) - 1);
                const sy1 = @min(y * 2 + 1, @as(usize, @intCast(prev_h)) - 1);
                var sum: [4]u32 = .{ 0, 0, 0, 0 };
                inline for ([_]usize{ sy0, sy1 }) |sy| {
                    inline for ([_]usize{ sx0, sx1 }) |sx| {
                        const i: usize = cursor_in + (sy * pw + sx) * 4;
                        sum[0] += out[i + 0];
                        sum[1] += out[i + 1];
                        sum[2] += out[i + 2];
                        sum[3] += out[i + 3];
                    }
                }
                const di: usize = cursor_out + (y * cw + x) * 4;
                out[di + 0] = @intCast((sum[0] + 2) / 4);
                out[di + 1] = @intCast((sum[1] + 2) / 4);
                out[di + 2] = @intCast((sum[2] + 2) / 4);
                out[di + 3] = @intCast((sum[3] + 2) / 4);
            }
        }
        cursor_in = cursor_out;
        cursor_out += cw * ch * 4;
        prev_w = cur_w;
        prev_h = cur_h;
    }

    // Replace image data.
    unloadImage(gpa, image.*);
    image.data = @ptrCast(out.ptr);
    image.mipmaps = level_count;
}

// ---- unloadImageColors / unloadImagePalette ---- (deleted)
// These were raylib-shape wrappers for `loadImageColors` /
// `loadImagePalette` which never got ported in this `textures`
// namespace.  In zimr the canonical pattern is "the loader returns
// an owned slice; you call `gpa.free(slice)` to release."  Cat 7
// of `notes/ziggification-candidates.md` flagged the wrappers as
// pointless raylib-API symmetry; the audit found zero callers, so
// the right move was deletion rather than `@deprecated`-marking.
// (The private `loadImageColors` in `models.zig` does already
// return an owned `[]Color`, freed by `ta.free` directly - see
// `leak_test.zig:185`.)

/// Convert `image.data` from its current pixel format to `new_format`
/// in place.  Allocates a fresh destination buffer at the new
/// format's size, walks each pixel through `getPixelColor`
/// (source-format→Color) then `setPixelColor` (Color→destination-
/// format), then frees the old buffer and installs the new.
/// Strong exception guarantee: on `error.OutOfMemory` from the
/// allocator, `image` is left untouched.
/// Compressed formats (DXT/ETC/PVRT/ASTC) are silent no-ops on
/// either source or destination - matches raylib's behaviour.
/// Mipmaps beyond level 0 are dropped (raylib parity).  Float
/// formats lose precision because the through-Color path is
/// RGBA8 - also raylib parity.
/// Pass the same allocator that was used to create `image`.
pub fn imageFormat(
    gpa: Allocator,
    image: *Image,
    new_format: PixelFormat,
) errors.ImageGenError!void {
    const old_format_int: i32 = image.format;
    const new_format_int: i32 = @backingInt(new_format);
    if (old_format_int == new_format_int) {
        return;
    }
    const old_format: PixelFormat = @fromBackingInt(@intCast(old_format_int));
    if (old_format.isCompressed() or new_format.isCompressed()) {
        // raylib also no-ops here; we'd need a real DXT/ETC encoder
        // to do anything useful, and the runtime path doesn't need
        // it (uploads accept compressed-as-is via rlLoadTexture).
        return;
    }
    if (image.data == null or image.width <= 0 or image.height <= 0) {
        return error.InvalidDimensions;
    }

    const w_u: usize = @intCast(image.width);
    const h_u: usize = @intCast(image.height);
    const px_count: usize = w_u * h_u;
    const new_byte_size: usize = @intCast(getPixelDataSize(image.width, image.height, new_format_int));
    const old_byte_size: usize = @intCast(getPixelDataSize(image.width, image.height, old_format_int));

    const new_data: []u8 = try gpa.alloc(u8, new_byte_size);
    errdefer gpa.free(new_data);

    // Compute per-pixel byte strides.  We've already excluded
    // compressed formats above, so getPixelDataSize / px_count
    // is integer-exact for both sides.
    const old_stride: usize = @divExact(old_byte_size, px_count);
    const new_stride: usize = @divExact(new_byte_size, px_count);

    const src: [*]u8 = @ptrCast(image.data.?);
    const dst: [*]u8 = new_data.ptr;
    var i: usize = 0;
    while (i < px_count) : (i += 1) {
        const src_pixel: *anyopaque = @ptrCast(src + i * old_stride);
        const dst_pixel: *anyopaque = @ptrCast(dst + i * new_stride);
        const c = getPixelColor(src_pixel, old_format_int);
        setPixelColor(dst_pixel, c, new_format_int);
    }

    // Swap.  Caller's allocator owns the old buffer; free it.
    const old_slice: []u8 = src[0..old_byte_size];
    gpa.free(old_slice);

    image.data = @ptrCast(new_data.ptr);
    image.format = new_format_int;
    image.mipmaps = 1;
}

test "imageFormat: same format is a no-op (no realloc)" {
    const ta: Allocator = std.testing.allocator;
    const buf: []u8 = try ta.alloc(u8, 4 * 4 * 4); // 4×4 RGBA8
    @memset(buf, 0xCC);
    var img: Image = .{
        .data = @ptrCast(buf.ptr),
        .width = 4,
        .height = 4,
        .mipmaps = 1,
        .format = @backingInt(PixelFormat.uncompressed_r8g8b8a8),
    };
    defer ta.free(buf); // we still own the original
    try imageFormat(ta, &img, .uncompressed_r8g8b8a8);
    // Same format → no swap, original buf still owned by us.
    try expectEqual(@backingInt(PixelFormat.uncompressed_r8g8b8a8), img.format);
}

test "imageFormat: RGBA8 → grayscale shrinks buffer + preserves mean" {
    const ta: Allocator = std.testing.allocator;
    const buf: []u8 = try ta.alloc(u8, 2 * 2 * 4);
    // Four pixels: red, green, blue, white.
    buf[0] = 255;
    buf[1] = 0;
    buf[2] = 0;
    buf[3] = 255; // red
    buf[4] = 0;
    buf[5] = 255;
    buf[6] = 0;
    buf[7] = 255; // green
    buf[8] = 0;
    buf[9] = 0;
    buf[10] = 255;
    buf[11] = 255; // blue
    buf[12] = 255;
    buf[13] = 255;
    buf[14] = 255;
    buf[15] = 255; // white
    var img: Image = .{
        .data = @ptrCast(buf.ptr),
        .width = 2,
        .height = 2,
        .mipmaps = 1,
        .format = @backingInt(PixelFormat.uncompressed_r8g8b8a8),
    };
    try imageFormat(ta, &img, .uncompressed_grayscale);
    const out_ptr: [*]u8 = @ptrCast(img.data.?);
    const out_slice: []u8 = out_ptr[0..4];
    defer ta.free(out_slice);

    try expectEqual(@backingInt(PixelFormat.uncompressed_grayscale), img.format);
    try expectEqual(@as(i32, 1), img.mipmaps);
    // setPixelColor uses the standard luma formula:
    //   Y = 0.299 R + 0.587 G + 0.114 B
    // applied in normalised 0-1 space and scaled back to 0-255.
    // red   → 0.299 × 255 = 76.245 → 76
    // green → 0.587 × 255 = 149.685 → 149
    // blue  → 0.114 × 255 = 29.07 → 29
    // white → 1.0   × 255 = 255
    const gray: [*]u8 = @ptrCast(img.data.?);
    try expectEqual(@as(u8, 76), gray[0]); // red
    try expectEqual(@as(u8, 149), gray[1]); // green
    try expectEqual(@as(u8, 29), gray[2]); // blue
    try expectEqual(@as(u8, 255), gray[3]); // white
}

test "imageFormat: compressed source is silent no-op" {
    const ta: Allocator = std.testing.allocator;
    const buf: []u8 = try ta.alloc(u8, 16); // 4x4 DXT1 = 8 bytes - give it room
    defer ta.free(buf);
    @memset(buf, 0);
    var img: Image = .{
        .data = @ptrCast(buf.ptr),
        .width = 4,
        .height = 4,
        .mipmaps = 1,
        .format = @backingInt(PixelFormat.compressed_dxt1_rgb),
    };
    try imageFormat(ta, &img, .uncompressed_r8g8b8a8); // no-op
    try expectEqual(@backingInt(PixelFormat.compressed_dxt1_rgb), img.format);
}

test "imageFormat: null data returns InvalidDimensions" {
    const ta: Allocator = std.testing.allocator;
    var img: Image = .{
        .data = null,
        .width = 4,
        .height = 4,
        .mipmaps = 1,
        .format = @backingInt(PixelFormat.uncompressed_r8g8b8a8),
    };
    try expectError(error.InvalidDimensions, imageFormat(ta, &img, .uncompressed_grayscale));
}

test "imageFormat: non-positive dimensions return InvalidDimensions" {
    const ta: Allocator = std.testing.allocator;
    const buf: []u8 = try ta.alloc(u8, 16);
    defer ta.free(buf);
    var img: Image = .{
        .data = @ptrCast(buf.ptr),
        .width = 0,
        .height = 4,
        .mipmaps = 1,
        .format = @backingInt(PixelFormat.uncompressed_r8g8b8a8),
    };
    try expectError(error.InvalidDimensions, imageFormat(ta, &img, .uncompressed_grayscale));
}

/// Extract a rectangular sub-region of an image as a new Image.
/// Result has `mipmaps = 1` regardless of the source.  No bounds
/// clamping - caller must keep `rec` within the source.  Free with
/// `unloadImage(gpa, sub)` using the same allocator.
pub fn imageFromImage(
    gpa: Allocator,
    image: Image,
    rec: Rectangle,
) errors.ImageGenError!Image {
    if (image.data == null) {
        return error.InvalidDimensions;
    }
    const bpp: usize = @intCast(getPixelDataSize(1, 1, image.format));
    const rw: usize = @trunc(rec.width);
    const rh: usize = @trunc(rec.height);
    const rx: usize = @trunc(rec.x);
    const ry: usize = @trunc(rec.y);
    const sw: usize = @intCast(image.width);
    const new_pixels: []u8 = try gpa.alloc(u8, rw * rh * bpp);
    errdefer gpa.free(new_pixels);
    const dst: [*]u8 = new_pixels.ptr;
    const src: [*]const u8 = @ptrCast(image.data);
    for (0..rh) |y| {
        const dst_off: usize = y * rw * bpp;
        const src_off: usize = ((y + ry) * sw + rx) * bpp;
        @memcpy(dst[dst_off .. dst_off + rw * bpp], src[src_off .. src_off + rw * bpp]);
    }
    return .{
        .data = @ptrCast(dst),
        .width = @intCast(rw),
        .height = @intCast(rh),
        .mipmaps = 1,
        .format = image.format,
    };
}

// ===========================================================================
// Procedural image generators
// ===========================================================================
// Pure-CPU image fills. All return RGBA8 images allocated with libc
// `malloc`; caller frees with `unloadImage`. None of these depend on
// stb_image, file I/O, or rlgl - they're entirely deterministic from
// their parameters (white-noise excepted, which uses `getRandomValue`).

inline fn lerpColor(
    a: Color,
    b: Color,
    t: f32,
) Color {
    const inv: f32 = 1.0 - t;
    return .{
        .r = @trunc(float(a.r) * inv + float(b.r) * t),
        .g = @trunc(float(a.g) * inv + float(b.g) * t),
        .b = @trunc(float(a.b) * inv + float(b.b) * t),
        .a = @trunc(float(a.a) * inv + float(b.a) * t),
    };
}

/// Linear gradient.  `direction_rad` is in radians: 0 goes top→bottom,
/// 90° left→right, etc. (counter-clockwise from "up").  The math:
/// rotate the gradient axis by 90°-direction, then for each pixel
/// project its position onto that axis and lerp between `start` and
/// `end`.  Caller frees with `unloadImage(gpa, img)`.
pub fn genImageGradientLinear(
    gpa: Allocator,
    width: i32,
    height: i32,
    direction_rad: f32,
    start: Color,
    end: Color,
) errors.ImageGenError!Image {
    if (width <= 0 or height <= 0) {
        return error.InvalidDimensions;
    }
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const pixels: []Color = try gpa.alloc(Color, w * h);
    errdefer gpa.free(pixels);

    const rad: f32 = (pi / 2.0) - direction_rad;
    const cos_d: f32 = @cos(rad);
    const sin_d: f32 = @sin(rad);
    const wf: f32 = float(width);
    const hf: f32 = float(height);
    const start_pos: f32 = 0.5 - cos_d * wf / 2 - sin_d * hf / 2;
    // Different quadrants make either the top-left or top-right pixel the
    // farthest point on the gradient axis. Pick the right magnitude so
    // the per-pixel `factor` lands in [-1, 1] before the clamp.
    const max_pos: f32 = if (signbit(sin_d) == signbit(cos_d))
        @abs(start_pos)
    else
        @abs(start_pos + wf * cos_d);

    for (0..w) |i| {
        for (0..h) |j| {
            const ipos: f32 = start_pos + float(i) * cos_d + float(j) * sin_d;
            const pos: f32 = ipos / max_pos;
            const factor: f32 = clamp(pos, -1.0, 1.0) / 2.0 + 0.5;
            pixels[j * w + i] = lerpColor(start, end, factor);
        }
    }
    return rgba8Image(@ptrCast(pixels.ptr), width, height);
}

/// Radial gradient from `inner` (centre) to `outer` (edge).  `density`
/// is a [0, 1] knob: at 0 the gradient starts at the centre; closer to
/// 1 the inner color spreads further before fading.  Caller frees with
/// `unloadImage(gpa, img)`.
pub fn genImageGradientRadial(
    gpa: Allocator,
    width: i32,
    height: i32,
    density: f32,
    inner: Color,
    outer: Color,
) errors.ImageGenError!Image {
    if (width <= 0 or height <= 0) {
        return error.InvalidDimensions;
    }
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const pixels: []Color = try gpa.alloc(Color, w * h);
    errdefer gpa.free(pixels);

    const radius: f32 = if (width < height)
        float(width) / 2.0
    else
        float(height) / 2.0;
    const cx: f32 = float(width) / 2.0;
    const cy: f32 = float(height) / 2.0;

    for (0..h) |y| {
        for (0..w) |x| {
            const dx: f32 = float(x) - cx;
            const dy: f32 = float(y) - cy;
            const dist: f32 = hypot(dx, dy);
            const factor_raw: f32 = (dist - radius * density) / (radius * (1.0 - density));
            const factor: f32 = clamp(factor_raw, 0.0, 1.0);
            pixels[y * w + x] = lerpColor(inner, outer, factor);
        }
    }
    return rgba8Image(@ptrCast(pixels.ptr), width, height);
}

/// Square (Manhattan-distance) gradient from `inner` (centre) to
/// `outer` (edge).  `density` works the same as in
/// `genImageGradientRadial`.  Caller frees with `unloadImage(gpa, img)`.
pub fn genImageGradientSquare(
    gpa: Allocator,
    width: i32,
    height: i32,
    density: f32,
    inner: Color,
    outer: Color,
) errors.ImageGenError!Image {
    if (width <= 0 or height <= 0) {
        return error.InvalidDimensions;
    }
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const pixels: []Color = try gpa.alloc(Color, w * h);
    errdefer gpa.free(pixels);

    const cx: f32 = float(width) / 2.0;
    const cy: f32 = float(height) / 2.0;

    for (0..h) |y| {
        for (0..w) |x| {
            const norm_x: f32 = @abs(float(x) - cx) / cx;
            const norm_y: f32 = @abs(float(y) - cy) / cy;
            const manhattan: f32 = @max(norm_x, norm_y);
            const factor_raw: f32 = (manhattan - density) / (1.0 - density);
            const factor: f32 = clamp(factor_raw, 0.0, 1.0);
            pixels[y * w + x] = lerpColor(inner, outer, factor);
        }
    }
    return rgba8Image(@ptrCast(pixels.ptr), width, height);
}

/// Generate a grayscale `Image` whose pixels are the bytes of
/// `text` - a debug/utility helper for visualising raw byte data,
/// NOT for rendering text glyphs.  For "render this string into
/// an image" you want text2d.zig's `imageDrawText` (which uses the
/// default font and produces a proper RGBA8 anti-aliased result).
/// Output is `width × height` bytes of single-channel grayscale;
/// text bytes are copied left-to-right, top-to-bottom; if `text`
/// is shorter than the image the remaining pixels stay zero
/// (allocator zeroes); if longer the excess is silently truncated.
pub fn genImageText(
    gpa: Allocator,
    width: i32,
    height: i32,
    s: []const u8,
) errors.ImageGenError!Image {
    if (width <= 0 or height <= 0) {
        return error.InvalidDimensions;
    }
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const total: usize = w * h;
    const buf: []u8 = try gpa.alloc(u8, total);
    errdefer gpa.free(buf);
    @memset(buf, 0);
    const copy_len: usize = @min(s.len, total);
    @memcpy(buf[0..copy_len], s[0..copy_len]);
    return .{
        .data = @ptrCast(buf.ptr),
        .width = width,
        .height = height,
        .mipmaps = 1,
        .format = @backingInt(types.PixelFormat.uncompressed_grayscale),
    };
}

// ---- internal helpers

// ===========================================================================
// In-place image manipulation (allocate-and-swap pattern)
// ===========================================================================
// These all mutate `*image`: free the old buffer and replace it with a
// freshly-allocated one. Mipmap levels beyond 0 are dropped - caller
// must regenerate them if needed. Compressed pixel formats are
// unsupported (the operations would have to decompress/recompress;
// those code paths are no-ops in raylib too).

// imageResize / imageResizeNN - Roadmap Step 12
//
// `imageResize` does bilinear resampling for high quality.  raylib's
// C version uses stb_image_resize for bicubic; we use bilinear here
// (simpler, no extra dep - Zig stdlib doesn't have a bicubic
// resampler).  For pixel art, use `imageResizeNN` (nearest-neighbor).
// Both reallocate `image.data` and free the old buffer.  Operate on
// any pixel format we have a `getImageColor`/`imageDrawPixel` pair
// for (GRAYSCALE/GRAY_ALPHA/R8G8B8/R8G8B8A8).

/// Resize image using bilinear filtering.  Quality is appropriate
/// for photographic content; for pixel art use `imageResizeNN`.
/// Pass the same allocator the image was created with - the old
/// pixel buffer is freed after the new (resized) buffer is built.
pub fn imageResize(
    gpa: Allocator,
    image: *Image,
    newWidth: i32,
    newHeight: i32,
) Allocator.Error!void {
    if (image.data == null or image.width == 0 or image.height == 0) {
        return;
    }
    if (newWidth <= 0 or newHeight <= 0) {
        return;
    }
    if (newWidth == image.width and newHeight == image.height) {
        return;
    }
    const bpp_i: i32 = bytesPerPixel(image.format);
    if (bpp_i == 0) {
        return;
    }
    const bpp: usize = @intCast(bpp_i);

    const new_w_u: usize = @intCast(newWidth);
    const new_h_u: usize = @intCast(newHeight);

    const new_pixels: []u8 = try gpa.alloc(u8, new_w_u * new_h_u * bpp);
    errdefer gpa.free(new_pixels);
    const out: [*]u8 = new_pixels.ptr;

    const src: [*]const u8 = @ptrCast(image.data.?);
    const src_w: usize = @intCast(image.width);
    const src_w_max: i32 = image.width - 1;
    const src_h_max: i32 = image.height - 1;

    // Scale ratios (ratio of source range to dest range, with -1 to
    // map dest's last pixel to source's last pixel exactly).
    const ratio_x: f32 = if (newWidth > 1)
        float(src_w_max) / float(newWidth - 1)
    else
        0;
    const ratio_y: f32 = if (newHeight > 1)
        float(src_h_max) / float(newHeight - 1)
    else
        0;

    for (0..@intCast(newHeight)) |yu| {
        const y: i32 = @intCast(yu);
        for (0..@intCast(newWidth)) |xu| {
            const x: i32 = @intCast(xu);
            const sx_f: f32 = float(x) * ratio_x;
            const sy_f: f32 = float(y) * ratio_y;
            const x1: i32 = @floor(sx_f);
            const y1: i32 = @floor(sy_f);
            const x2: i32 = if (x1 < src_w_max) x1 + 1 else x1;
            const y2: i32 = if (y1 < src_h_max) y1 + 1 else y1;
            const px: f32 = sx_f - float(x1);
            const py: f32 = sy_f - float(y1);

            const x1_u: usize = @intCast(x1);
            const y1_u: usize = @intCast(y1);
            const x2_u: usize = @intCast(x2);
            const y2_u: usize = @intCast(y2);
            const dst_off: usize = (@as(usize, @intCast(y)) * new_w_u + @as(usize, @intCast(x))) * bpp;

            for (0..bpp) |i| {
                const f1: f32 = float(src[(y1_u * src_w + x1_u) * bpp + i]);
                const f2: f32 = float(src[(y1_u * src_w + x2_u) * bpp + i]);
                const f3: f32 = float(src[(y2_u * src_w + x1_u) * bpp + i]);
                const f4: f32 = float(src[(y2_u * src_w + x2_u) * bpp + i]);
                const val: f32 = f1 * (1 - px) * (1 - py) + f2 * px * (1 - py) + f3 * (1 - px) * py + f4 * px * py;
                out[dst_off + i] = @trunc(clamp(val, 0.0, 255.0));
            }
        }
    }

    freeImageData(gpa, image.*);
    image.data = @ptrCast(new_pixels.ptr);
    image.width = newWidth;
    image.height = newHeight;
}

/// Resize image using nearest-neighbor sampling.  Best for pixel art
/// or when crisp pixel boundaries are desired.  Faster than
/// `imageResize`.  Pass the same allocator the image was created with.
pub fn imageResizeNN(
    gpa: Allocator,
    image: *Image,
    newWidth: i32,
    newHeight: i32,
) Allocator.Error!void {
    if (image.data == null or image.width == 0 or image.height == 0) {
        return;
    }
    if (newWidth <= 0 or newHeight <= 0) {
        return;
    }
    if (newWidth == image.width and newHeight == image.height) {
        return;
    }
    const bpp_i: i32 = bytesPerPixel(image.format);
    if (bpp_i == 0) {
        return;
    }
    const bpp: usize = @intCast(bpp_i);

    const new_w_u: usize = @intCast(newWidth);
    const new_h_u: usize = @intCast(newHeight);

    const new_pixels: []u8 = try gpa.alloc(u8, new_w_u * new_h_u * bpp);
    errdefer gpa.free(new_pixels);
    const out: [*]u8 = new_pixels.ptr;
    const src: [*]const u8 = @ptrCast(image.data.?);
    const src_w: usize = @intCast(image.width);

    // Use raylib's fixed-point trick: shift left 16 then divide
    // (replacing one float division with one integer divide per
    // dimension).
    const x_ratio: i32 = @intCast(@divTrunc(@as(i64, image.width) << 16, @as(i64, newWidth)) + 1);
    const y_ratio: i32 = @intCast(@divTrunc(@as(i64, image.height) << 16, @as(i64, newHeight)) + 1);

    for (0..@intCast(newHeight)) |yu| {
        const y: i32 = @intCast(yu);
        const sy: i32 = (y * y_ratio) >> 16;
        const sy_u: usize = @intCast(sy);
        for (0..@intCast(newWidth)) |xu| {
            const x: i32 = @intCast(xu);
            const sx: i32 = (x * x_ratio) >> 16;
            const sx_u: usize = @intCast(sx);
            const dst_off: usize = (@as(usize, @intCast(y)) * new_w_u + @as(usize, @intCast(x))) * bpp;
            const src_off: usize = (sy_u * src_w + sx_u) * bpp;
            for (0..bpp) |i| {
                out[dst_off + i] = src[src_off + i];
            }
        }
    }

    freeImageData(gpa, image.*);
    image.data = @ptrCast(new_pixels.ptr);
    image.width = newWidth;
    image.height = newHeight;
}

/// Resize the image's canvas to (`new_w`, `new_h`), preserving pixel
/// content.  The original image is positioned at (`off_x`, `off_y`)
/// in the new canvas; new area is filled with `fill`.  Negative
/// offsets clip the source.  Pass the same allocator the image was
/// created with - the old buffer is freed after the new canvas is
/// built.
pub fn imageResizeCanvas(
    gpa: Allocator,
    image: *Image,
    new_w: i32,
    new_h: i32,
    off_x: i32,
    off_y: i32,
    fill: Color,
) Allocator.Error!void {
    if (image.data == null or image.width == 0 or image.height == 0) {
        return;
    }
    if (image.pixelFormat().isCompressed()) {
        return;
    }
    if (new_w == image.width and new_h == image.height) {
        return;
    }

    // Compute source rect (within the OLD image) and destination
    // position (in the NEW canvas).
    var src = Rectangle{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(image.width),
        .height = @floatFromInt(image.height),
    };
    var dst_pos = Vec2{ @floatFromInt(off_x), @floatFromInt(off_y) };

    if (off_x < 0) {
        src.x = @floatFromInt(-off_x);
        src.width += @floatFromInt(off_x);
        dst_pos[0] = 0;
    } else if (off_x + image.width > new_w) {
        src.width = @floatFromInt(new_w - off_x);
    }
    if (off_y < 0) {
        src.y = @floatFromInt(-off_y);
        src.height += @floatFromInt(off_y);
        dst_pos[1] = 0;
    } else if (off_y + image.height > new_h) {
        src.height = @floatFromInt(new_h - off_y);
    }
    if (float(new_w) < src.width) {
        src.width = @floatFromInt(new_w);
    }
    if (float(new_h) < src.height) {
        src.height = @floatFromInt(new_h);
    }

    const bpp: usize = @intCast(getPixelDataSize(1, 1, image.format));
    const nw_u: usize = @intCast(new_w);
    const nh_u: usize = @intCast(new_h);
    const new_pixels: []u8 = try gpa.alloc(u8, nw_u * nh_u * bpp);
    errdefer gpa.free(new_pixels);
    @memset(new_pixels, 0);
    const dst: [*]u8 = new_pixels.ptr;

    // Fill: write the fill color into pixel 0, then memcpy that pixel
    // across the first row, then memcpy the first row down.
    setPixelColor(@ptrCast(dst), fill, image.format);
    var x: usize = 1;
    while (x < nw_u) : (x += 1) {
        @memcpy(dst[x * bpp .. (x + 1) * bpp], dst[0..bpp]);
    }
    var y: usize = 1;
    while (y < nh_u) : (y += 1) {
        @memcpy(dst[y * nw_u * bpp .. (y + 1) * nw_u * bpp], dst[0 .. nw_u * bpp]);
    }

    // Copy the source content into its destination position.
    const src_h: usize = @trunc(src.height);
    const src_w: usize = @trunc(src.width);
    const src_x: usize = @trunc(src.x);
    const src_y: usize = @trunc(src.y);
    const dpx: usize = @trunc(dst_pos[0]);
    const dpy: usize = @trunc(dst_pos[1]);
    const sw: usize = @intCast(image.width);
    const old_src: [*]const u8 = @ptrCast(image.data);

    var iy: usize = 0;
    while (iy < src_h) : (iy += 1) {
        const dst_off: usize = ((dpy + iy) * nw_u + dpx) * bpp;
        const src_off: usize = ((src_y + iy) * sw + src_x) * bpp;
        @memcpy(dst[dst_off .. dst_off + src_w * bpp], old_src[src_off .. src_off + src_w * bpp]);
    }

    freeImageData(gpa, image.*);
    image.data = @ptrCast(new_pixels.ptr);
    image.width = new_w;
    image.height = new_h;
}

/// Pad image to next power-of-two dimensions.  Useful for OpenGL ES 2
/// (and WebGL 1) which require POT textures for mipmaps and certain
/// wrap modes.  New padding is filled with `fill`.
pub fn imageToPOT(
    gpa: Allocator,
    image: *Image,
    fill: Color,
) Allocator.Error!void {
    if (image.data == null or image.width <= 0 or image.height <= 0) {
        return;
    }
    const w_u: u32 = @intCast(image.width);
    const h_u: u32 = @intCast(image.height);
    const pot_w_u = ceilPowerOfTwo(u32, w_u) catch return;
    const pot_h_u = ceilPowerOfTwo(u32, h_u) catch return;
    if (pot_w_u == w_u and pot_h_u == h_u) {
        return;
    }
    try imageResizeCanvas(gpa, image, @intCast(pot_w_u), @intCast(pot_h_u), 0, 0, fill);
}

// ===========================================================================
// Texture API completion - Step 2 of the 20-step coverage plan
// ===========================================================================
// High-level wrappers around the existing rlgl_gpu primitives.  Every
// function here either:
//   - Promotes a CPU `Image` to a GPU `Texture` (loadTextureFromImage)
//   - Re-uploads pixel data to an existing texture (updateTexture / Rec)
//   - Bundles framebuffer + colour + depth into a `RenderTexture`
//     (loadRenderTexture / unloadRenderTexture)
//   - Generates a mipmap pyramid (genTextureMipmaps)
// These exist because the rlgl-level API is stateful and verbose
// (build FBO, attach colour, attach depth, check completeness).  The
// wrappers do those steps in one call and return a typed value.
// Wasm-gating: every function routes through `rlgl.fwd.zig` which
// no-ops on host targets (returns 0 / does nothing).  The host
// fallback means tests can call these without a GPU; the smoke
// harness verifies the wasm path actually does something.

// ---- tests (formerly src/tests/textures_test.zig)
// Tolerance for float round-trip (one byte of precision).
const _test_eps: f32 = 1.0 / 255.0;
fn closeEnough(a: f32, b: f32) bool {
    return @abs(a - b) <= _test_eps;
}
// ===========================================================================
// fade / colorAlpha
// ===========================================================================

test "fade(red, 1.0) preserves alpha" {
    const red: Color = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    const out: Color = fade(red, 1.0);
    try expect(out.r == 255);
    try expect(out.g == 0);
    try expect(out.b == 0);
    try expect(out.a == 255);
}

test "fade(red, 0.5) halves alpha" {
    const red: Color = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    const out: Color = fade(red, 0.5);
    try expect(out.a >= 126 and out.a <= 128);
}

test "fade clamps alpha to [0,1]" {
    const c: Color = .{ .r = 100, .g = 100, .b = 100, .a = 200 };
    try expect(fade(c, -0.5).a == 0);
    try expect(fade(c, 1.5).a == 255);
}

test "colorAlpha and fade behave identically" {
    const c: Color = .{ .r = 50, .g = 100, .b = 150, .a = 200 };
    const a: Color = fade(c, 0.42);
    const b: Color = colorAlpha(c, 0.42);
    try expect(a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a);
}

// ===========================================================================
// colorToInt / GetColor (round-trip)
// ===========================================================================

test "colorToInt then GetColor round-trips" {
    const c: Color = .{ .r = 0x12, .g = 0x34, .b = 0x56, .a = 0x78 };
    const packed_int: i32 = colorToInt(c);
    const c2: Color = getColor(@bitCast(packed_int));
    try expect(c2.r == c.r and c2.g == c.g and c2.b == c.b and c2.a == c.a);
}

test "colorToInt: white_c = 0xFFFFFFFF" {
    const white_c: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const packed_int: i32 = colorToInt(white_c);
    try expect(@as(u32, @bitCast(packed_int)) == 0xFFFFFFFF);
}

test "colorToInt: black_c = 0x000000FF" {
    const black_c: Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const packed_int: i32 = colorToInt(black_c);
    try expect(@as(u32, @bitCast(packed_int)) == 0x000000FF);
}

// ===========================================================================
// colorIsEqual
// ===========================================================================

test "colorIsEqual: identical and different" {
    const a: Color = .{ .r = 100, .g = 100, .b = 100, .a = 255 };
    const b: Color = .{ .r = 100, .g = 100, .b = 100, .a = 255 };
    const c: Color = .{ .r = 100, .g = 101, .b = 100, .a = 255 };
    try expect(colorIsEqual(a, b));
    try expect(!colorIsEqual(a, c));
}

// ===========================================================================
// colorNormalize / colorFromNormalized (round-trip)
// ===========================================================================

test "colorNormalize: white_c is (1,1,1,1)" {
    const white_c: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const n: Vec = colorNormalize(white_c);
    try expect(closeEnough(n[0], 1.0));
    try expect(closeEnough(n[1], 1.0));
    try expect(closeEnough(n[2], 1.0));
    try expect(closeEnough(n[3], 1.0));
}

test "colorNormalize: black_c is (0,0,0,1)" {
    const black_c: Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const n: Vec = colorNormalize(black_c);
    try expect(closeEnough(n[0], 0));
    try expect(closeEnough(n[1], 0));
    try expect(closeEnough(n[2], 0));
    try expect(closeEnough(n[3], 1));
}

test "colorNormalize then colorFromNormalized round-trips" {
    const c: Color = .{ .r = 100, .g = 150, .b = 200, .a = 255 };
    const n: Vec = colorNormalize(c);
    const c2: Color = colorFromNormalized(n);
    try expect(c2.r == c.r and c2.g == c.g and c2.b == c.b and c2.a == c.a);
}

// ===========================================================================
// HSV round-trip
// ===========================================================================

test "colorToHSV: pure red has hue 0, saturation 1, value 1" {
    const red: Color = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    const hsv: Vec = colorToHSV(red);
    try expect(closeEnough(hsv[0], 0)); // hue
    try expect(closeEnough(hsv[1], 1)); // saturation
    try expect(closeEnough(hsv[2], 1)); // value
}

test "colorToHSV: pure green has hue 120" {
    const green: Color = .{ .r = 0, .g = 255, .b = 0, .a = 255 };
    const hsv: Vec = colorToHSV(green);
    try expect(closeEnough(hsv[0], 120));
}

test "colorToHSV: pure blue has hue 240" {
    const blue: Color = .{ .r = 0, .g = 0, .b = 255, .a = 255 };
    const hsv: Vec = colorToHSV(blue);
    try expect(closeEnough(hsv[0], 240));
}

test "colorFromHSV(0, 1, 1) = pure red" {
    const c: Color = colorFromHSV(0, 1, 1);
    try expect(c.r == 255 and c.g == 0 and c.b == 0);
}

test "colorFromHSV(120, 1, 1) = pure green" {
    const c: Color = colorFromHSV(120, 1, 1);
    try expect(c.r == 0 and c.g == 255 and c.b == 0);
}

test "HSV round-trip preserves the colour within 1 byte" {
    const c: Color = .{ .r = 100, .g = 150, .b = 200, .a = 255 };
    const hsv: Vec = colorToHSV(c);
    const c2: Color = colorFromHSV(hsv[0], hsv[1], hsv[2]);
    // Allow ±2 bytes since HSV→RGB is lossy at integer precision.
    try expect(@abs(@as(i32, c.r) - @as(i32, c2.r)) <= 2);
    try expect(@abs(@as(i32, c.g) - @as(i32, c2.g)) <= 2);
    try expect(@abs(@as(i32, c.b) - @as(i32, c2.b)) <= 2);
}

// ===========================================================================
// colorTint / colorBrightness / colorContrast / colorLerp
// ===========================================================================

test "colorTint(red, white_c) = red (white_c tint is identity)" {
    const red: Color = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    const white_c: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const out: Color = colorTint(red, white_c);
    try expect(out.r == red.r and out.g == red.g and out.b == red.b and out.a == red.a);
}

test "colorTint(white_c, red) = red" {
    const white_c: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const red: Color = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    const out: Color = colorTint(white_c, red);
    try expect(out.r == 255 and out.g == 0 and out.b == 0);
}

test "colorBrightness(c, 0) = c (identity)" {
    const c: Color = .{ .r = 100, .g = 150, .b = 200, .a = 255 };
    const out: Color = colorBrightness(c, 0);
    try expect(out.r == c.r and out.g == c.g and out.b == c.b);
}

test "colorBrightness(c, 1) = white" {
    const c: Color = .{ .r = 100, .g = 50, .b = 200, .a = 255 };
    const out: Color = colorBrightness(c, 1);
    try expect(out.r == 255 and out.g == 255 and out.b == 255);
}

test "colorBrightness(c, -1) = black" {
    const c: Color = .{ .r = 100, .g = 50, .b = 200, .a = 255 };
    const out: Color = colorBrightness(c, -1);
    try expect(out.r == 0 and out.g == 0 and out.b == 0);
}

test "colorLerp(a, b, 0) = a; colorLerp(a, b, 1) = b" {
    const a: Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const b: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const at_zero: Color = colorLerp(a, b, 0);
    const at_one: Color = colorLerp(a, b, 1);
    try expect(at_zero.r == 0 and at_zero.g == 0 and at_zero.b == 0);
    try expect(at_one.r == 255 and at_one.g == 255 and at_one.b == 255);
}

test "colorLerp(black_c, white_c, 0.5) ≈ grey" {
    const black_c: Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const white_c: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const mid: Color = colorLerp(black_c, white_c, 0.5);
    // ~127 since lerp truncates the fractional byte.
    try expect(mid.r >= 126 and mid.r <= 128);
}

// ===========================================================================
// colorAlphaBlend
// ===========================================================================

test "colorAlphaBlend: opaque src replaces dst" {
    const dst: Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const src: Color = .{ .r = 255, .g = 100, .b = 50, .a = 255 };
    const white_c: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const out: Color = colorAlphaBlend(dst, src, white_c);
    try expect(out.r == 255 and out.g == 100 and out.b == 50);
}

test "colorAlphaBlend: zero-alpha src leaves dst unchanged" {
    const dst: Color = .{ .r = 100, .g = 100, .b = 100, .a = 255 };
    const src: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    const white_c: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const out: Color = colorAlphaBlend(dst, src, white_c);
    try expect(out.r == dst.r and out.g == dst.g and out.b == dst.b);
}

// ===========================================================================
// getPixelDataSize
// Pixel-format byte sizes pinned against raylib's reference implementation
// in `rtextures.c`'s `GetPixelDataSize`.  The HDR-format cases (R32, R16,
// R32G32B32, R16G16B16A16, …) caught a real bug during the aggressive
// ziggification sweep - the previous magic-number switch had bpp=8 for
// R32/R16 (should be 32 and 16) and bpp=32 for R32G32B32 (should be 96).
// Don't simplify these tests; they're regression coverage.
// ===========================================================================

inline fn pf(tag: PixelFormat) i32 {
    return @backingInt(tag);
}

test "getPixelDataSize: RGBA8 = 4 bytes/pixel" {
    try expect(getPixelDataSize(1, 1, pf(.uncompressed_r8g8b8a8)) == 4);
    try expect(getPixelDataSize(8, 8, pf(.uncompressed_r8g8b8a8)) == 256);
}

test "getPixelDataSize: zero dims returns 0" {
    try expect(getPixelDataSize(0, 8, pf(.uncompressed_r8g8b8a8)) == 0);
    try expect(getPixelDataSize(8, 0, pf(.uncompressed_r8g8b8a8)) == 0);
}

test "getPixelDataSize: 8-bit formats (GRAYSCALE) = 1 B/px" {
    try expect(getPixelDataSize(1, 1, pf(.uncompressed_grayscale)) == 1);
    try expect(getPixelDataSize(16, 16, pf(.uncompressed_grayscale)) == 256);
}

test "getPixelDataSize: 16-bit formats = 2 B/px (raylib parity)" {
    inline for (.{
        PixelFormat.uncompressed_gray_alpha,
        PixelFormat.uncompressed_r5g6b5,
        PixelFormat.uncompressed_r5g5b5a1,
        PixelFormat.uncompressed_r4g4b4a4,
        PixelFormat.uncompressed_r16,
    }) |fmt| {
        try expect(getPixelDataSize(1, 1, pf(fmt)) == 2);
        try expect(getPixelDataSize(8, 8, pf(fmt)) == 128);
    }
}

test "getPixelDataSize: R8G8B8 = 3 B/px" {
    try expect(getPixelDataSize(1, 1, pf(.uncompressed_r8g8b8)) == 3);
    try expect(getPixelDataSize(8, 8, pf(.uncompressed_r8g8b8)) == 192);
}

test "getPixelDataSize: HDR single-channel (R32) = 4 B/px (raylib parity)" {
    // Regression: previous zimr returned 1 here (bpp=8 in raylib's
    // R32 column was misread as 8 bpp instead of 32).
    try expect(getPixelDataSize(1, 1, pf(.uncompressed_r32)) == 4);
    try expect(getPixelDataSize(8, 8, pf(.uncompressed_r32)) == 256);
}

test "getPixelDataSize: HDR triple-channel = 12 B/px (R32G32B32) (raylib parity)" {
    // Regression: previous zimr returned 4 here (32 bpp instead of 96).
    try expect(getPixelDataSize(1, 1, pf(.uncompressed_r32g32b32)) == 12);
    try expect(getPixelDataSize(2, 2, pf(.uncompressed_r32g32b32)) == 48);
}

test "getPixelDataSize: HDR quad-channel = 16 B/px (R32G32B32A32)" {
    try expect(getPixelDataSize(1, 1, pf(.uncompressed_r32g32b32a32)) == 16);
    try expect(getPixelDataSize(4, 4, pf(.uncompressed_r32g32b32a32)) == 256);
}

test "getPixelDataSize: half-float triple-channel = 6 B/px (R16G16B16) (raylib parity)" {
    // Regression: previous zimr returned 2 here (16 bpp instead of 48).
    try expect(getPixelDataSize(1, 1, pf(.uncompressed_r16g16b16)) == 6);
    try expect(getPixelDataSize(4, 4, pf(.uncompressed_r16g16b16)) == 96);
}

test "getPixelDataSize: half-float quad-channel = 8 B/px (R16G16B16A16) (raylib parity)" {
    // Regression: previous zimr returned 4 here (32 bpp instead of 64).
    try expect(getPixelDataSize(1, 1, pf(.uncompressed_r16g16b16a16)) == 8);
    try expect(getPixelDataSize(4, 4, pf(.uncompressed_r16g16b16a16)) == 128);
}

test "getPixelDataSize: DXT1 compressed = 0.5 B/px on 4-aligned dims" {
    // 8x8 = 64 pixels × 4 bpp ÷ 8 = 32 bytes.
    try expect(getPixelDataSize(8, 8, pf(.compressed_dxt1_rgb)) == 32);
    try expect(getPixelDataSize(8, 8, pf(.compressed_dxt1_rgba)) == 32);
}

test "getPixelDataSize: DXT5 compressed = 1 B/px on 4-aligned dims" {
    try expect(getPixelDataSize(8, 8, pf(.compressed_dxt5_rgba)) == 64);
}

test "getPixelDataSize: ASTC 8x8 = 0.25 B/px (raylib parity)" {
    // 8×8 = 64 pixels × 2 bpp ÷ 8 = 16 bytes.
    try expect(getPixelDataSize(8, 8, pf(.compressed_astc_8x8_rgba)) == 16);
}

test "getPixelDataSize: compressed formats round non-aligned dims up to 4×4 blocks" {
    // 5×5 image at 4 bpp:
    //   raw:        5 × 5 × 4 / 8 = 12 (intermediate, gets overwritten)
    //   block-rounded: ((5/4)+1)*4 = 8, ((5/4)+1)*4 = 8 → 8 × 8 × 4 / 8 = 32
    try expect(getPixelDataSize(5, 5, pf(.compressed_dxt1_rgb)) == 32);
    // 7×3 image at 8 bpp: rounded to 8×4 → 8 × 4 × 8 / 8 = 32.
    try expect(getPixelDataSize(7, 3, pf(.compressed_dxt5_rgba)) == 32);
}

// ===========================================================================
// PixelFormat.isCompressed() - pins the off-by-one fix where a previous
// magic-number boundary marker had value 13 (which made R16G16B16A16,
// the 13th-and-uncompressed format, register as compressed and get
// silently rejected by `imageCrop` / `imageResizeCanvas`).
// ===========================================================================

test "PixelFormat.isCompressed: uncompressed formats return false" {
    try expect(!PixelFormat.uncompressed_grayscale.isCompressed());
    try expect(!PixelFormat.uncompressed_r8g8b8a8.isCompressed());
    try expect(!PixelFormat.uncompressed_r32g32b32a32.isCompressed());
    // The off-by-one regression check - this format is uncompressed
    // but had numeric value at the old boundary.
    try expect(!PixelFormat.uncompressed_r16g16b16a16.isCompressed());
}

test "PixelFormat.isCompressed: compressed formats return true" {
    try expect(PixelFormat.compressed_dxt1_rgb.isCompressed());
    try expect(PixelFormat.compressed_dxt5_rgba.isCompressed());
    try expect(PixelFormat.compressed_etc1_rgb.isCompressed());
    try expect(PixelFormat.compressed_pvrt_rgba.isCompressed());
    try expect(PixelFormat.compressed_astc_8x8_rgba.isCompressed());
}

// ===========================================================================
// Image validity
// ===========================================================================

test "isImageValid: zero data is invalid" {
    const img: Image = .{
        .data = null,
        .width = 0,
        .height = 0,
        .mipmaps = 0,
        .format = 0,
    };
    try expect(!isImageValid(img));
}

test "isTextureValid: id 0 is invalid" {
    const tex: Texture = .{ .id = 0, .width = 0, .height = 0, .mipmaps = 0, .format = 0 };
    try expect(!isTextureValid(tex));
}

// getImageColor + imageDraw - Roadmap Step 5
// Build small RGBA buffers on the stack so we can test without a wasm
// allocator on host.  4×2 source, 4×4 destination is plenty.
test "getImageColor: in-bounds RGBA8 read" {
    var pixels = [_]u8{
        // 2×2 image: (0,0)=red (1,0)=green (0,1)=blue (1,1)=white
        255, 0, 0,   255, 0,   255, 0,   255,
        0,   0, 255, 255, 255, 255, 255, 255,
    };
    const img: Image = .{
        .data = @ptrCast(&pixels),
        .width = 2,
        .height = 2,
        .mipmaps = 1,
        .format = 7,
    };
    try expect(getImageColor(img, 0, 0).r == 255);
    try expect(getImageColor(img, 1, 0).g == 255);
    try expect(getImageColor(img, 0, 1).b == 255);
    try expect(getImageColor(img, 1, 1).r == 255);
    try expect(getImageColor(img, 1, 1).a == 255);
}

test "getImageColor: out-of-bounds returns transparent" {
    var pixels = [_]u8{ 100, 100, 100, 255 };
    const img: Image = .{
        .data = @ptrCast(&pixels),
        .width = 1,
        .height = 1,
        .mipmaps = 1,
        .format = 7,
    };
    const out: Color = getImageColor(img, 5, 5);
    try expect(out.a == 0);
    const neg: Color = getImageColor(img, -1, 0);
    try expect(neg.a == 0);
}

test "getImageColor: grayscale read" {
    var pixels = [_]u8{ 0, 64, 128, 255 };
    const img: Image = .{
        .data = @ptrCast(&pixels),
        .width = 4,
        .height = 1,
        .mipmaps = 1,
        .format = 1, // PIXELFORMAT_UNCOMPRESSED_GRAYSCALE
    };
    const c0: Color = getImageColor(img, 0, 0);
    try expect(c0.r == 0 and c0.g == 0 and c0.b == 0 and c0.a == 255);
    const c2: Color = getImageColor(img, 2, 0);
    try expect(c2.r == 128 and c2.a == 255);
}

test "imageDraw: same-size copy paints source onto dest" {
    // 2×1 source: [red, green]
    var src_pixels = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 255 };
    const src: Image = .{
        .data = @ptrCast(&src_pixels),
        .width = 2,
        .height = 1,
        .mipmaps = 1,
        .format = 7,
    };
    // 2×1 dest, all blue
    var dst_pixels = [_]u8{ 0, 0, 255, 255, 0, 0, 255, 255 };
    var dst: Image = .{
        .data = @ptrCast(&dst_pixels),
        .width = 2,
        .height = 1,
        .mipmaps = 1,
        .format = 7,
    };
    const src_rec: Rectangle = .{ .x = 0, .y = 0, .width = 2, .height = 1 };
    const dst_rec: Rectangle = .{ .x = 0, .y = 0, .width = 2, .height = 1 };
    imageDraw(&dst, src, src_rec, dst_rec, .{ .r = 255, .g = 255, .b = 255, .a = 255 });
    // After full-alpha draw, dest should match source.
    try expect(getImageColor(dst, 0, 0).r == 255);
    try expect(getImageColor(dst, 1, 0).g == 255);
}

test "imageDraw: out-of-bounds dst rectangle clipped (no crash)" {
    var src_pixels = [_]u8{ 255, 0, 0, 255 };
    const src: Image = .{
        .data = @ptrCast(&src_pixels),
        .width = 1,
        .height = 1,
        .mipmaps = 1,
        .format = 7,
    };
    var dst_pixels = [_]u8{ 0, 0, 0, 255, 0, 0, 0, 255 };
    var dst: Image = .{
        .data = @ptrCast(&dst_pixels),
        .width = 2,
        .height = 1,
        .mipmaps = 1,
        .format = 7,
    };
    // dst rect entirely off-screen - should be a no-op
    imageDraw(
        &dst,
        src,
        .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .{ .x = 100, .y = 100, .width = 1, .height = 1 },
        .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    );
    try expect(getImageColor(dst, 0, 0).r == 0);
    try expect(getImageColor(dst, 1, 0).r == 0);
}

test "imageDraw: alpha blends translucent source" {
    // 1×1 50%-alpha red source
    var src_pixels = [_]u8{ 255, 0, 0, 128 };
    const src: Image = .{
        .data = @ptrCast(&src_pixels),
        .width = 1,
        .height = 1,
        .mipmaps = 1,
        .format = 7,
    };
    // dest: solid green
    var dst_pixels = [_]u8{ 0, 255, 0, 255 };
    var dst: Image = .{
        .data = @ptrCast(&dst_pixels),
        .width = 1,
        .height = 1,
        .mipmaps = 1,
        .format = 7,
    };
    imageDraw(
        &dst,
        src,
        .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    );
    const result: Color = getImageColor(dst, 0, 0);
    // Blend: ~50% red + ~50% green.  Don't assert exact values
    // (alphaBlend uses gamma-aware path); just check it's a mid mix.
    try expect(result.r > 100 and result.r < 200);
    try expect(result.g > 100 and result.g < 200);
}

// imageDrawTriangleGradient - Roadmap Step 6
test "imageDrawTriangleGradient: solid fill (all same color)" {
    // 4×4 dest, all transparent
    var pixels: [4 * 4 * 4]u8 = @splat(0);
    var dst: Image = .{
        .data = @ptrCast(&pixels),
        .width = 4,
        .height = 4,
        .mipmaps = 1,
        .format = 7,
    };
    const red: Color = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    // Big triangle covering most of the image.
    imageDrawTriangleGradient(
        &dst,
        .{ 0, 0 },
        .{ 3, 0 },
        .{ 0, 3 },
        red,
        red,
        red,
    );
    // Pixel near v1 should be red.
    const c0: Color = getImageColor(dst, 0, 0);
    try expect(c0.r == 255 and c0.g == 0);
}

test "imageDrawTriangleGradient: vertex-color blend" {
    var pixels: [8 * 8 * 4]u8 = @splat(0);
    var dst: Image = .{
        .data = @ptrCast(&pixels),
        .width = 8,
        .height = 8,
        .mipmaps = 1,
        .format = 7,
    };
    const red: Color = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    const green: Color = .{ .r = 0, .g = 255, .b = 0, .a = 255 };
    const blue: Color = .{ .r = 0, .g = 0, .b = 255, .a = 255 };
    imageDrawTriangleGradient(
        &dst,
        .{ 0, 0 },
        .{ 7, 0 },
        .{ 0, 7 },
        red,
        green,
        blue,
    );
    // Near v1 (top-left) → mostly red
    const near_v1: Color = getImageColor(dst, 0, 0);
    try expect(near_v1.r > near_v1.g and near_v1.r > near_v1.b);
    // Near v2 (top-right) → mostly green
    const near_v2: Color = getImageColor(dst, 6, 0);
    try expect(near_v2.g > near_v2.r);
    // Near v3 (bottom-left) → mostly blue
    const near_v3: Color = getImageColor(dst, 0, 6);
    try expect(near_v3.b > near_v3.r);
}

test "imageDrawTriangleGradient: degenerate triangle is no-op" {
    var pixels: [2 * 2 * 4]u8 = @splat(0xFF);
    var dst: Image = .{
        .data = @ptrCast(&pixels),
        .width = 2,
        .height = 2,
        .mipmaps = 1,
        .format = 7,
    };
    const c: Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    // Three colinear points.
    imageDrawTriangleGradient(
        &dst,
        .{ 0, 0 },
        .{ 1, 1 },
        .{ 2, 2 },
        c,
        c,
        c,
    );
    // Pixels should be unchanged.
    try expect(pixels[0] == 0xFF);
}

// imageDrawTriangle - bbox clamping (regression)
// Added in aggressive sweep.  zimr's previous implementation
// iterated the unclamped bounding box, relying on `imageDrawPixel` to
// drop out-of-bounds writes.  raylib's reference clamps the bbox first
// - both correct, but raylib's avoids ~maxx*maxy iterations for
// triangles that only partially overlap the image.  The fix matches
// raylib's behaviour and these tests pin it.
test "imageDrawTriangle: clamps bbox to image (regression)" {
    // 4x4 RGBA8 image.  A triangle with one vertex far off-screen
    // should still draw correctly to the on-screen part.
    var pixels: [4 * 4 * 4]u8 = @splat(0);
    var img: Image = .{
        .data = @ptrCast(&pixels),
        .width = 4,
        .height = 4,
        .mipmaps = 1,
        .format = 7,
    };
    const red: Color = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    // Triangle stretching from far above-and-left to the on-screen area.
    imageDrawTriangle(
        &img,
        .{ -1000, -1000 },
        .{ 100, -1000 },
        .{ 0, 100 },
        red,
    );
    // Some on-screen pixels should be red (the triangle's lower
    // half-plane covers the full image).
    var any_red: bool = false;
    for (0..16) |i| {
        if (pixels[i * 4 + 0] == 255) {
            any_red = true;
            break;
        }
    }
    try expect(any_red);
}

test "imageDrawTriangle: triangle entirely off-screen is no-op" {
    var pixels: [4 * 4 * 4]u8 = @splat(0);
    var img: Image = .{
        .data = @ptrCast(&pixels),
        .width = 4,
        .height = 4,
        .mipmaps = 1,
        .format = 7,
    };
    const red: Color = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    // All three vertices off-screen, on the same side.
    imageDrawTriangle(
        &img,
        .{ -100, -100 },
        .{ -50, -100 },
        .{ -75, -50 },
        red,
    );
    // Image must be unchanged (still all zeros).
    for (0..16) |i| {
        try expect(pixels[i * 4 + 0] == 0);
    }
}

// imageAlpha* - Roadmap Step 8
test "getImageAlphaBorder: detects opaque rect inside transparent margin" {
    // 4×4 RGBA8 with a 2×2 opaque block at (1,1)..(2,2)
    var pixels: [4 * 4 * 4]u8 = @splat(0);
    var dst: Image = .{
        .data = @ptrCast(&pixels),
        .width = 4,
        .height = 4,
        .mipmaps = 1,
        .format = 7,
    };
    const opaque_clr: Color = .{ .r = 200, .g = 100, .b = 50, .a = 255 };
    imageDrawPixel(&dst, 1, 1, opaque_clr);
    imageDrawPixel(&dst, 2, 1, opaque_clr);
    imageDrawPixel(&dst, 1, 2, opaque_clr);
    imageDrawPixel(&dst, 2, 2, opaque_clr);

    const r: Rectangle = getImageAlphaBorder(dst, 0.5);
    try expect(r.x == 1 and r.y == 1);
    try expect(r.width == 2 and r.height == 2);
}

test "getImageAlphaBorder: fully transparent image returns zero rect" {
    var pixels: [3 * 3 * 4]u8 = @splat(0);
    const dst: Image = .{
        .data = @ptrCast(&pixels),
        .width = 3,
        .height = 3,
        .mipmaps = 1,
        .format = 7,
    };
    const r: Rectangle = getImageAlphaBorder(dst, 0.5);
    try expect(r.width == 0 and r.height == 0);
}

test "getImageAlphaBorder: threshold tunes which pixels count" {
    // 2×2 RGBA8 - alpha values: 64, 128, 192, 255 (one per pixel)
    var pixels = [_]u8{
        100, 100, 100, 64,  100, 100, 100, 128,
        100, 100, 100, 192, 100, 100, 100, 255,
    };
    const dst: Image = .{
        .data = @ptrCast(&pixels),
        .width = 2,
        .height = 2,
        .mipmaps = 1,
        .format = 7,
    };
    // threshold=0.5 (cutoff=127): only pixels with a>127 count.  That's
    // pixel (1,0) [a=128 - but 128 > 127] and the bottom row.
    const r1: Rectangle = getImageAlphaBorder(dst, 0.5);
    try expect(r1.x == 0 or r1.x == 1);
    try expect(r1.height == 2 or r1.height == 1);

    // threshold=0.99 (cutoff=252): only the bottom-right pixel (a=255).
    const r2: Rectangle = getImageAlphaBorder(dst, 0.99);
    try expect(r2.x == 1 and r2.y == 1);
    try expect(r2.width == 1 and r2.height == 1);
}

test "imageAlphaMask: rejects mismatched formats" {
    var img_pixels = [_]u8{ 200, 200, 200, 255 };
    var img: Image = .{
        .data = @ptrCast(&img_pixels),
        .width = 1,
        .height = 1,
        .mipmaps = 1,
        .format = 7,
    };
    // Mask in RGBA8 (wrong format)
    var mask_pixels = [_]u8{ 100, 100, 100, 100 };
    const mask: Image = .{
        .data = @ptrCast(&mask_pixels),
        .width = 1,
        .height = 1,
        .mipmaps = 1,
        .format = 7,
    };
    imageAlphaMask(&img, mask);
    // Should be no-op; image alpha unchanged.
    try expect(img_pixels[3] == 255);
}

test "imageAlphaMask: GRAYSCALE mask replaces alpha channel" {
    // 2×1 RGBA8 image, both fully opaque
    var img_pixels = [_]u8{ 200, 200, 200, 255, 100, 100, 100, 255 };
    var img: Image = .{
        .data = @ptrCast(&img_pixels),
        .width = 2,
        .height = 1,
        .mipmaps = 1,
        .format = 7,
    };
    // 2×1 GRAYSCALE mask: 64, 192
    var mask_pixels = [_]u8{ 64, 192 };
    const mask: Image = .{
        .data = @ptrCast(&mask_pixels),
        .width = 2,
        .height = 1,
        .mipmaps = 1,
        .format = 1,
    };
    imageAlphaMask(&img, mask);
    try expect(img_pixels[3] == 64); // first pixel's new alpha
    try expect(img_pixels[7] == 192); // second pixel's new alpha
    // RGB unchanged
    try expect(img_pixels[0] == 200 and img_pixels[4] == 100);
}

test "imageAlphaCrop: zero-size dst is a no-op" {
    const ta: Allocator = std.testing.allocator;
    var img: Image = .{
        .data = null,
        .width = 0,
        .height = 0,
        .mipmaps = 0,
        .format = 0,
    };
    try imageAlphaCrop(ta, &img, 0.5);
    // No crash.
    try expect(img.data == null);
}

// imageBlurGaussian / imageKernelConvolution / imageDither - Phase E.2
// ziggified.  Tests below exercise the early-return paths only.  Real
// realloc paths could be added when there's a need for visual-
// correctness coverage; smoke tests already prove the work loops run.
test "imageBlurGaussian: null data is a no-op" {
    const ta: Allocator = std.testing.allocator;
    var img: Image = .{
        .data = null,
        .width = 0,
        .height = 0,
        .mipmaps = 0,
        .format = 0,
    };
    try imageBlurGaussian(ta, &img, 3);
}

test "imageBlurGaussian: zero or negative blur size is a no-op" {
    const ta: Allocator = std.testing.allocator;
    var pixels: [2 * 2 * 4]u8 = @splat(0xFF);
    var img: Image = .{
        .data = @ptrCast(&pixels),
        .width = 2,
        .height = 2,
        .mipmaps = 1,
        .format = 7,
    };
    try imageBlurGaussian(ta, &img, 0);
    try expect(pixels[0] == 0xFF); // unchanged
    try imageBlurGaussian(ta, &img, -1);
    try expect(pixels[0] == 0xFF);
}

test "imageBlurGaussian: wrong format is a no-op" {
    const ta: Allocator = std.testing.allocator;
    var pixels = [_]u8{ 100, 100, 100, 100 };
    var img: Image = .{
        .data = @ptrCast(&pixels),
        .width = 2,
        .height = 2,
        .mipmaps = 1,
        .format = 1, // GRAYSCALE
    };
    try imageBlurGaussian(ta, &img, 2);
    try expect(pixels[0] == 100); // unchanged
}

test "imageKernelConvolution: rejects even kernel sizes" {
    const ta: Allocator = std.testing.allocator;
    var pixels: [2 * 2 * 4]u8 = @splat(0);
    var img: Image = .{
        .data = @ptrCast(&pixels),
        .width = 2,
        .height = 2,
        .mipmaps = 1,
        .format = 7,
    };
    // 4 elements → sqrt = 2 → even → rejected.
    const kernel: [4]f32 = [_]f32{ 1.0, 1.0, 1.0, 1.0 };
    try imageKernelConvolution(ta, &img, &kernel);
    try expect(pixels[0] == 0); // unchanged
}

test "imageKernelConvolution: rejects non-square kernel" {
    const ta: Allocator = std.testing.allocator;
    var pixels: [16]u8 = .{ 1, 2, 3, 4, 1, 2, 3, 4, 1, 2, 3, 4, 1, 2, 3, 4 }; // 2x2 RGBA
    var img: Image = .{
        .data = @ptrCast(&pixels),
        .width = 2,
        .height = 2,
        .mipmaps = 1,
        .format = 7,
    };
    // 5 elements: sqrt(5) ≈ 2.24, intCast = 2, 2*2 = 4 ≠ 5 → rejected.
    const kernel: [5]f32 = [_]f32{ 0.2, 0.2, 0.2, 0.2, 0.2 };
    const original: u8 = pixels[0];
    try imageKernelConvolution(ta, &img, &kernel);
    try expect(pixels[0] == original); // unchanged
}

test "imageKernelConvolution: 3x3 identity preserves pixels" {
    const ta: Allocator = std.testing.allocator;
    // 3x3 RGBA image with a single coloured pixel in the middle.
    var pixels: [3 * 3 * 4]u8 = @splat(0);
    pixels[(1 * 3 + 1) * 4 + 0] = 100; // center R
    pixels[(1 * 3 + 1) * 4 + 3] = 255; // center A
    var img: Image = .{
        .data = @ptrCast(&pixels),
        .width = 3,
        .height = 3,
        .mipmaps = 1,
        .format = 7,
    };
    // Identity kernel.
    const kernel = [_]f32{
        0, 0, 0,
        0, 1, 0,
        0, 0, 0,
    };
    try imageKernelConvolution(ta, &img, &kernel);
    try expect(pixels[(1 * 3 + 1) * 4 + 0] == 100);
}

test "imageDither: requires bitDepths summing to 16" {
    const ta: Allocator = std.testing.allocator;
    var pixels: [1 * 1 * 4]u8 = @splat(0);
    var img: Image = .{
        .data = @ptrCast(&pixels),
        .width = 1,
        .height = 1,
        .mipmaps = 1,
        .format = 7,
    };
    // Sum != 16 → no-op
    try imageDither(ta, &img, 4, 4, 4, 4); // sum=16 ok
    try imageDither(ta, &img, 8, 8, 8, 8); // sum=32 → no-op
    try imageDither(ta, &img, 0, 0, 0, 0); // sum=0 → no-op
}

// imageColorTint / Invert / Grayscale / Brightness / Contrast / Replace
// - Roadmap Step 10
// All operate on RGBA8 in-place; safe to host-test with stack buffers.
test "imageColorTint: multiplicative tint" {
    // 1×1 white pixel
    var pixels = [_]u8{ 255, 255, 255, 255 };
    var img: Image = .{
        .data = @ptrCast(&pixels),
        .width = 1,
        .height = 1,
        .mipmaps = 1,
        .format = 7,
    };
    // Tint by half-red - result should be (128, 0, 0, 128) approximately.
    imageColorTint(&img, .{ .r = 128, .g = 0, .b = 0, .a = 128 });
    try expect(pixels[0] == 128);
    try expect(pixels[1] == 0);
    try expect(pixels[2] == 0);
    try expect(pixels[3] == 128);
}

test "imageColorInvert: RGB inverted, alpha preserved" {
    var pixels = [_]u8{ 100, 200, 50, 128 };
    var img: Image = .{
        .data = @ptrCast(&pixels),
        .width = 1,
        .height = 1,
        .mipmaps = 1,
        .format = 7,
    };
    imageColorInvert(&img);
    try expect(pixels[0] == 155); // 255 - 100
    try expect(pixels[1] == 55); // 255 - 200
    try expect(pixels[2] == 205); // 255 - 50
    try expect(pixels[3] == 128); // alpha unchanged
}

test "imageColorGrayscale: pure red maps to luma=76" {
    var pixels = [_]u8{ 255, 0, 0, 255 };
    var img: Image = .{
        .data = @ptrCast(&pixels),
        .width = 1,
        .height = 1,
        .mipmaps = 1,
        .format = 7,
    };
    imageColorGrayscale(&img);
    // Luma weights: 0.299*255 ≈ 76
    try expect(pixels[0] == 76);
    try expect(pixels[1] == 76);
    try expect(pixels[2] == 76);
    try expect(pixels[3] == 255);
}

test "imageColorBrightness: positive brightens, negative darkens" {
    var pixels = [_]u8{ 100, 100, 100, 255 };
    var img: Image = .{
        .data = @ptrCast(&pixels),
        .width = 1,
        .height = 1,
        .mipmaps = 1,
        .format = 7,
    };
    imageColorBrightness(&img, 50);
    try expect(pixels[0] == 150);

    // Then darken back
    imageColorBrightness(&img, -200);
    try expect(pixels[0] == 0); // clamped
}

test "imageColorBrightness: clamps to [0, 255]" {
    var pixels = [_]u8{ 250, 250, 250, 255 };
    var img: Image = .{
        .data = @ptrCast(&pixels),
        .width = 1,
        .height = 1,
        .mipmaps = 1,
        .format = 7,
    };
    imageColorBrightness(&img, 100);
    try expect(pixels[0] == 255); // clamped to 255
}

test "imageColorReplace: replaces matching color" {
    var pixels = [_]u8{
        255, 0, 0, 255, 0, 255, 0, 255, // 2 pixels: red, green
    };
    var img: Image = .{
        .data = @ptrCast(&pixels),
        .width = 2,
        .height = 1,
        .mipmaps = 1,
        .format = 7,
    };
    imageColorReplace(&img, .{ .r = 255, .g = 0, .b = 0, .a = 255 }, .{ .r = 0, .g = 0, .b = 255, .a = 255 });
    // First pixel: red → blue.  Second: untouched.
    try expect(pixels[0] == 0 and pixels[2] == 255);
    try expect(pixels[4] == 0 and pixels[5] == 255 and pixels[6] == 0);
}

test "imageColorContrast: positive value increases contrast" {
    // Mid-gray pixel at 128
    var pixels = [_]u8{ 128, 128, 128, 255 };
    var img: Image = .{
        .data = @ptrCast(&pixels),
        .width = 1,
        .height = 1,
        .mipmaps = 1,
        .format = 7,
    };
    // Apply +50 contrast - mid-gray should stay mid-ish
    imageColorContrast(&img, 50.0);
    // Tolerance: contrast pivot is 128, so mid-gray won't move much.
    try expect(pixels[0] >= 100 and pixels[0] <= 156);
}

// imageRotate (arbitrary angle) - Phase E.2 ziggified.  Realloc-path
// coverage for the 90° variants lives below; the arbitrary-angle path
// still has only no-op coverage at host.
test "imageRotate: null data is no-op" {
    const ta: Allocator = std.testing.allocator;
    var img: Image = .{
        .data = null,
        .width = 0,
        .height = 0,
        .mipmaps = 0,
        .format = 0,
    };
    try imageRotate(ta, &img, radFromDeg(45.0));
    try expect(img.data == null);
}

test "imageRotate: 0-degree rotation on null data" {
    const ta: Allocator = std.testing.allocator;
    var img: Image = .{
        .data = null,
        .width = 0,
        .height = 0,
        .mipmaps = 0,
        .format = 0,
    };
    try imageRotate(ta, &img, 0.0);
    try expect(img.data == null);
}

// imageResize / imageResizeNN - Phase E.1 ziggified
// These tests cover only the early-return paths (null data, same-size,
// invalid args) since the realloc path would free `image.data` and
// these stack-allocated test pixels can't be freed with gpa.
test "imageResize: null data is no-op" {
    const ta: Allocator = std.testing.allocator;
    var img: Image = .{
        .data = null,
        .width = 0,
        .height = 0,
        .mipmaps = 0,
        .format = 0,
    };
    try imageResize(ta, &img, 4, 4);
    try expect(img.data == null);
}

test "imageResize: same-size is no-op" {
    const ta: Allocator = std.testing.allocator;
    var pixels = [_]u8{ 100, 200, 50, 255 };
    var img: Image = .{
        .data = @ptrCast(&pixels),
        .width = 1,
        .height = 1,
        .mipmaps = 1,
        .format = 7,
    };
    try imageResize(ta, &img, 1, 1);
    try expect(img.width == 1 and img.height == 1);
    try expect(pixels[0] == 100); // unchanged
}

test "imageResize: invalid new size is no-op" {
    const ta: Allocator = std.testing.allocator;
    var pixels = [_]u8{ 100, 100, 100, 255 };
    var img: Image = .{
        .data = @ptrCast(&pixels),
        .width = 1,
        .height = 1,
        .mipmaps = 1,
        .format = 7,
    };
    try imageResize(ta, &img, 0, 4); // zero w
    try expect(img.width == 1);
    try imageResize(ta, &img, 4, -1); // negative h
    try expect(img.width == 1);
}

test "imageResizeNN: null data is no-op" {
    const ta: Allocator = std.testing.allocator;
    var img: Image = .{
        .data = null,
        .width = 0,
        .height = 0,
        .mipmaps = 0,
        .format = 0,
    };
    try imageResizeNN(ta, &img, 4, 4);
    try expect(img.data == null);
}

test "imageResizeNN: same-size is no-op" {
    const ta: Allocator = std.testing.allocator;
    var pixels = [_]u8{ 100, 200, 50, 255 };
    var img: Image = .{
        .data = @ptrCast(&pixels),
        .width = 1,
        .height = 1,
        .mipmaps = 1,
        .format = 7,
    };
    try imageResizeNN(ta, &img, 1, 1);
    try expect(pixels[0] == 100);
}

test "imageResize: real realloc path - 4x4 → 8x8 RGBA8" {
    const ta: Allocator = std.testing.allocator;
    // Build a 4x4 RGBA8 image via genImageColor so it's gpa-owned.
    var img: Image = try genImageColor(ta, 4, 4, .{ .r = 100, .g = 50, .b = 200, .a = 255 });
    defer unloadImage(ta, img);

    try imageResize(ta, &img, 8, 8);
    try expect(img.width == 8 and img.height == 8);
    try expect(img.data != null);
    // All pixels should still be the same fill color since source was uniform.
    const data: [*]const u8 = @ptrCast(img.data);
    try expect(data[0] == 100); // R
    try expect(data[1] == 50); // G
    try expect(data[2] == 200); // B
    try expect(data[3] == 255); // A
    // Last pixel of last row.
    try expect(data[(8 * 8 - 1) * 4] == 100);
}

test "imageResizeNN: real realloc path - 2x2 → 4x4 RGBA8" {
    const ta: Allocator = std.testing.allocator;
    var img: Image = try genImageColor(ta, 2, 2, .{ .r = 30, .g = 60, .b = 90, .a = 255 });
    defer unloadImage(ta, img);

    try imageResizeNN(ta, &img, 4, 4);
    try expect(img.width == 4 and img.height == 4);
    const data: [*]const u8 = @ptrCast(img.data);
    try expect(data[0] == 30);
    try expect(data[(4 * 4 - 1) * 4 + 2] == 90); // B of last pixel
}

test "imageResizeCanvas: real realloc path - pad 2x2 → 4x4 RGBA8" {
    const ta: Allocator = std.testing.allocator;
    var img: Image = try genImageColor(ta, 2, 2, .{ .r = 200, .g = 200, .b = 200, .a = 255 });
    defer unloadImage(ta, img);

    try imageResizeCanvas(ta, &img, 4, 4, 1, 1, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    try expect(img.width == 4 and img.height == 4);
    const data: [*]const u8 = @ptrCast(img.data);
    // Top-left should be the fill color (offset shifted source by (1,1)).
    try expect(data[0] == 0);
    // Pixel at (1,1) in the 4x4 = first row offset = 4*1 + 1, byte offset *4 = 20.
    try expect(data[(1 * 4 + 1) * 4] == 200);
}

test "imageCrop: real realloc path - crop 4x4 → 2x2 center" {
    const ta: Allocator = std.testing.allocator;
    var img: Image = try genImageColor(ta, 4, 4, .{ .r = 50, .g = 100, .b = 150, .a = 255 });
    defer unloadImage(ta, img);

    try imageCrop(ta, &img, .{ .x = 1, .y = 1, .width = 2, .height = 2 });
    try expect(img.width == 2 and img.height == 2);
    const data: [*]const u8 = @ptrCast(img.data);
    try expect(data[0] == 50); // unchanged fill
}

test "imageRotateCW: real realloc path - 4x2 → 2x4 RGBA8" {
    const ta: Allocator = std.testing.allocator;
    var img: Image = try genImageColor(ta, 4, 2, .{ .r = 70, .g = 80, .b = 90, .a = 255 });
    defer unloadImage(ta, img);

    try imageRotateCW(ta, &img);
    try expect(img.width == 2 and img.height == 4);
    const data: [*]const u8 = @ptrCast(img.data);
    try expect(data[0] == 70); // first pixel still the fill color
}

test "imageCopy: deep copy is independent of source" {
    const ta: Allocator = std.testing.allocator;
    const src: Image = try genImageColor(ta, 3, 3, .{ .r = 10, .g = 20, .b = 30, .a = 255 });
    defer unloadImage(ta, src);

    const dst: Image = try imageCopy(ta, src);
    defer unloadImage(ta, dst);
    try expect(dst.width == 3 and dst.height == 3);
    // Mutate source's first pixel; copy should be unchanged.
    const sp: [*]u8 = @ptrCast(src.data);
    sp[0] = 99;
    const dp: [*]const u8 = @ptrCast(dst.data);
    try expect(dp[0] == 10);
}

test "imageFromImage: extract sub-rect" {
    const ta: Allocator = std.testing.allocator;
    const src: Image = try genImageColor(ta, 4, 4, .{ .r = 200, .g = 100, .b = 50, .a = 255 });
    defer unloadImage(ta, src);

    const sub: Image = try imageFromImage(ta, src, .{ .x = 1, .y = 1, .width = 2, .height = 2 });
    defer unloadImage(ta, sub);
    try expect(sub.width == 2 and sub.height == 2);
    const sp: [*]const u8 = @ptrCast(sub.data);
    try expect(sp[0] == 200);
}

// ===========================================================================
// Error-path coverage for image generators (Cat 2a: sentinel-of-failure
// returns are now `error.InvalidDimensions`).
// Every generator that used to return `std.mem.zeroes(Image)` for bad
// input now returns `error.InvalidDimensions`.  These tests pin the new
// behaviour so a future "helpful" refactor that swaps the error back
// for a zeroes-sentinel fails loudly here.
// `Rng` is a vtable struct; the white-noise generator returns its
// dimension error before touching `rng`, so `undefined` is safe.
// ===========================================================================

test "genImageColor: width=0 returns error.InvalidDimensions" {
    const ta: Allocator = std.testing.allocator;
    const c: Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    try expectError(error.InvalidDimensions, genImageColor(ta, 0, 4, c));
}

test "genImageColor: height=0 returns error.InvalidDimensions" {
    const ta: Allocator = std.testing.allocator;
    const c: Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    try expectError(error.InvalidDimensions, genImageColor(ta, 4, 0, c));
}

test "genImageColor: negative width returns error.InvalidDimensions" {
    const ta: Allocator = std.testing.allocator;
    const c: Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    try expectError(error.InvalidDimensions, genImageColor(ta, -1, 4, c));
}

test "imageCopy: null data returns error.InvalidDimensions" {
    const ta: Allocator = std.testing.allocator;
    const empty: Image = .{
        .data = null,
        .width = 4,
        .height = 4,
        .mipmaps = 1,
        .format = 7,
    };
    try expectError(error.InvalidDimensions, imageCopy(ta, empty));
}

test "imageFromImage: null data returns error.InvalidDimensions" {
    const ta: Allocator = std.testing.allocator;
    const empty: Image = .{
        .data = null,
        .width = 4,
        .height = 4,
        .mipmaps = 1,
        .format = 7,
    };
    try expectError(
        error.InvalidDimensions,
        imageFromImage(ta, empty, .{ .x = 0, .y = 0, .width = 2, .height = 2 }),
    );
}

test "genImageGradientLinear: bad dims return error.InvalidDimensions" {
    const ta: Allocator = std.testing.allocator;
    const c1: Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const c2: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    try expectError(error.InvalidDimensions, genImageGradientLinear(ta, 0, 4, 0.0, c1, c2));
    try expectError(error.InvalidDimensions, genImageGradientLinear(ta, 4, -1, 0.0, c1, c2));
}

test "genImageGradientRadial: bad dims return error.InvalidDimensions" {
    const ta: Allocator = std.testing.allocator;
    const c1: Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const c2: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    try expectError(error.InvalidDimensions, genImageGradientRadial(ta, 0, 4, 0.5, c1, c2));
}

test "genImageGradientSquare: bad dims return error.InvalidDimensions" {
    const ta: Allocator = std.testing.allocator;
    const c1: Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const c2: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    try expectError(error.InvalidDimensions, genImageGradientSquare(ta, -2, 4, 0.5, c1, c2));
}

test "genImageChecked: zero checks_x returns error.InvalidDimensions" {
    const ta: Allocator = std.testing.allocator;
    const c1: Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const c2: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    // Width and height are fine, but checks_x = 0 trips the same error.
    try expectError(error.InvalidDimensions, genImageChecked(ta, 8, 8, 0, 2, c1, c2));
    try expectError(error.InvalidDimensions, genImageChecked(ta, 8, 8, 2, 0, c1, c2));
    try expectError(error.InvalidDimensions, genImageChecked(ta, 0, 8, 2, 2, c1, c2));
}

test "genImageWhiteNoise: bad dims return error.InvalidDimensions" {
    const ta: Allocator = std.testing.allocator;
    // Rng is never reached on the error path - the dimension check
    // returns before the function dereferences the vtable.
    const rng: Rng = undefined;
    try expectError(error.InvalidDimensions, genImageWhiteNoise(ta, rng, 0, 4, 0.5));
}

test "genImagePerlinNoise: bad dims return error.InvalidDimensions" {
    const ta: Allocator = std.testing.allocator;
    try expectError(error.InvalidDimensions, genImagePerlinNoise(ta, 0, 4, 0, 0, 1.0));
    try expectError(error.InvalidDimensions, genImagePerlinNoise(ta, 4, -3, 0, 0, 1.0));
}

test "genImageCellular: bad dims or tile_size return error.InvalidDimensions" {
    const ta: Allocator = std.testing.allocator;
    try expectError(error.InvalidDimensions, genImageCellular(ta, 0, 4, 8));
    // tile_size <= 0 also trips the same error - that branch exists
    // because zero tiles would divide by zero in the cell layout.
    try expectError(error.InvalidDimensions, genImageCellular(ta, 8, 8, 0));
}

test "genImageText: bad dims return error.InvalidDimensions" {
    const ta: Allocator = std.testing.allocator;
    try expectError(error.InvalidDimensions, genImageText(ta, 0, 4, "hi"));
    try expectError(error.InvalidDimensions, genImageText(ta, 4, -1, "hi"));
}

// exportImageToMemory + imageFromChannel + imageMipmaps - Phase-1B GAP fills.
test "exportImageToMemory: invalid image rejected" {
    const ta: Allocator = std.testing.allocator;
    var bad: Image = .{ .data = null, .width = 16, .height = 16, .mipmaps = 1, .format = 7 };
    try expectError(error.InvalidImage, exportImageToMemory(ta, bad, ".png"));
    bad = .{ .data = @ptrFromInt(8), .width = 0, .height = 16, .mipmaps = 1, .format = 7 };
    try expectError(error.InvalidImage, exportImageToMemory(ta, bad, ".png"));
}

test "exportImageToMemory: unsupported file type" {
    const ta: Allocator = std.testing.allocator;
    const c = Color{ .r = 1, .g = 2, .b = 3, .a = 4 };
    const img: Image = try genImageColor(ta, 4, 4, c);
    defer unloadImage(ta, img);
    try expectError(error.UnsupportedFileType, exportImageToMemory(ta, img, ".bmp"));
    try expectError(error.UnsupportedFileType, exportImageToMemory(ta, img, ".jpg"));
}

test "exportImageToMemory: PNG round-trips through codecs.png.decode" {
    const ta: Allocator = std.testing.allocator;
    const c = Color{ .r = 0xA0, .g = 0x10, .b = 0x80, .a = 0xC0 };
    const img: Image = try genImageColor(ta, 4, 4, c);
    defer unloadImage(ta, img);

    const png_bytes: []u8 = try exportImageToMemory(ta, img, ".png");
    defer ta.free(png_bytes);

    // Sanity: PNG signature.
    try expect(png_bytes.len >= 8);
    const sig: [8]u8 = .{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a };
    try expect(eql(u8, png_bytes[0..8], &sig));

    // Round-trip: decode the PNG and verify the pixels match.
    const codecs_mod = codecs;
    const decoded_img: codecs_mod.png.Image = try codecs_mod.png.decode(ta, png_bytes);
    defer decoded_img.deinit(ta);
    try expect(decoded_img.width == 4);
    try expect(decoded_img.height == 4);
    // Spot-check pixel (1, 1) - RGBA8 layout.
    const i: f32 = (1 * 4 + 1) * 4;
    try expect(decoded_img.pixels[i + 0] == c.r);
    try expect(decoded_img.pixels[i + 1] == c.g);
    try expect(decoded_img.pixels[i + 2] == c.b);
    try expect(decoded_img.pixels[i + 3] == c.a);
}

test "imageFromChannel: extracts R channel as grayscale" {
    const ta: Allocator = std.testing.allocator;
    const c = Color{ .r = 0x42, .g = 0x10, .b = 0x80, .a = 0xFF };
    const img: Image = try genImageColor(ta, 3, 2, c);
    defer unloadImage(ta, img);

    const r_only: Image = try imageFromChannel(ta, img, 0);
    defer unloadImage(ta, r_only);
    try expect(r_only.width == 3 and r_only.height == 2);
    try expect(r_only.format == @backingInt(PixelFormat.uncompressed_grayscale));

    // Each pixel is 1 byte; all should == 0x42.
    const buf: [*]const u8 = @ptrCast(@alignCast(r_only.data));
    for (0..6) |i| {
        try expect(buf[i] == 0x42);
    }
}

test "imageFromChannel: out-of-range channel returns 255" {
    const ta: Allocator = std.testing.allocator;
    const c = Color{ .r = 0x42, .g = 0x10, .b = 0x80, .a = 0xFF };
    const img: Image = try genImageColor(ta, 2, 2, c);
    defer unloadImage(ta, img);

    const ch5: Image = try imageFromChannel(ta, img, 5);
    defer unloadImage(ta, ch5);
    const buf: [*]const u8 = @ptrCast(@alignCast(ch5.data));
    for (0..4) |i| {
        try expect(buf[i] == 255);
    }
}

test "imageMipmaps: 4x4 RGBA generates 3 levels" {
    const ta: Allocator = std.testing.allocator;
    const c = Color{ .r = 0x80, .g = 0x80, .b = 0x80, .a = 0xFF };
    var img: Image = try genImageColor(ta, 4, 4, c);
    defer unloadImage(ta, img);

    try imageMipmaps(ta, &img);
    // Expected levels: 4×4 → 2×2 → 1×1 == 3 levels.
    try expect(img.mipmaps == 3);
    try expect(img.width == 4 and img.height == 4);

    // All-gray input → each downscale level is also all-gray.
    const buf: [*]const u8 = @ptrCast(@alignCast(img.data));
    // Level 0: 4*4*4 = 64 bytes
    // Level 1: 2*2*4 = 16 bytes (offset 64)
    // Level 2: 1*1*4 = 4 bytes (offset 80)
    try expect(buf[64] == 0x80); // level-1 first byte
    try expect(buf[80] == 0x80); // level-2 first byte
}

test "imageMipmaps: refuses non-RGBA8 formats" {
    const ta: Allocator = std.testing.allocator;
    const c = Color{ .r = 1, .g = 2, .b = 3, .a = 4 };
    var img: Image = try genImageColor(ta, 4, 4, c);
    defer unloadImage(ta, img);
    // genImageColor produces RGBA8; convert to grayscale to test refusal.
    try imageFormat(ta, &img, PixelFormat.uncompressed_grayscale);
    try expectError(error.UnsupportedPixelFormat, imageMipmaps(ta, &img));
}
