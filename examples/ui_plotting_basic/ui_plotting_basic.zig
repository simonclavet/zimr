// examples/ui_plotting_basic.zig - Phase 0c sparkline plots +
// block-tooltip showcase.
// Mirrors imgui's "Widgets/Plots Widgets" + a tease of the
// "Tooltips" section.  Three sparklines side-by-side:
// - A live FPS history (60-frame rolling buffer).
// - A sine wave (deterministic; good for visual regression).
// - A histogram of bin counts (sliders alter the data live).
// Hovering any plot shows the value at the cursor's sample index
// (via the built-in plot tooltip).  A separate "rich tooltip"
// demo shows beginTooltip / endTooltip submitting arbitrary
// widgets in a popover.

const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Vec2 = zm.Vec2;
const float = zm.float;
const pi = zm.pi;
const ui = z.ui_real;
const roboto_mono_ttf = @embedFile("roboto_mono_ttf");

const screen_w: i32 = 900;
const screen_h: i32 = 720;

const hist_len: usize = 60;

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,

    // FPS history - overwritten one sample per frame in update().
    fps_hist: [hist_len]f32 = @splat(60.0),
    fps_idx: usize = 0,

    // Sine wave - deterministic, parameterized.
    sine_freq: f32 = 2.0,
    sine_phase: f32 = 0.0,

    // Histogram bins - user can tweak each bin's height with sliders.
    bins: [12]f32 = .{ 4, 8, 12, 18, 22, 28, 25, 19, 13, 9, 6, 3 },

    // Plot-vs-bar toggle for the bins data.
    bins_as_lines: bool = false,

    // Tooltip block demo state.
    show_tooltip_demo_color: [3]f32 = .{ 0.8, 0.4, 0.2 },
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, roboto_mono_ttf, 28);
    s.* = .{ .ui_host = z.UiHost.init(gpa, font), .font = font };
}

fn update(f: *z.Frame, s: *State) void {
    z.clearViewport(f, .{ .r = 16, .g = 18, .b = 26, .a = 255 });

    // Sample current FPS into the rolling buffer.  FPS-smoothing is
    // a user concern per the runtime contract - compute as
    // `1 / dt` and let the plot's row-by-row history smooth it.
    const dt: f32 = f.time.delta_time;
    const fps_inst: f32 = if (dt > 0) 1.0 / dt else 60.0;
    s.fps_hist[s.fps_idx] = fps_inst;
    s.fps_idx = (s.fps_idx + 1) % hist_len;
    s.sine_phase += dt * 0.5;

    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    if (u.window("Plotting basics", .{
        .initial_pos = .{ 20, 20 },
        .initial_size = .{ 860, 680 },
    })) |w| {
        defer w.close();

        u.text("Sparklines: plotLines (connected) and plotHistogram (bars).", .{});
        u.text("Hover any plot to see the value at the cursor.", .{});
        u.separator();

        // --- Live FPS history ---
        var fps_overlay: [32]u8 = undefined;
        const fps_now: f32 = s.fps_hist[(s.fps_idx + hist_len - 1) % hist_len];
        const overlay: []const u8 = bufPrint(&fps_overlay, "{d:.1} fps", .{fps_now}) catch fps_overlay[0..0];
        // Linearize the ring buffer for clean left-to-right display.
        var fps_linear: [hist_len]f32 = undefined;
        for (0..hist_len) |i| {
            fps_linear[i] = s.fps_hist[(s.fps_idx + i) % hist_len];
        }
        u.plotLines("fps (60-frame history)", fps_linear[0..], .{
            .overlay = overlay,
            .min = 0,
            .max = 120,
            .height = 70,
        });

        u.spacing();

        // --- Sine wave ---
        var sine_buf: [128]f32 = undefined;
        for (sine_buf[0..], 0..) |*v, i| {
            const t: f32 = float(i) / float(sine_buf.len - 1);
            v.* = @sin(2.0 * pi * s.sine_freq * t + s.sine_phase);
        }
        u.plotLines("animated sine", sine_buf[0..], .{
            .min = -1.2,
            .max = 1.2,
            .height = 70,
        });
        _ = u.slider("sine frequency", &s.sine_freq, .{ .min = 0.1, .max = 8, .fmt = "{d:.2}" });

        u.spacing();

        // --- Bins (lines OR histogram) ---
        _ = u.checkbox("show bins as a connected line plot", &s.bins_as_lines);
        if (s.bins_as_lines) {
            u.plotLines("bins (line)", s.bins[0..], .{ .height = 70 });
        } else {
            u.plotHistogram("bins (histogram)", s.bins[0..], .{ .height = 70 });
        }
        u.text("Tweak the bins:", .{});
        // Edit each bin via a row of small dragInts.
        for (s.bins[0..], 0..) |*b, i| {
            var lbl_buf: [8]u8 = undefined;
            const lbl: []const u8 = bufPrint(&lbl_buf, "b{d}", .{i}) catch lbl_buf[0..0];
            _ = u.drag(lbl, b, .{ .speed = 0.2, .fmt = "{d:.0}" });
            if ((i + 1) % 4 != 0 and i + 1 < s.bins.len) {
                u.sameLine(.{});
            }
        }

        u.separator();
        u.text("beginTooltip / endTooltip - hover the swatch below:", .{});
        // Render a small swatch; if hovered, open a rich tooltip
        // with arbitrary widgets inside.
        const swatch_size: f32 = 24;
        const swatch_pos: Vec2 = u.getCursorScreenPos();
        if (u.button("swatch", .{ .size = .{ swatch_size * 4, swatch_size } })) {}
        if (u.isItemHovered(.{})) {
            u.beginTooltip();
            u.text("This is a block tooltip.", .{});
            u.text("Arbitrary widgets allowed inside:", .{});
            _ = u.colorEdit("col", &s.show_tooltip_demo_color, .{});
            u.endTooltip();
        }
        _ = swatch_pos;
    }
}

/// User-owned framework integration point.  See `examples/basic.zig`
/// for the canonical comment block; this declaration is the
/// AppBridge pattern's required convention.
/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - UI plotting basic",
            .width = screen_w,
            .height = screen_h,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
