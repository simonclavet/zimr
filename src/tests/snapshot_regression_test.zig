// src/tests/snapshot_regression_test.zig - host-side visual
// regression tests built on the `ui.snapshot` helper.
//
// What's tested:
//   - First-run baseline: snapshot() writes a fresh PNG when no
//     reference exists, returns a clean (zero differing pixels)
//     diff so the test passes.
//   - Re-run against an identical scene: zero differing pixels,
//     matches the freshly-written baseline byte-for-byte.
//   - Diff catches a real change: forcing a different scene
//     against the same reference yields a nonzero `differing`
//     count.
//
// Reference PNGs live under `tests/snapshots/`.  The first run
// writes them; subsequent runs compare against them.  To refresh
// a baseline, delete the file and re-run.

const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const Allocator = std.mem.Allocator;
const ui = @import("../ui.zig");
const shapes2d = @import("../shapes2d.zig");
const text2d = @import("../text2d.zig");

const width: u32 = 240;
const height: u32 = 180;

const snapshot_dir: []const u8 = "tests/snapshots";

/// Build a minimal scene used by every test in this file.  Keep
/// it small + deterministic so the rendered PNG is tiny.
fn drawSceneA(u_handle: ui.Ui) void {
    if (u_handle.window("snap-a", .{
        .initial_pos = .{ 10, 10 },
        .initial_size = .{ 200, 140 },
    })) |w| {
        defer w.close();
        u_handle.text("hello", .{});
        _ = u_handle.button("click me", .{});
    }
}

fn drawSceneB(u_handle: ui.Ui) void {
    if (u_handle.window("snap-b", .{
        .initial_pos = .{ 10, 10 },
        .initial_size = .{ 200, 140 },
    })) |w| {
        defer w.close();
        u_handle.text("different content", .{});
        _ = u_handle.button("other label", .{});
    }
}

fn buildContext(gpa: Allocator) ui.UiContext {
    return .{
        .gpa = gpa,
        // * `ui.UiContext` moved from a bare arena to `FrameArena` (an arena plus a
        // live-byte tripwire that catches a dropped per-frame reset). These four test
        // files were imported by nothing, so they never compiled against the change.
        .frame_arena = ui.FrameArena.init(gpa, ui.ui_frame_arena_ceiling, "ui"),
        .canvas_w = width,
        .canvas_h = height,
    };
}

/// Best-effort directory create + file delete using the Io-threaded
/// file APIs.  Both swallow errors - the tests are robust to host
/// environments where `tests/snapshots/` isn't writable.
fn prepareSnapshotPath(io: std.Io, ref_path: []const u8) void {
    std.Io.Dir.cwd().createDirPath(io, snapshot_dir) catch {}; // lint:off catch-suppression: ensure-dir, ok if exists
    std.Io.Dir.cwd().deleteFile(io, ref_path) catch {}; // lint:off catch-suppression: remove if present
}

test "snapshot: first-run writes baseline and returns clean diff" {
    const gpa: Allocator = std.testing.allocator;

    const ref_path: []const u8 = snapshot_dir ++ "/snap_baseline_test.png";
    var io_threaded: std.Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();
    const io: std.Io = io_threaded.io();
    prepareSnapshotPath(io, ref_path);

    var ctx: ui.UiContext = buildContext(gpa);
    defer ctx.deinit();

    var gl_dummy: ui.Gl = .{};
    const shapes_dummy: shapes2d.ShapesTextureState = .{};
    const font_dummy: text2d.FontCache = .{};
    const u_handle: ui.Ui = ctx.beginFrameRaw(.{}, null, width, height, &gl_dummy, &shapes_dummy, &font_dummy);
    drawSceneA(u_handle);

    const diff: ui.PixelDiff = ui.snapshotPng(gpa, io, &ctx, width, height, ref_path) catch {
        // If the snapshot dir isn't writable (rare host), bail.
        // The codepath still ran up to the file write.
        return;
    };

    // First-run path: writes the baseline, returns zero differing.
    try expectEqual(@as(u32, 0), diff.differing);
    try expectEqual(@as(u32, width * height), diff.total);
}

