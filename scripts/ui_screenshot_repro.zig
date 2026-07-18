// scripts/ui_screenshot_repro.zig - host-only driver.
// Builds a tab-bar scene mirroring `examples/ui_tabbar_tour.zig`'s
// Bar 1 (closeable tabs + per-tab counters), then rasterizes the
// frame via `ui_screenshot` and writes the PNG to argv[1].
// Use: `zig run scripts/ui_screenshot_repro.zig --deps zimr <path.png>`
// Reproduces the turn-315 visual bug: tab content overlaps the
// tab strip because cursor advance happens at endTabBar instead
// of openTabBar.  Looking at the PNG should show the "Click me"
// button overlapping the "Alpha" tab.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const ui = z.ui;

const w: u32 = 480;
const h: u32 = 360;

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa: Allocator = gpa_state.allocator();

    var args: std.process.ArgIterator = try std.process.argsWithAllocator(gpa);
    defer args.deinit();
    _ = args.next(); // exe
    const out_path: []const u8 = args.next() orelse {
        std.debug.print("usage: ui_screenshot_repro <out.png>\n", .{});
        return error.MissingArg;
    };

    var ctx: ui.UiContext = .{
        .gpa = gpa,
        .frame_arena = std.heap.ArenaAllocator.init(gpa),
        .canvas_w = w,
        .canvas_h = h,
    };
    defer ctx.deinit();

    var gl_dummy: z.rlgl.GlState = .{};
    const shapes_dummy: z.drawing.shapes.ShapesTextureState = .{};
    const font_dummy: z.drawing.text.FontCache = .{};

    const u: ui.Ui = ctx.beginFrameRaw(.{}, null, w, h, &gl_dummy, &shapes_dummy, &font_dummy);
    if (u.window("TabBar tour", .{
        .initial_pos = .{ 8, 8 },
        .initial_size = .{ 460, 340 },
    })) |w| {
        defer w.close();
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
    }

    try z.ui_screenshot.renderToPng(gpa, &ctx, w, h, out_path);
    std.debug.print("wrote {s}\n", .{out_path});
}
