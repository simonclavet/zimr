// src/tests/ui_dock_screenshot_test.zig visual proof.
// Builds a dockspace with three pre-docked windows; renders to
// `/mnt/user-data/outputs/ui_dock_basic-turn319.png` for eyeball
// verification of the tab-bar rendering wiring.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("../ui.zig");
const shapes2d = @import("../shapes2d.zig");
const text2d = @import("../text2d.zig");

const width: u32 = 720;
const height: u32 = 480;

test "ui: dockspace with 3 docked windows -> PNG" {
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

    const h: ui.WindowHandle = u.window("Host", .{
        .initial_pos = .{ 8, 8 },
        .initial_size = .{ 704, 464 },
    }) orelse return;
    defer h.close();
    u.text("Step 5.5c - dockspace + tab bars", .{});
    u.separator();

    const root: ui.Id = u.dockSpace("MainDS", .{ 680, 400 }, .{});
    if (root != 0) {
        const split: ui.SplitResult = u.dockBuilderSplitNode(root, .left, 0.3);
        if (split.a != 0 and split.b != 0) {
            u.dockBuilderDockWindow("Tools", split.a);
            u.dockBuilderDockWindow("Viewport", split.b);
            u.dockBuilderDockWindow("Console", split.b);
            u.dockBuilderFinish(root);
        }
    }

    if (u.window("Tools", .{})) |hw| {
        defer hw.close();
        u.text("Tools panel", .{});
    }
    if (u.window("Viewport", .{})) |hw| {
        defer hw.close();
        u.text("Viewport (selected)", .{});
    }
    if (u.window("Console", .{})) |hw| {
        defer hw.close();
        u.text("Console (inactive tab)", .{});
    }

    var io_threaded: std.Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();
    const io: std.Io = io_threaded.io();
    ui.renderToPng(
        gpa,
        io,
        &ctx,
        width,
        height,
        "/mnt/user-data/outputs/ui_dock_basic-turn328.png",
    ) catch {}; // lint:off catch-suppression: best-effort screenshot artifact
}

//.iii: same scene but with a simulated drag in
// progress.  Fakes `ctx.dock.dragging_window = <some id>` + mouse
// position over the right leaf so the 5-zone overlay renders with
// the right-edge zone hovered (brighter).  Produces a PNG that
// captures the drop-target preview without needing a real input loop.

test "ui: dock drag overlay -> PNG" {
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

    // Mouse pos chosen to land firmly on the RIGHT zone of the
    // right leaf, with cursor near (but not at) zone center - so
    // we see a high-score right zone (bright fill + bright outline)
    // alongside its low-score neighbors (still faintly visible
    // thanks to BASE_ALPHA in the score-modulated renderer).
    // Demonstrates the smooth-pull rendering versus binary hit-test.
    var input: ui.InputSnapshot = .{};
    input.mouse_pos = .{ 495, 260 };

    const u: ui.Ui = ctx.beginFrameRaw(input, null, width, height, &gl_dummy, &shapes_dummy, &font_dummy);

    const h: ui.WindowHandle = u.window("Host", .{
        .initial_pos = .{ 8, 8 },
        .initial_size = .{ 704, 464 },
    }) orelse return;
    defer h.close();
    u.text("Step 5.5d.iii - dock drop-zone overlay", .{});
    u.separator();

    const root: ui.Id = u.dockSpace("MainDS", .{ 680, 400 }, .{});
    if (root != 0) {
        const split: ui.SplitResult = u.dockBuilderSplitNode(root, .left, 0.3);
        if (split.a != 0 and split.b != 0) {
            u.dockBuilderDockWindow("Tools", split.a);
            u.dockBuilderDockWindow("Viewport", split.b);
            u.dockBuilderDockWindow("Console", split.b);
            u.dockBuilderFinish(root);
        }
    }

    if (u.window("Tools", .{})) |hw| {
        defer hw.close();
        u.text("Tools panel", .{});
    }
    if (u.window("Viewport", .{})) |hw| {
        defer hw.close();
        u.text("Viewport", .{});
    }
    if (u.window("Console", .{})) |hw| {
        defer hw.close();
        u.text("Console", .{});
    }

    // Fake a drag-in-progress.  Use a non-zero id that doesn't
    // need to be a real window - the overlay code doesn't read
    // `dragging_window`'s id, only checks for non-null.
    ctx.dock.dragging_window = 0x1234;

    var io_threaded: std.Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();
    const io: std.Io = io_threaded.io();
    ui.renderToPng(
        gpa,
        io,
        &ctx,
        width,
        height,
        "/mnt/user-data/outputs/ui_dock_overlay-turn325.png",
    ) catch {}; // lint:off catch-suppression: best-effort screenshot artifact
}
