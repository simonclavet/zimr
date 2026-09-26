// examples/ui_data_grid_phone.zig
//
// Touch-friendly H+V scrolling dashboard.  A grid of cells laid
// out wider than the phone viewport so the user has to pan both
// axes to see everything.
//
// What this exercises:
//   - `WindowFlags.horizontal_scrollbar` for X overflow
//   - Vertical scroll on Y overflow (default behavior)
//   - Window re-sized every frame to match screen dimensions, so
//     device rotation or browser-chrome resize moves the X bar
//     into view instead of stranding it off-screen
//   - Pos/neg coloring on the "change" column so the eye can
//     track context across long pans
//
// Build:
//   zig build install -Dfocus=ui_data_grid_phone

const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const ui = z.ui_real;

const Color = zm.Color;

const Bg: Color = .{ .r = 15, .g = 23, .b = 42, .a = 255 };
const White: Color = .{ .r = 241, .g = 245, .b = 249, .a = 255 };
const Dim: Color = .{ .r = 148, .g = 163, .b = 184, .a = 255 };
const Pos: Color = .{ .r = 34, .g = 197, .b = 94, .a = 255 };
const Neg: Color = .{ .r = 239, .g = 68, .b = 68, .a = 255 };

const col_w: f32 = 120;
const n_cols: usize = 8;
const n_rows: usize = 500;

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, @embedFile("atkinson_mono_ttf"), 22);
    s.* = .{ .ui_host = z.UiHost.init(gpa, font), .font = font };
}

/// Deterministic-but-varied "stock" data so the grid looks
/// real without bundling a dataset.  Each row's prng is seeded
/// from its index, so the same row always shows the same data
/// across frames.
fn formatCell(
    row: usize,
    col: usize,
    buf: []u8,
) []const u8 {
    var prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(@as(u64, @intCast(row * 37 + 11)));
    const r: std.Random = prng.random();
    return switch (col) {
        0 => blk: {
            const a: u8 = 'A' + @as(u8, @intCast(row % 26));
            const b: u8 = 'A' + @as(u8, @intCast((row * 7) % 26));
            const c: u8 = 'A' + @as(u8, @intCast((row * 13) % 26));
            break :blk bufPrint(buf, "{c}{c}{c}", .{ a, b, c }) catch "???";
        },
        1 => bufPrint(buf, "${d:.2}", .{r.float(f32) * 500 + 10}) catch "?",
        2 => blk: {
            const v: f32 = (r.float(f32) - 0.5) * 10;
            const sign: u8 = if (v < 0) '-' else '+';
            break :blk bufPrint(buf, "{c}{d:.2}%", .{ sign, @abs(v) }) catch "?";
        },
        3 => bufPrint(buf, "{d}M", .{r.intRangeAtMost(u32, 1, 999)}) catch "?",
        4 => bufPrint(buf, "${d}B", .{r.intRangeAtMost(u32, 1, 500)}) catch "?",
        5 => bufPrint(buf, "{d:.1}", .{r.float(f32) * 50 + 5}) catch "?",
        6 => bufPrint(buf, "${d:.2}", .{r.float(f32) * 600 + 100}) catch "?",
        7 => bufPrint(buf, "${d:.2}", .{r.float(f32) * 100 + 5}) catch "?",
        else => "?",
    };
}

/// Pos/neg coloring for the "change" column.
fn cellColor(col: usize, txt: []const u8) Color {
    if (col != 2 or txt.len == 0) {
        return White;
    }
    return if (txt[0] == '-') Neg else Pos;
}

fn update(f: *z.Frame, s: *State) void {
    z.clearViewport(f, Bg);

    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    const screen_w: f32 = float(f.window.screen_width);
    const screen_h: f32 = float(f.window.screen_height);

    // Header strip at the top tells the user which columns are
    // which.  Drawn directly via the GL text path so it's not
    // part of the scrolling window's content area; stays put
    // when the user pans.
    f.gl.text(
        .{ 12, 8 },
        "ticker  price  change  vol  cap  p/e  hi  lo",
        .{ .size = 14, .color = Dim, .font = &s.font },
    );
    f.gl.text(
        .{ 12, 28 },
        "swipe both axes (use the H scrollbar at the bottom)",
        .{ .size = 12, .color = Dim, .font = &s.font },
    );

    // Re-position + re-size the grid window every frame so a
    // rotation or browser-chrome resize keeps it on screen.
    // setNextWindow* with default opts (`once = false`) fires
    // every frame.  The window's full rect is visible, so the
    // horizontal scrollbar at the bottom edge always lands in
    // the viewport.
    // Reserve room top + bottom.  Top strip holds the column-label
    // header.  Bottom inset keeps the window's lower edge - where
    // the horizontal scrollbar gets rendered at `w.pos[1] +
    // w.size[1] - 12` - clear of the home indicator / browser
    // gesture bar so the user can actually see and tap it.
    const top_strip: f32 = 50;
    const bottom_inset: f32 = 24;
    u.setNextWindowPos(.{ 0, top_strip }, .{});
    u.setNextWindowSize(.{
        screen_w,
        @max(120, screen_h - top_strip - bottom_inset),
    }, .{});

    if (u.window("grid", .{
        .flags = .{
            .horizontal_scrollbar = true,
            .no_title_bar = true,
            .no_resize = true,
            .no_move = true,
        },
    })) |w| {
        defer w.close();

        // Data rows.  No separate header row inside the window -
        // the column headings are drawn above (outside the
        // scrolling area) so they stay visible while the user
        // pans.
        // Row clipper (ImGuiListClipper): only the rows intersecting the
        // scroll viewport are iterated + submitted, so a 500-row (or 100k-row)
        // grid costs the same as the ~20 visible rows - CPU loop + draw-list
        // both shrink to the visible window. Fixed row height = one text line.
        const style: ui.Style = s.ui_host.ctx.style;
        const item_height: f32 = style.font_size + style.item_spacing[1];
        var clip: ui.Clipper = u.clipper(n_rows, item_height);
        while (clip.step()) |range| {
            var row: usize = range.start;
            while (row < range.end) : (row += 1) {
                var col: usize = 0;
                while (col < n_cols) : (col += 1) {
                    if (col > 0) {
                        u.sameLine(.{ .offset_x = float(col) * col_w });
                    }
                    var buf: [32]u8 = undefined;
                    const txt: []const u8 = formatCell(row, col, &buf);
                    u.textColored(cellColor(col, txt), "{s}", .{txt});
                }
            }
        }
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - data grid phone",
            .width = 400,
            .height = 800,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
