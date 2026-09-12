// src/tests/ui_screenshot_test.zig - host-side debug screenshot.
// build a tab-bar scene that mirrors
// `examples/ui_tabbar_tour.zig` Bar 1, then write a PNG via
// `ui.renderToPng`.  The PNG goes to
// `/mnt/user-data/outputs/ui_tabbar_bug-turn317.png` so it can be
// previewed in the chat artifact viewer.
// This is a layout-bug visualizer, not a pass/fail regression
// (yet).  The eyeball check is: does "Click me" overlap "Alpha"?
// If yes, the turn-315 cursor-advance bug still exists.  If no,
// the fix landed.  Real assertion tests come later - start with
// the visual loop.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("../ui.zig");
const shapes2d = @import("../shapes2d.zig");
const text2d = @import("../text2d.zig");

const width: u32 = 480;
const height: u32 = 360;

test "ui: tab-bar scene → PNG for visual debug" {
    // Always attempt to write - host test runners with /mnt available
    // produce the screenshot; environments without it skip via the
    // catch on renderToPng below.

    const gpa: Allocator = std.testing.allocator;
    var ctx: ui.UiContext = .{
        .gpa = gpa,
        // ★ `ui.UiContext` moved from a bare arena to `FrameArena` (an arena plus a
        // live-byte tripwire that catches a dropped per-frame reset). These four test
        // files were imported by nothing, so they never compiled against the change.
        .frame_arena = ui.FrameArena.init(gpa, ui.ui_frame_arena_ceiling, "ui"),
        .canvas_w = width,
        .canvas_h = height,
    };
    defer ctx.deinit();

    var gl_dummy: ui.Gl = .{};
    const shapes_dummy: shapes2d.ShapesTextureState = .{};
    const font_dummy: text2d.FontCache = .{};

    const u: ui.Ui = ctx.beginFrameRaw(.{}, null, width, height, &gl_dummy, &shapes_dummy, &font_dummy);
    const h: ui.WindowHandle = u.window("TabBar tour", .{
        .initial_pos = .{ 8, 8 },
        .initial_size = .{ 460, 340 },
    }) orelse return;
    defer h.close();

    if (u.beginTabBar("bar1", .{})) {
        defer u.endTabBar();
        var a_open: bool = true;
        var b_open: bool = true;
        var c_open: bool = true;
        if (u.beginTabItem("Alpha", &a_open, .{})) {
            defer u.endTabItem();
            _ = u.button("Click me", .{});
            u.text("alpha tab content here", .{});
        }
        if (u.beginTabItem("Beta", &b_open, .{})) {
            defer u.endTabItem();
            _ = u.button("Click me", .{});
        }
        if (u.beginTabItem("Gamma", &c_open, .{})) {
            defer u.endTabItem();
            _ = u.button("Click me", .{});
        }
    }

    // Silently skip if the output path isn't writable (Windows host,
    // no /mnt, etc.).  PNG is for visual inspection in the Linux
    // sandbox; on other hosts the rest of the test still exercises
    // the codepath.
    var io_threaded: std.Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();
    const io: std.Io = io_threaded.io();
    ui.renderToPng(
        gpa,
        io,
        &ctx,
        width,
        height,
        "/mnt/user-data/outputs/ui_tabbar_bug-turn317.png",
    ) catch {}; // lint:off catch-suppression: best-effort screenshot artifact
}
