// src/errors_test.zig - host tests for the unified LoadError set
// and the synchronous embedded-data loaders introduced in Phase 12.3.
// `loadTextureFromMemory` can't be tested on host (needs GPU), but
// `loadImageFromMemory` is fully host-compilable since PNG decode is
// pure CPU.  We exercise both happy and failure paths.

const std = @import("std");
const Allocator = std.mem.Allocator;
const errors = @import("../errors.zig");
const png_mod = @import("../codecs.zig").png;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const allocator = std.testing.allocator;

// libc allocator stubs - png.zig itself doesn't use them, but the
// global `extern fn malloc/calloc/free` symbols still need to resolve
// for the test binary to link.  The Phase 12.0 strip cleared most of
// these; allocator.zig provides the wasm-side implementations.  On
// host the implementations short-circuit to null/no-op.

// LoadError set composition
test "LoadError contains every png.Error" {
    // Every error from png_mod.Error should be assignable into LoadError.
    const e: errors.LoadError = errors.PngError.InvalidSignature;
    try expect(e == errors.LoadError.InvalidSignature);

    const e2: errors.LoadError = errors.PngError.UnsupportedColorType;
    try expect(e2 == errors.LoadError.UnsupportedColorType);
}

test "LoadError contains the GPU + alloc errors" {
    const e: errors.LoadError = errors.LoadError.GpuUploadFailed;
    try expect(e == errors.LoadError.GpuUploadFailed);
    const e2: errors.LoadError = errors.LoadError.OutOfMemory;
    try expect(e2 == errors.LoadError.OutOfMemory);
}

// loadImageFromMemory - happy path + error paths
//
// We can't import zimr.zig from a test file (it pulls in webgl externs),
// so we replicate the function logic directly here.  The contract is
// "decode PNG → wrap in Image", which is one png.decode call wide.

const Image = @import("../types.zig").Image;

fn loadImageFromMemory(gpa: Allocator, bytes: []const u8) errors.LoadError!Image {
    const decoded: png_mod.Image = try png_mod.decode(gpa, bytes);
    return Image{
        .data = decoded.pixels.ptr,
        .width = @intCast(decoded.width),
        .height = @intCast(decoded.height),
        .mipmaps = 1,
        .format = 7,
    };
}

// 4×4 RGBA PNG, copied from png_test.zig.
const png_4x4_rgba = [_]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x08, 0x06, 0x00, 0x00, 0x00, 0xa9, 0xf1, 0x9e,
    0x7e, 0x00, 0x00, 0x00, 0x17, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xf8, 0xcf, 0xc0, 0xf0,
    0x1f, 0x84, 0x91, 0x20, 0x9a, 0x00, 0x94, 0x0f, 0x07, 0x18, 0x02, 0x00, 0x97, 0xe4, 0x27, 0xd9,
    0xe0, 0x08, 0x96, 0xdd, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
};

test "loadImageFromMemory: valid PNG decodes to Image with correct dimensions" {
    const img: Image = try loadImageFromMemory(allocator, &png_4x4_rgba);
    defer allocator.free(
        @as([*]u8, @ptrCast(img.data.?))[0 .. @as(usize, @intCast(img.width)) * @as(usize, @intCast(img.height)) * 4],
    );

    try expectEqual(@as(c_int, 4), img.width);
    try expectEqual(@as(c_int, 4), img.height);
    try expectEqual(@as(c_int, 1), img.mipmaps);
    // PIXELFORMAT_UNCOMPRESSED_R8G8B8A8 = 7 in raylib's enum.
    try expectEqual(@as(c_int, 7), img.format);
    try expect(img.data != null);
}

test "loadImageFromMemory: bad signature surfaces InvalidSignature" {
    const garbage = [_]u8{ 0xde, 0xad, 0xbe, 0xef, 0xde, 0xad, 0xbe, 0xef, 0x00 };
    try expectError(errors.LoadError.InvalidSignature, loadImageFromMemory(allocator, &garbage));
}

test "loadImageFromMemory: truncated PNG surfaces a parse error" {
    // 16-byte truncation gets through the chunk header but the IHDR
    // chunk's length field claims more data than is present, so the
    // decoder bails with InvalidIHDR.  (UnexpectedEnd would surface for
    // truncations mid-chunk-header - see the empty-input test.)
    const truncated: *const [16]u8 = png_4x4_rgba[0..16];
    try expectError(errors.LoadError.InvalidIHDR, loadImageFromMemory(allocator, truncated));
}

test "loadImageFromMemory: empty input surfaces UnexpectedEnd" {
    const empty = [_]u8{};
    try expectError(errors.LoadError.UnexpectedEnd, loadImageFromMemory(allocator, &empty));
}

// `try` composition - confirm error union sugar works as expected
fn doubleLoad(gpa: Allocator, bytes: []const u8) errors.LoadError!c_int {
    const img: Image = try loadImageFromMemory(gpa, bytes);
    defer gpa.free(
        @as([*]u8, @ptrCast(img.data.?))[0 .. @as(usize, @intCast(img.width)) * @as(usize, @intCast(img.height)) * 4],
    );
    return img.width * 2;
}

test "LoadError composes cleanly with try" {
    try expectEqual(@as(c_int, 8), try doubleLoad(allocator, &png_4x4_rgba));

    // Error path propagates through `try` correctly.
    try expectError(errors.LoadError.InvalidSignature, doubleLoad(allocator, "not a png"));
}