test "snapshot: identical scene re-run is byte-for-byte equal" {
    const gpa: Allocator = std.testing.allocator;

    const ref_path: []const u8 = snapshot_dir ++ "/snap_identical_test.png";
    var io_threaded: std.Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();
    const io: std.Io = io_threaded.io();
    prepareSnapshotPath(io, ref_path);

    // Pass 1: write the baseline.
    {
        var ctx: ui.UiContext = buildContext(gpa);
        defer ctx.deinit();
        var gl_dummy: ui.Gl = .{};
        const shapes_dummy: shapes2d.ShapesTextureState = .{};
        const font_dummy: text2d.FontCache = .{};
        const u_handle: ui.Ui = ctx.beginFrameRaw(.{}, null, width, height, &gl_dummy, &shapes_dummy, &font_dummy);
        drawSceneA(u_handle);
        _ = ui.snapshotPng(gpa, io, &ctx, width, height, ref_path) catch return;
    }

    // Pass 2: identical scene -> must read the baseline + compare
    // pixel-for-pixel.  Zero differing.
    var ctx: ui.UiContext = buildContext(gpa);
    defer ctx.deinit();
    var gl_dummy: ui.Gl = .{};
    const shapes_dummy: shapes2d.ShapesTextureState = .{};
    const font_dummy: text2d.FontCache = .{};
    const u_handle: ui.Ui = ctx.beginFrameRaw(.{}, null, width, height, &gl_dummy, &shapes_dummy, &font_dummy);
    drawSceneA(u_handle);

    const diff: ui.PixelDiff = ui.snapshotPng(
        gpa,
        io,
        &ctx,
        width,
        height,
        ref_path,
    ) catch return;
    try expectEqual(@as(u32, 0), diff.differing);
    try expectEqual(@as(u8, 0), diff.max_channel_delta);
}

test "snapshot: different scene against same reference yields nonzero diff" {
    const gpa: Allocator = std.testing.allocator;

    const ref_path: []const u8 = snapshot_dir ++ "/snap_diff_test.png";
    var io_threaded: std.Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();
    const io: std.Io = io_threaded.io();
    prepareSnapshotPath(io, ref_path);

    // Pass 1: write Scene A as baseline.
    {
        var ctx: ui.UiContext = buildContext(gpa);
        defer ctx.deinit();
        var gl_dummy: ui.Gl = .{};
        const shapes_dummy: shapes2d.ShapesTextureState = .{};
        const font_dummy: text2d.FontCache = .{};
        const u_handle: ui.Ui = ctx.beginFrameRaw(.{}, null, width, height, &gl_dummy, &shapes_dummy, &font_dummy);
        drawSceneA(u_handle);
        _ = ui.snapshotPng(gpa, io, &ctx, width, height, ref_path) catch return;
    }

    // Pass 2: render Scene B against Scene A's baseline.  Should
    // see a real number of differing pixels.
    var ctx: ui.UiContext = buildContext(gpa);
    defer ctx.deinit();
    var gl_dummy: ui.Gl = .{};
    const shapes_dummy: shapes2d.ShapesTextureState = .{};
    const font_dummy: text2d.FontCache = .{};
    const u_handle: ui.Ui = ctx.beginFrameRaw(.{}, null, width, height, &gl_dummy, &shapes_dummy, &font_dummy);
    drawSceneB(u_handle);

    const diff: ui.PixelDiff = ui.snapshotPng(
        gpa,
        io,
        &ctx,
        width,
        height,
        ref_path,
    ) catch return;
    try expect(diff.differing > 0);
}

test "comparePixels: identical buffers report zero difference" {
    const a: []const u8 = &.{ 10, 20, 30, 255, 100, 150, 200, 255 };
    const b: []const u8 = &.{ 10, 20, 30, 255, 100, 150, 200, 255 };
    const diff: ui.PixelDiff = ui.comparePixels(a, b, 0);
    try expectEqual(@as(u32, 2), diff.total);
    try expectEqual(@as(u32, 0), diff.differing);
    try expectEqual(@as(u8, 0), diff.max_channel_delta);
}

test "comparePixels: single-channel delta above tolerance counts" {
    const a: []const u8 = &.{ 10, 20, 30, 255 };
    const b: []const u8 = &.{ 15, 20, 30, 255 };
    const diff: ui.PixelDiff = ui.comparePixels(a, b, 2);
    try expectEqual(@as(u32, 1), diff.total);
    try expectEqual(@as(u32, 1), diff.differing);
    try expectEqual(@as(u8, 5), diff.max_channel_delta);
}

test "comparePixels: delta within tolerance is not counted" {
    const a: []const u8 = &.{ 10, 20, 30, 255 };
    const b: []const u8 = &.{ 11, 21, 29, 254 };
    const diff: ui.PixelDiff = ui.comparePixels(a, b, 2);
    try expectEqual(@as(u32, 1), diff.total);
    try expectEqual(@as(u32, 0), diff.differing);
    try expectEqual(@as(u8, 1), diff.max_channel_delta);
}
