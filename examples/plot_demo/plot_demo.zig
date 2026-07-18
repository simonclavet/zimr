// examples/plot_demo/plot_demo.zig — the growing zimr plot showcase,
// in the spirit of ImPlot's implot_demo. One tab per feature so it stays
// reviewable on a phone; add a tab as each parity item lands. Fully
// interactive (pan / zoom / pinch / double-tap-fit / value readout).

const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float64 = zm.float64;
const float = zm.float;
const Vec2 = zm.Vec2;
const Color = zm.Color;
const ui = z.ui_real;

const screen_w: i32 = 960;
const screen_h: i32 = 720;
const n: usize = 200;
const n_marker_pts: usize = 6;
const n_coarse: usize = 12;
const hm_rows: usize = 20;
const hm_cols: usize = 28;
const hist_bins: usize = 32;
const hist_n: usize = 4000;
const h2_cols: usize = 28;
const h2_rows: usize = 28;
const h2_n: usize = 6000;
const bg_items: usize = 3;
const bg_groups: usize = 5;
const hb_n: usize = 6;
const plot_w: f32 = 884;
const plot_h: f32 = 470;

const MarkerDef = struct { m: z.plot.Marker, name: []const u8 };
const markers = [_]MarkerDef{
    .{ .m = .circle, .name = "circle" },
    .{ .m = .square, .name = "square" },
    .{ .m = .diamond, .name = "diamond" },
    .{ .m = .triangle_up, .name = "tri up" },
    .{ .m = .triangle_down, .name = "tri down" },
    .{ .m = .triangle_left, .name = "tri left" },
    .{ .m = .triangle_right, .name = "tri right" },
    .{ .m = .plus, .name = "plus" },
    .{ .m = .cross, .name = "cross" },
    .{ .m = .asterisk, .name = "asterisk" },
};

// Vertical reference-line positions for the Inf Lines tab.
const vline_vals = [_]f64{ 2.0, 5.0, 8.0 };

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,
    p_lines: z.plot_ui.PlotState = .{},
    p_markers: z.plot_ui.PlotState = .{},
    p_more: z.plot_ui.PlotState = .{},
    p_stems: z.plot_ui.PlotState = .{},
    p_inflines: z.plot_ui.PlotState = .{},
    p_errorbars: z.plot_ui.PlotState = .{},
    p_annot: z.plot_ui.PlotState = .{},
    p_heatmap: z.plot_ui.PlotState = .{},
    cmap_idx: usize = 0,
    legend_loc_idx: usize = 1,
    p_hist: z.plot_ui.PlotState = .{},
    p_hist2d: z.plot_ui.PlotState = .{},
    p_bargroups: z.plot_ui.PlotState = .{},
    p_band: z.plot_ui.PlotState = .{},
    p_hbars: z.plot_ui.PlotState = .{},
    p_dual: z.plot_ui.PlotState = .{},
    p_dualx: z.plot_ui.PlotState = .{},
    p_theme: z.plot_ui.PlotState = .{},
    p_gaps: z.plot_ui.PlotState = .{},
    p_query: z.plot_ui.PlotState = .{},
    p_boxzoom: z.plot_ui.PlotState = .{},
    p_legend: z.plot_ui.PlotState = .{},
    legend_h: bool = false,
    p_image: z.plot_ui.PlotState = .{},
    img_tex: u32 = 0,
    theme_light: bool = false,
    p_drag: z.plot_ui.PlotState = .{},
    p_rect: z.plot_ui.PlotState = .{},
    p_sel: z.plot_ui.PlotState = .{},
    p_time: z.plot_ui.PlotState = .{},
    p_sym: z.plot_ui.PlotState = .{},
    p_axiscfg: z.plot_ui.PlotState = .{},
    p_equal: z.plot_ui.PlotState = .{},
    p_pie: z.plot_ui.PlotState = .{},
    p_bub: z.plot_ui.PlotState = .{},
    p_candle: z.plot_ui.PlotState = .{},
    p_digital: z.plot_ui.PlotState = .{},
    p_heatlbl: z.plot_ui.PlotState = .{},
    sub: [4]z.plot_ui.PlotState = @splat(.{}),
    bg_stacked: bool = false,
    box_mode: bool = true,
    sel: z.plot_ui.SelectRect = .{},
    current_tab: usize = 0,
    drag_px: f64 = 2.5,
    drag_py: f64 = 0.6,
    drag_lx: f64 = 6.0,
    drag_ly: f64 = -0.4,
    rect_x0: f64 = 2.0,
    rect_x1: f64 = 6.0,
    rect_y0: f64 = -0.5,
    rect_y1: f64 = 0.8,
    frame_count: u64 = 0,
    animate: bool = true,

    // Line + inf-line section (animated).
    xs: [n]f64 = undefined,
    sine: [n]f64 = undefined,
    cosw: [n]f64 = undefined,
    d1: [n]f64 = undefined,
    d2: [n]f64 = undefined,

    // Markers section: each marker as its own row of points.
    mxs: [n_marker_pts]f64 = undefined,
    mys: [markers.len][n_marker_pts]f64 = undefined,

    // Coarse series for bars / stairs / stems / error bars.
    cxs: [n_coarse]f64 = undefined,
    cys: [n_coarse]f64 = undefined,
    stem_ys: [n_coarse]f64 = undefined,
    cerr: [n_coarse]f64 = undefined,
    cneg: [n_coarse]f64 = undefined,
    cpos: [n_coarse]f64 = undefined,

    // Smooth positive curve for the shaded fill.
    sxs: [n]f64 = undefined,
    area: [n]f64 = undefined,

    // Heatmap grid + bounds corners (for auto-fit).
    hvals: [hm_rows * hm_cols]f64 = undefined,
    hxs: [2]f64 = undefined,
    hys: [2]f64 = undefined,

    // Histogram (1D) + 2D histogram data.
    samp: [hist_n]f64 = undefined,
    hist_centers: [hist_bins]f64 = undefined,
    hist_counts: [hist_bins]f64 = undefined,
    sx: [h2_n]f64 = undefined,
    sy: [h2_n]f64 = undefined,
    h2vals: [h2_rows * h2_cols]f64 = undefined,
    h2x: [2]f64 = undefined,
    h2y: [2]f64 = undefined,
    h2max: f64 = 1,

    // Bar groups (item-major), band (between two curves), horizontal bars.
    bg_vals: [bg_items * bg_groups]f64 = undefined,
    bg_x: [2]f64 = undefined,
    bg_y: [2]f64 = undefined,
    band_hi: [n]f64 = undefined,
    band_lo: [n]f64 = undefined,
    hb_vals: [hb_n]f64 = undefined,
    hb_pos: [hb_n]f64 = undefined,
    time_x: [n]f64 = undefined,
    time_y: [n]f64 = undefined,
    sym_x: [n]f64 = undefined,
    sym_y: [n]f64 = undefined,
    acfg_x: [n]f64 = undefined,
    acfg_y: [n]f64 = undefined,
    eq_x: [n]f64 = undefined,
    eq_y: [n]f64 = undefined,
    pie_vals: [6]f64 = .{ 30, 22, 16, 12, 14, 6 },
    bub_x: [14]f64 = undefined,
    bub_y: [14]f64 = undefined,
    bub_sz: [14]f64 = undefined,
    c_x: [40]f64 = undefined,
    c_o: [40]f64 = undefined,
    c_h: [40]f64 = undefined,
    c_l: [40]f64 = undefined,
    c_c: [40]f64 = undefined,
    dig_x: [64]f64 = undefined,
    dig_y: [64]f64 = undefined,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn rngNext(state: *u64) f64 {
    state.* = state.* *% 6364136223846793005 +% 1442695040888963407;
    const top: u64 = state.* >> 40; // 24 high bits
    return float64(top) / float64(@as(u64, 1) << 24);
}

/// Approx N(0,1) via the sum of 12 uniforms (central-limit). Deterministic.
fn gauss(state: *u64) f64 {
    var sum: f64 = 0;
    var k: usize = 0;
    while (k < 12) : (k += 1) {
        sum += rngNext(state);
    }
    return sum - 6.0;
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, @embedFile("atkinson_mono_ttf"), 22);
    s.* = .{ .font = font, .ui_host = z.UiHost.init(gpa, font) };

    // Checkerboard texture for the Image tab: built once, uploaded to the GPU,
    // and registered to a draw-list id we keep in State.
    const checker: z.Image = try z.genImageChecked(
        gpa,
        64,
        64,
        8,
        8,
        .{ .r = 60, .g = 70, .b = 120, .a = 255 },
        .{ .r = 230, .g = 220, .b = 120, .a = 255 },
    );
    const tex: z.WgpuTexture = z.loadTextureFromImage(f.gl, checker);
    z.unloadImage(gpa, checker);
    s.img_tex = f.gl.renderer().registerOwnedTexture(tex);

    var j: usize = 0;
    while (j < n_marker_pts) : (j += 1) {
        s.mxs[j] = float64(j) + 1.0;
    }
    var i: usize = 0;
    while (i < markers.len) : (i += 1) {
        var k: usize = 0;
        while (k < n_marker_pts) : (k += 1) {
            s.mys[i][k] = float64(i);
        }
    }

    var b: usize = 0;
    while (b < n_coarse) : (b += 1) {
        const t: f64 = float64(b);
        s.cxs[b] = t + 0.5;
        s.cys[b] = 1.0 + float64((b * 7 + 3) % 6) * 0.5;
        s.stem_ys[b] = @sin(t * 0.7) * 2.0;
        s.cerr[b] = 0.25 + 0.12 * float64(b % 3);
        s.cneg[b] = 0.2 + 0.1 * float64(b % 2);
        s.cpos[b] = 0.5 + 0.1 * float64((b + 1) % 3);
    }

    var m: usize = 0;
    while (m < n) : (m += 1) {
        const t: f64 = float64(m) / @as(f64, n - 1) * 12.0;
        s.sxs[m] = t;
        s.area[m] = @sin(t * 0.8) * 1.5 + 2.5;
    }

    s.hxs = .{ 0, @floatFromInt(hm_cols) };
    s.hys = .{ 0, @floatFromInt(hm_rows) };

    // 1D histogram: gaussian samples binned over [-4, 4].
    var rng: u64 = 0x9e3779b97f4a7c15;
    for (0..hist_n) |hi| {
        s.samp[hi] = gauss(&rng);
    }
    z.plot.histogramBins(&s.samp, &s.hist_counts, -4.0, 4.0);
    const bf: f64 = float64(hist_bins);
    for (0..hist_bins) |bi| {
        s.hist_centers[bi] = -4.0 + 8.0 * (float64(bi) + 0.5) / bf;
    }

    // 2D histogram: independent gaussian x/y, binned over [-3,3]^2.
    for (0..h2_n) |pi| {
        s.sx[pi] = gauss(&rng);
        s.sy[pi] = gauss(&rng);
    }
    z.plot.histogramBins2D(&s.sx, &s.sy, &s.h2vals, h2_cols, h2_rows, -3.0, 3.0, -3.0, 3.0);
    s.h2x = .{ -3, 3 };
    s.h2y = .{ -3, 3 };
    var mx: f64 = 1;
    for (s.h2vals) |v| {
        if (v > mx) {
            mx = v;
        }
    }
    s.h2max = mx;

    // Bar groups: 3 items x 5 groups (item-major). Track stacked-sum max.
    const bgv = [_]f64{
        2.0, 3.0, 1.5, 4.0, 2.5, // item 0 across groups
        1.0, 2.0, 3.0, 1.5, 2.0, // item 1
        2.5, 1.0, 2.0, 2.5, 3.0, // item 2
    };
    for (0..bg_items * bg_groups) |k| {
        s.bg_vals[k] = bgv[k];
    }
    var bgmax: f64 = 1;
    for (0..bg_groups) |g| {
        var sum: f64 = 0;
        for (0..bg_items) |it| {
            sum += s.bg_vals[it * bg_groups + g];
        }
        if (sum > bgmax) {
            bgmax = sum;
        }
    }
    s.bg_x = .{ -0.6, float64(bg_groups) - 0.4 };
    s.bg_y = .{ 0, bgmax * 1.05 };

    // Horizontal bars: position 0 has value 0 so the x=0 baseline is in frame.
    const hbv = [_]f64{ 0, 2.0, 4.0, 1.5, 5.0, 3.0 };
    for (0..hb_n) |k| {
        s.hb_pos[k] = @floatFromInt(k);
        s.hb_vals[k] = hbv[k];
    }

    // Time series: a 2-day diurnal "temperature" curve over epoch seconds.
    const t0: f64 = 1704067200; // 2024-01-01 00:00 UTC
    const tspan: f64 = 2.0 * 86400.0;
    var tseed: u64 = 99;
    for (0..n) |k| {
        const fr: f64 = float64(k) / @as(f64, n - 1);
        s.time_x[k] = t0 + fr * tspan;
        const diurnal: f64 = 15.0 + 8.0 * @sin(fr * 2.0 * 6.2831853 - 1.5708);
        s.time_y[k] = diurnal + gauss(&tseed) * 0.6;
    }

    // Symlog series: a saturating curve crossing zero, spanning +/-1000.
    for (0..n) |k| {
        const fr: f64 = float64(k) / @as(f64, n - 1);
        s.sym_x[k] = fr * 10.0;
        const uu: f64 = (fr - 0.5) * 8.0;
        s.sym_y[k] = 1000.0 * (uu / (1.0 + @abs(uu)));
    }

    // Axis-config series: x in [0,1] (percent), y a 0..120 swing.
    for (0..n) |k| {
        const fr: f64 = float64(k) / @as(f64, n - 1);
        s.acfg_x[k] = fr;
        s.acfg_y[k] = 60.0 + 50.0 * @sin(fr * 6.2831853);
    }

    // Equal-aspect series: a unit circle (round only with equal aspect).
    for (0..n) |k| {
        const t: f64 = float64(k) / @as(f64, n - 1) * 6.2831853;
        s.eq_x[k] = @cos(t);
        s.eq_y[k] = @sin(t);
    }

    // Bubbles: scattered points with a third value mapped to size.
    var bseed: u64 = 99;
    for (0..14) |k| {
        s.bub_x[k] = 1.0 + rngNext(&bseed) * 9.0;
        s.bub_y[k] = 1.0 + rngNext(&bseed) * 8.0;
        s.bub_sz[k] = 2.0 + rngNext(&bseed) * 90.0;
    }

    // Candlesticks: a small random walk of OHLC bars.
    var cseed: u64 = 1234;
    var price: f64 = 100;
    for (0..40) |k| {
        s.c_x[k] = @floatFromInt(k);
        const o: f64 = price;
        const c: f64 = o + (rngNext(&cseed) - 0.5) * 9.0;
        const wig: f64 = rngNext(&cseed) * 4.0;
        s.c_o[k] = o;
        s.c_c[k] = c;
        s.c_h[k] = @max(o, c) + wig;
        s.c_l[k] = @min(o, c) - wig;
        price = c;
    }

    // Digital trace: a pseudo-random 0/1 bitstream.
    var dseed: u64 = 555;
    for (0..64) |k| {
        s.dig_x[k] = @floatFromInt(k);
        s.dig_y[k] = if (rngNext(&dseed) > 0.5) 1 else 0;
    }
}

fn regen(s: *State) void {
    const phase: f64 = if (s.animate) float64(s.frame_count) * 0.03 else 0.0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const t: f64 = float64(i) / @as(f64, n - 1) * 10.0;
        s.xs[i] = t;
        s.sine[i] = @sin(t + phase);
        s.cosw[i] = @cos(t * 0.7 + phase) * 0.8;
        const env: f64 = 0.35 + 0.25 * @sin(t * 0.5);
        s.band_hi[i] = s.sine[i] + env;
        s.band_lo[i] = s.sine[i] - env;
        s.d1[i] = 50.0 + 40.0 * @sin(t + phase);
        s.d2[i] = 0.5 + 0.45 * @cos(t * 0.7 + phase);
    }
    var r: usize = 0;
    while (r < hm_rows) : (r += 1) {
        var c: usize = 0;
        while (c < hm_cols) : (c += 1) {
            const fx: f64 = float64(c);
            const fy: f64 = float64(r);
            s.hvals[r * hm_cols + c] = @sin(fx * 0.4 + phase) * @cos(fy * 0.4);
        }
    }
}

fn tabLines(u: ui.Ui, s: *State) void {
    const locs = [_]z.plot.LegendLocation{ .nw, .ne, .sw, .se };
    const loc: z.plot.LegendLocation = locs[s.legend_loc_idx % locs.len];
    if (u.button("legend corner", .{})) {
        s.legend_loc_idx += 1;
    }
    u.text("corner: {s}  (tap a legend row to hide/show that line)", .{@tagName(loc)});
    const series = [_]z.plot_ui.Series{
        .{
            .kind = .line,
            .xs = &s.xs,
            .ys = &s.sine,
            .spec = .{ .color = .{ .r = 33, .g = 150, .b = 243, .a = 255 } },
            .label = "sin",
        },
        .{
            .kind = .line,
            .xs = &s.xs,
            .ys = &s.cosw,
            .spec = .{ .color = .{ .r = 255, .g = 152, .b = 0, .a = 255 } },
            .label = "cos",
        },
    };
    z.plot_ui.show(u, &s.p_lines, .{ plot_w, plot_h - 40 }, &series, .{
        .title = "live lines",
        .legend_location = loc,
    });
}

fn tabMarkers(u: ui.Ui, s: *State) void {
    var mseries: [markers.len]z.plot_ui.Series = undefined;
    var i: usize = 0;
    while (i < markers.len) : (i += 1) {
        mseries[i] = .{
            .kind = .scatter,
            .xs = &s.mxs,
            .ys = &s.mys[i],
            .spec = .{ .marker = markers[i].m, .marker_size = 5.0, .color = z.plot.autoColor(i) },
            .label = markers[i].name,
        };
    }
    z.plot_ui.show(u, &s.p_markers, .{ plot_w, plot_h }, &mseries, .{ .title = "marker types" });
}

fn tabMore(u: ui.Ui, s: *State) void {
    const series = [_]z.plot_ui.Series{
        .{
            .kind = .shaded,
            .xs = &s.sxs,
            .ys = &s.area,
            .shaded = .{ .color = .{ .r = 76, .g = 175, .b = 80, .a = 50 }, .y_ref = 0 },
        },
        .{
            .kind = .line,
            .xs = &s.sxs,
            .ys = &s.area,
            .spec = .{ .color = .{ .r = 76, .g = 175, .b = 80, .a = 255 } },
            .label = "area",
        },
        .{
            .kind = .bars,
            .xs = &s.cxs,
            .ys = &s.cys,
            .bars = .{ .color = .{ .r = 0, .g = 188, .b = 212, .a = 120 }, .width = 0.6 },
            .label = "bars",
        },
        .{
            .kind = .stairs,
            .xs = &s.cxs,
            .ys = &s.cys,
            .spec = .{ .color = .{ .r = 156, .g = 39, .b = 176, .a = 255 } },
            .label = "stairs",
        },
    };
    z.plot_ui.show(u, &s.p_more, .{ plot_w, plot_h }, &series, .{ .title = "shaded / bars / stairs" });
}

fn tabStems(u: ui.Ui, s: *State) void {
    const series = [_]z.plot_ui.Series{
        .{
            .kind = .stems,
            .xs = &s.cxs,
            .ys = &s.stem_ys,
            .spec = .{
                .color = .{ .r = 33, .g = 150, .b = 243, .a = 255 },
                .marker = .circle,
                .marker_size = 4.0,
            },
            .label = "stems",
        },
    };
    z.plot_ui.show(u, &s.p_stems, .{ plot_w, plot_h }, &series, .{ .title = "stem plot" });
}

fn tabInfLines(u: ui.Ui, s: *State) void {
    const series = [_]z.plot_ui.Series{
        .{
            .kind = .line,
            .xs = &s.xs,
            .ys = &s.sine,
            .spec = .{ .color = .{ .r = 33, .g = 150, .b = 243, .a = 255 } },
            .label = "sin",
        },
        .{
            .kind = .inf_lines,
            .xs = &vline_vals,
            .ys = &vline_vals,
            .inflines = .{ .color = .{ .r = 244, .g = 67, .b = 54, .a = 200 } },
            .label = "markers",
        },
    };
    z.plot_ui.show(u, &s.p_inflines, .{ plot_w, plot_h }, &series, .{ .title = "infinite lines" });
}

fn tabErrorBars(u: ui.Ui, s: *State) void {
    const series = [_]z.plot_ui.Series{
        .{
            .kind = .bars,
            .xs = &s.cxs,
            .ys = &s.cys,
            .bars = .{ .color = .{ .r = 0, .g = 188, .b = 212, .a = 90 }, .width = 0.5 },
            .label = "value",
        },
        .{
            .kind = .error_bars,
            .xs = &s.cxs,
            .ys = &s.cys,
            .err = &s.cerr,
            .errorbars = .{ .color = .{ .r = 255, .g = 180, .b = 0, .a = 255 } },
            .label = "sym err",
        },
        .{
            .kind = .line,
            .xs = &s.cxs,
            .ys = &s.stem_ys,
            .spec = .{ .color = .{ .r = 156, .g = 39, .b = 176, .a = 255 }, .marker = .circle, .marker_size = 3 },
            .label = "signal",
        },
        .{
            .kind = .error_bars_asym,
            .xs = &s.cxs,
            .ys = &s.stem_ys,
            .err_neg = &s.cneg,
            .err_pos = &s.cpos,
            .errorbars = .{ .color = .{ .r = 233, .g = 30, .b = 99, .a = 255 } },
            .label = "asym err",
        },
    };
    z.plot_ui.show(u, &s.p_errorbars, .{ plot_w, plot_h }, &series, .{ .title = "error bars (sym + asym)" });
}

fn tabAnnotations(u: ui.Ui, s: *State) void {
    const series = [_]z.plot_ui.Series{
        .{
            .kind = .line,
            .xs = &s.xs,
            .ys = &s.sine,
            .spec = .{ .color = .{ .r = 33, .g = 150, .b = 243, .a = 255 } },
            .label = "sin",
        },
    };
    const overlays = [_]z.plot_ui.Overlay{
        .{
            .kind = .text,
            .text = "free text label",
            .x = 5.0,
            .y = 1.25,
            .text_spec = .{ .color = .{ .r = 210, .g = 210, .b = 220, .a = 255 } },
        },
        .{ .kind = .annotation, .text = "first peak", .x = 1.57, .y = 1.0 },
        .{ .kind = .annotation, .text = "trough", .x = 4.71, .y = -1.0, .ann_spec = .{ .offset = .{ 0, 16 } } },
        .{ .kind = .tag_x, .text = "x=5", .value = 5.0 },
        .{ .kind = .tag_y, .text = "0", .value = 0.0 },
    };
    z.plot_ui.show(u, &s.p_annot, .{ plot_w, plot_h }, &series, .{
        .title = "text / annotations / tags",
        .overlays = &overlays,
    });
}

fn tabHeatmap(u: ui.Ui, s: *State) void {
    const cmaps = [_]z.plot.Colormap{ .viridis, .plasma, .jet, .hot, .cool, .spectral, .twilight, .greys };
    const cmap: z.plot.Colormap = cmaps[s.cmap_idx % cmaps.len];
    if (u.button("next colormap", .{})) {
        s.cmap_idx += 1;
    }
    u.text("colormap: {s}", .{@tagName(cmap)});
    const series = [_]z.plot_ui.Series{
        .{
            .kind = .heatmap,
            .xs = &s.hxs,
            .ys = &s.hys,
            .values = &s.hvals,
            .rows = hm_rows,
            .cols = hm_cols,
            .heatmap = .{
                .cmap = cmap,
                .min = -1,
                .max = 1,
                .x0 = 0,
                .x1 = @floatFromInt(hm_cols),
                .y0 = 0,
                .y1 = @floatFromInt(hm_rows),
            },
        },
    };
    z.plot_ui.show(u, &s.p_heatmap, .{ plot_w, plot_h - 40 }, &series, .{
        .title = "heatmap",
        .show_legend = false,
        .colorbar = .{
            .cmap = cmap,
            .min = -1,
            .max = 1,
            .ticks = 5,
            .label_decimals = 1,
        },
    });
}

fn tabHistogram(u: ui.Ui, s: *State) void {
    const series = [_]z.plot_ui.Series{
        .{
            .kind = .bars,
            .xs = &s.hist_centers,
            .ys = &s.hist_counts,
            .bars = .{ .color = .{ .r = 100, .g = 181, .b = 246, .a = 200 }, .width = 0.92 },
            .label = "counts",
        },
    };
    z.plot_ui.show(u, &s.p_hist, .{ plot_w, plot_h }, &series, .{
        .title = "histogram - 4000 gaussian samples",
    });
}

fn tabHistogram2D(u: ui.Ui, s: *State) void {
    const series = [_]z.plot_ui.Series{
        .{
            .kind = .heatmap,
            .xs = &s.h2x,
            .ys = &s.h2y,
            .values = &s.h2vals,
            .rows = h2_rows,
            .cols = h2_cols,
            .heatmap = .{ .cmap = .plasma, .min = 0, .max = s.h2max, .x0 = -3, .x1 = 3, .y0 = -3, .y1 = 3 },
        },
    };
    z.plot_ui.show(u, &s.p_hist2d, .{ plot_w, plot_h }, &series, .{
        .title = "2D histogram - gaussian x/y",
        .show_legend = false,
    });
}

fn tabBarGroups(u: ui.Ui, s: *State) void {
    if (u.button(if (s.bg_stacked) "show clustered" else "show stacked", .{})) {
        s.bg_stacked = !s.bg_stacked;
    }
    u.text("mode: {s}  (3 items x 5 groups)", .{if (s.bg_stacked) "stacked" else "clustered"});
    const series = [_]z.plot_ui.Series{
        .{
            .kind = .bar_groups,
            .xs = &s.bg_x,
            .ys = &s.bg_y,
            .values = &s.bg_vals,
            .rows = bg_items,
            .cols = bg_groups,
            .bargroups = .{ .stacked = s.bg_stacked, .width = 0.7 },
        },
    };
    z.plot_ui.show(u, &s.p_bargroups, .{ plot_w, plot_h - 40 }, &series, .{
        .title = "bar groups",
        .show_legend = false,
    });
}

fn tabBand(u: ui.Ui, s: *State) void {
    const series = [_]z.plot_ui.Series{
        .{
            .kind = .shaded_between,
            .xs = &s.xs,
            .ys = &s.band_hi,
            .ys2 = &s.band_lo,
            .shaded = .{ .color = .{ .r = 33, .g = 150, .b = 243, .a = 55 } },
            .label = "band",
        },
        .{
            .kind = .line,
            .xs = &s.xs,
            .ys = &s.sine,
            .spec = .{ .color = .{ .r = 33, .g = 150, .b = 243, .a = 255 } },
            .label = "signal",
        },
    };
    z.plot_ui.show(u, &s.p_band, .{ plot_w, plot_h }, &series, .{ .title = "shaded between two lines" });
}

fn tabHBars(u: ui.Ui, s: *State) void {
    const series = [_]z.plot_ui.Series{
        .{
            .kind = .bars,
            .xs = &s.hb_vals,
            .ys = &s.hb_pos,
            .bars = .{
                .horizontal = true,
                .color = .{ .r = 0, .g = 188, .b = 212, .a = 200 },
                .width = 0.6,
                .show_labels = true,
            },
            .label = "value",
        },
    };
    z.plot_ui.show(u, &s.p_hbars, .{ plot_w, plot_h }, &series, .{ .title = "horizontal bars" });
}

fn tabDual(u: ui.Ui, s: *State) void {
    const series = [_]z.plot_ui.Series{
        .{
            .kind = .line,
            .xs = &s.xs,
            .ys = &s.d1,
            .spec = .{ .color = .{ .r = 33, .g = 150, .b = 243, .a = 255 } },
            .label = "left (y1)",
        },
        .{
            .kind = .line,
            .xs = &s.xs,
            .ys = &s.d2,
            .axis = .y2,
            .spec = .{ .color = .{ .r = 255, .g = 152, .b = 0, .a = 255 } },
            .label = "right (y2)",
        },
    };
    z.plot_ui.show(u, &s.p_dual, .{ plot_w, plot_h }, &series, .{
        .title = "dual Y axes",
        .y_label = "0..100",
        .y2_label = "0..1",
    });
}

fn tabSubplots(u: ui.Ui, s: *State) void {
    const sp: z.plot_ui.Subplots = z.plot_ui.beginSubplots(u, .{ plot_w, plot_h }, 2, 2, 10);
    {
        const sz: Vec2 = sp.cellAt(0, 0);
        const series = [_]z.plot_ui.Series{
            .{
                .kind = .line,
                .xs = &s.xs,
                .ys = &s.sine,
                .spec = .{ .color = .{ .r = 33, .g = 150, .b = 243, .a = 255 } },
            },
        };
        z.plot_ui.show(u, &s.sub[0], sz, &series, .{ .title = "sin", .show_legend = false });
    }
    {
        const sz: Vec2 = sp.cellAt(0, 1);
        const series = [_]z.plot_ui.Series{
            .{
                .kind = .line,
                .xs = &s.xs,
                .ys = &s.cosw,
                .spec = .{ .color = .{ .r = 255, .g = 152, .b = 0, .a = 255 } },
            },
        };
        z.plot_ui.show(u, &s.sub[1], sz, &series, .{ .title = "cos", .show_legend = false });
    }
    {
        const sz: Vec2 = sp.cellAt(1, 0);
        const series = [_]z.plot_ui.Series{
            .{
                .kind = .scatter,
                .xs = &s.cxs,
                .ys = &s.cys,
                .spec = .{ .marker = .diamond, .marker_size = 5, .color = .{ .r = 76, .g = 175, .b = 80, .a = 255 } },
            },
        };
        z.plot_ui.show(u, &s.sub[2], sz, &series, .{ .title = "scatter", .show_legend = false });
    }
    {
        const sz: Vec2 = sp.cellAt(1, 1);
        const series = [_]z.plot_ui.Series{
            .{
                .kind = .bars,
                .xs = &s.cxs,
                .ys = &s.cys,
                .bars = .{ .color = .{ .r = 0, .g = 188, .b = 212, .a = 160 }, .width = 0.7 },
            },
        };
        z.plot_ui.show(u, &s.sub[3], sz, &series, .{ .title = "bars", .show_legend = false });
    }
    sp.finish();
}

fn tabDrag(u: ui.Ui, s: *State) void {
    u.text("grab the dot or either guide line and drag it", .{});
    u.text("pt = ({d:.2}, {d:.2})   x-line = {d:.2}   y-line = {d:.2}", .{
        s.drag_px,
        s.drag_py,
        s.drag_lx,
        s.drag_ly,
    });
    const series = [_]z.plot_ui.Series{
        .{
            .kind = .line,
            .xs = &s.xs,
            .ys = &s.sine,
            .spec = .{ .color = .{ .r = 33, .g = 150, .b = 243, .a = 200 } },
        },
    };
    const handles = [_]z.plot_ui.DragHandle{
        .{ .kind = .point, .x = &s.drag_px, .y = &s.drag_py, .color = .{ .r = 255, .g = 87, .b = 34, .a = 255 } },
        .{ .kind = .line_x, .x = &s.drag_lx, .color = .{ .r = 76, .g = 175, .b = 80, .a = 220 } },
        .{ .kind = .line_y, .y = &s.drag_ly, .color = .{ .r = 156, .g = 39, .b = 176, .a = 220 } },
    };
    z.plot_ui.show(u, &s.p_drag, .{ plot_w, plot_h - 40 }, &series, .{
        .title = "drag tools",
        .drag_handles = &handles,
        .show_legend = false,
    });
}

fn tabDragRect(u: ui.Ui, s: *State) void {
    u.text("drag the rectangle interior to move it, a corner to resize", .{});
    const xlo: f64 = @min(s.rect_x0, s.rect_x1);
    const xhi: f64 = @max(s.rect_x0, s.rect_x1);
    const ylo: f64 = @min(s.rect_y0, s.rect_y1);
    const yhi: f64 = @max(s.rect_y0, s.rect_y1);
    var inside: usize = 0;
    for (s.xs, s.sine) |xv, yv| {
        if (xv >= xlo and xv <= xhi and yv >= ylo and yv <= yhi) {
            inside += 1;
        }
    }
    u.text("x:[{d:.2}, {d:.2}]  y:[{d:.2}, {d:.2}]  pts inside: {d}", .{ xlo, xhi, ylo, yhi, inside });
    const series = [_]z.plot_ui.Series{
        .{
            .kind = .line,
            .xs = &s.xs,
            .ys = &s.sine,
            .spec = .{ .color = .{ .r = 33, .g = 150, .b = 243, .a = 200 } },
        },
    };
    const dr: z.plot_ui.DragRect = .{
        .x0 = &s.rect_x0,
        .x1 = &s.rect_x1,
        .y0 = &s.rect_y0,
        .y1 = &s.rect_y1,
    };
    z.plot_ui.show(u, &s.p_rect, .{ plot_w, plot_h - 40 }, &series, .{
        .title = "drag rect + query",
        .drag_rect = dr,
        .show_legend = false,
    });
}

fn tabSelect(u: ui.Ui, s: *State) void {
    _ = u.checkbox("select mode (drag = box-select; uncheck to pan)", &s.box_mode);
    if (s.sel.has) {
        var inside: usize = 0;
        for (s.xs, s.sine) |xv, yv| {
            if (xv >= s.sel.x0 and xv <= s.sel.x1 and yv >= s.sel.y0 and yv <= s.sel.y1) {
                inside += 1;
            }
        }
        u.text("selected x:[{d:.2}, {d:.2}]  y:[{d:.2}, {d:.2}]  pts: {d}", .{
            s.sel.x0,
            s.sel.x1,
            s.sel.y0,
            s.sel.y1,
            inside,
        });
    } else {
        u.text("drag a box over the curve to select a region (tap to clear)", .{});
    }
    const series = [_]z.plot_ui.Series{
        .{
            .kind = .line,
            .xs = &s.xs,
            .ys = &s.sine,
            .spec = .{ .color = .{ .r = 33, .g = 150, .b = 243, .a = 200 } },
        },
    };
    z.plot_ui.show(u, &s.p_sel, .{ plot_w, plot_h - 40 }, &series, .{
        .title = "box select + query",
        .box_select = s.box_mode,
        .selection = &s.sel,
        .show_legend = false,
    });
}

fn tabTime(u: ui.Ui, s: *State) void {
    u.text("epoch-seconds x axis with date/time ticks (pan/zoom to rescale)", .{});
    const series = [_]z.plot_ui.Series{
        .{
            .kind = .line,
            .xs = &s.time_x,
            .ys = &s.time_y,
            .spec = .{ .color = .{ .r = 255, .g = 152, .b = 0, .a = 255 } },
        },
    };
    z.plot_ui.show(u, &s.p_time, .{ plot_w, plot_h - 40 }, &series, .{
        .title = "time series (2 days)",
        .x_time = true,
        .y_label = "degC",
        .show_legend = false,
    });
}

fn tabSymlog(u: ui.Ui, s: *State) void {
    u.text("symmetric-log Y: linear near 0, log decades beyond (linthresh=1)", .{});
    const series = [_]z.plot_ui.Series{
        .{
            .kind = .line,
            .xs = &s.sym_x,
            .ys = &s.sym_y,
            .spec = .{ .color = .{ .r = 33, .g = 150, .b = 243, .a = 255 } },
        },
    };
    z.plot_ui.show(u, &s.p_sym, .{ plot_w, plot_h - 40 }, &series, .{
        .title = "symlog",
        .y_symlog = true,
        .y_linthresh = 1,
        .show_legend = false,
    });
}

fn tabAxisCfg(u: ui.Ui, s: *State) void {
    u.text("custom Y labels + percent X; view locked to data via constraints", .{});
    const yt = [_]f64{ 0, 30, 60, 90, 120 };
    const yl = [_][]const u8{ "0", "cool", "warm", "hot", "max" };
    const series = [_]z.plot_ui.Series{
        .{
            .kind = .line,
            .xs = &s.acfg_x,
            .ys = &s.acfg_y,
            .spec = .{ .color = .{ .r = 76, .g = 175, .b = 80, .a = 255 } },
        },
    };
    z.plot_ui.show(u, &s.p_axiscfg, .{ plot_w, plot_h - 40 }, &series, .{
        .title = "axiscfg",
        .x_format = .percent,
        .y_tick_values = &yt,
        .y_tick_labels = &yl,
        .x_constraints = .{ .min = 0, .max = 1 },
        .y_constraints = .{ .min = 0, .max = 120 },
        .show_legend = false,
    });
}

fn tabEqual(u: ui.Ui, s: *State) void {
    u.text("equal aspect: identical units/pixel on both axes keeps the circle round", .{});
    const series = [_]z.plot_ui.Series{
        .{
            .kind = .line,
            .xs = &s.eq_x,
            .ys = &s.eq_y,
            .spec = .{ .color = .{ .r = 233, .g = 30, .b = 99, .a = 255 } },
        },
    };
    z.plot_ui.show(u, &s.p_equal, .{ plot_w, plot_h - 40 }, &series, .{
        .title = "equal",
        .equal_aspect = true,
        .show_legend = false,
    });
}

fn tabPie(u: ui.Ui, s: *State) void {
    u.text("pie chart — wedge angle is proportional; labels + percentages inside", .{});
    const labs = [_][]const u8{ "rent", "food", "fun", "save", "travel", "misc" };
    const series = [_]z.plot_ui.Series{
        .{
            .kind = .pie,
            .xs = &[_]f64{},
            .ys = &[_]f64{},
            .values = &s.pie_vals,
            .pie = .{ .radius = 1.0, .labels = &labs },
        },
    };
    z.plot_ui.show(u, &s.p_pie, .{ plot_w, plot_h - 40 }, &series, .{
        .title = "pie",
        .equal_aspect = true,
        .show_legend = false,
    });
}

fn tabBubbles(u: ui.Ui, s: *State) void {
    u.text("bubble chart — marker radius encodes a third value", .{});
    const series = [_]z.plot_ui.Series{
        .{
            .kind = .bubbles,
            .xs = &s.bub_x,
            .ys = &s.bub_y,
            .sizes = &s.bub_sz,
            .bubble = .{ .color = .{ .r = 0, .g = 188, .b = 212, .a = 255 } },
        },
    };
    z.plot_ui.show(u, &s.p_bub, .{ plot_w, plot_h - 40 }, &series, .{
        .title = "bubbles",
        .show_legend = false,
    });
}

fn tabCandles(u: ui.Ui, s: *State) void {
    u.text("candlestick / OHLC — green when close >= open, red otherwise", .{});
    const series = [_]z.plot_ui.Series{
        .{
            .kind = .candlestick,
            .xs = &s.c_x,
            .ys = &s.c_c,
            .opens = &s.c_o,
            .highs = &s.c_h,
            .lows = &s.c_l,
            .closes = &s.c_c,
        },
    };
    z.plot_ui.show(u, &s.p_candle, .{ plot_w, plot_h - 40 }, &series, .{
        .title = "ohlc",
        .show_legend = false,
    });
}

fn tabDigital(u: ui.Ui, s: *State) void {
    u.text("digital / logic trace — 0/1 step signal in a fixed bottom band", .{});
    const series = [_]z.plot_ui.Series{
        .{
            .kind = .digital,
            .xs = &s.dig_x,
            .ys = &s.dig_y,
            .digital = .{
                .color = .{ .r = 76, .g = 175, .b = 80, .a = 255 },
                .height = 46,
                .offset = 36,
            },
        },
    };
    z.plot_ui.show(u, &s.p_digital, .{ plot_w, plot_h - 40 }, &series, .{
        .title = "digital",
        .show_legend = false,
    });
}

fn tabHeatLabels(u: ui.Ui, s: *State) void {
    u.text("heatmap cell labels — text color auto-picks black/white for contrast", .{});
    const vals = [_]f64{
        0.05, 0.30, 0.55, 0.80,
        0.20, 0.45, 0.70, 0.95,
        0.10, 0.35, 0.60, 0.85,
        0.25, 0.50, 0.75, 1.00,
    };
    const series = [_]z.plot_ui.Series{
        .{
            .kind = .heatmap,
            .xs = &[_]f64{},
            .ys = &[_]f64{},
            .values = &vals,
            .rows = 4,
            .cols = 4,
            .heatmap = .{
                .cmap = .viridis,
                .min = 0,
                .max = 1,
                .x0 = 0,
                .x1 = 4,
                .y0 = 0,
                .y1 = 4,
                .show_labels = true,
                .label_decimals = 2,
            },
        },
    };
    z.plot_ui.show(u, &s.p_heatlbl, .{ plot_w, plot_h - 40 }, &series, .{
        .title = "cells",
        .show_legend = false,
    });
}

fn tabDualX(u: ui.Ui, s: *State) void {
    u.text("two independent X axes: bottom 0..10 (blue), top 32..212 (orange)", .{});
    var xs1: [40]f64 = undefined;
    var ys1: [40]f64 = undefined;
    var xs2: [40]f64 = undefined;
    var ys2: [40]f64 = undefined;
    for (0..40) |i| {
        const fi: f64 = float64(i);
        const t: f64 = fi / 39.0;
        xs1[i] = t * 10.0;
        ys1[i] = 0.5 + 0.4 * @sin(xs1[i]);
        xs2[i] = 32.0 + t * 180.0;
        ys2[i] = 0.5 + 0.4 * @cos(xs2[i] / 30.0);
    }
    const series = [_]z.plot_ui.Series{
        .{
            .kind = .line,
            .xs = &xs1,
            .ys = &ys1,
            .spec = .{ .color = .{ .r = 100, .g = 181, .b = 246, .a = 255 } },
            .label = "x1 series",
        },
        .{
            .kind = .line,
            .xs = &xs2,
            .ys = &ys2,
            .x_axis = .x2,
            .spec = .{ .color = .{ .r = 255, .g = 160, .b = 60, .a = 255 } },
            .label = "x2 series",
        },
    };
    z.plot_ui.show(u, &s.p_dualx, .{ plot_w, plot_h - 40 }, &series, .{
        .title = "dual X axes",
        .x_label = "x1 (bottom)",
        .x2_label = "x2 (top)",
    });
}

fn tabTheme(u: ui.Ui, s: *State) void {
    _ = u.checkbox("light theme", &s.theme_light);
    u.text("the same plot under a swappable Style (area bg, grid, border, text)", .{});
    var xs: [60]f64 = undefined;
    var ys: [60]f64 = undefined;
    var yb: [60]f64 = undefined;
    for (0..60) |i| {
        const t: f64 = float64(i) / 59.0 * 6.28318;
        xs[i] = t;
        ys[i] = 0.5 + 0.4 * @sin(t);
        yb[i] = 0.0;
    }
    const light: z.plot.Style = .{
        .panel_bg = .{ .r = 246, .g = 246, .b = 249, .a = 255 },
        .bg = .{ .r = 252, .g = 252, .b = 254, .a = 255 },
        .grid = .{ .r = 205, .g = 205, .b = 214, .a = 255 },
        .minor_grid = .{ .r = 230, .g = 230, .b = 236, .a = 255 },
        .border = .{ .r = 120, .g = 120, .b = 132, .a = 255 },
        .text = .{ .r = 28, .g = 28, .b = 38, .a = 255 },
        .label = .{ .r = 60, .g = 60, .b = 72, .a = 255 },
        .legend_bg = .{ .r = 236, .g = 236, .b = 242, .a = 235 },
    };
    const series = [_]z.plot_ui.Series{
        .{
            .kind = .shaded,
            .xs = &xs,
            .ys = &ys,
            .shaded = .{ .y_ref = 0.0, .color = .{ .r = 33, .g = 150, .b = 243, .a = 90 } },
            .label = "sin",
        },
        .{
            .kind = .line,
            .xs = &xs,
            .ys = &ys,
            .spec = .{ .color = .{ .r = 33, .g = 150, .b = 243, .a = 255 } },
        },
    };
    z.plot_ui.show(u, &s.p_theme, .{ plot_w, plot_h - 40 }, &series, .{
        .title = "themeable",
        .x_label = "x",
        .y_label = "y",
        .style = if (s.theme_light) light else .{},
    });
}

fn tabGaps(u: ui.Ui, s: *State) void {
    u.text("non-finite samples (z.plot.missing) break the line / skip the point", .{});
    var xs: [120]f64 = undefined;
    var ys: [120]f64 = undefined;
    for (0..120) |i| {
        const t: f64 = float64(i) / 119.0 * 6.2831853;
        xs[i] = t;
        // Two windows of missing data become clean gaps in the curve + fill.
        if ((t > 1.5 and t < 2.3) or (t > 4.0 and t < 4.6)) {
            ys[i] = z.plot.missing;
        } else {
            ys[i] = @sin(t);
        }
    }
    const series = [_]z.plot_ui.Series{
        .{
            .kind = .shaded,
            .xs = &xs,
            .ys = &ys,
            .shaded = .{ .y_ref = 0.0, .color = .{ .r = 80, .g = 200, .b = 255, .a = 70 } },
            .label = "sin",
        },
        .{
            .kind = .line,
            .xs = &xs,
            .ys = &ys,
            .spec = .{
                .color = .{ .r = 80, .g = 200, .b = 255, .a = 255 },
                .thickness = 2,
                .marker = .circle,
                .marker_size = 3,
            },
        },
    };
    z.plot_ui.show(u, &s.p_gaps, .{ plot_w, plot_h - 40 }, &series, .{
        .title = "missing data = gaps",
        .x_label = "x",
        .y_label = "sin(x)",
    });
}

fn tabQuery(u: ui.Ui, s: *State) void {
    u.text("public query API: crosshair + live data coords drawn AFTER show()", .{});
    var xs: [60]f64 = undefined;
    var ys: [60]f64 = undefined;
    for (0..60) |i| {
        const t: f64 = float64(i) / 59.0 * 10.0;
        xs[i] = t;
        ys[i] = 50.0 + 40.0 * @sin(t);
    }
    const series = [_]z.plot_ui.Series{
        .{
            .kind = .line,
            .xs = &xs,
            .ys = &ys,
            .spec = .{ .color = .{ .r = 120, .g = 200, .b = 255, .a = 255 }, .thickness = 2 },
        },
    };
    z.plot_ui.show(u, &s.p_query, .{ plot_w, plot_h - 40 }, &series, .{
        .title = "query / crosshair",
        .x_label = "x",
        .y_label = "y",
    });

    // Everything below is app code using ONLY the public query API to draw a
    // custom overlay into the same window: a crosshair at the cursor plus the
    // cursor's position in DATA space (maps correctly under pan/zoom).
    const area: z.plot.Rect = s.p_query.plotArea();
    const m: Vec2 = u.getMousePos();
    if (s.p_query.isInside(m)) {
        var sink: z.plot_ui.DrawListSink = z.plot_ui.DrawListSink.fromUi(u) orelse return;
        const ch: Color = .{ .r = 255, .g = 220, .b = 120, .a = 170 };
        sink.line(.{ area.x, m[1] }, .{ area.right(), m[1] }, .{ .color = ch, .thickness = 1.0 });
        sink.line(.{ m[0], area.y }, .{ m[0], area.bottom() }, .{ .color = ch, .thickness = 1.0 });
        const dp: [2]f64 = s.p_query.getPlotMousePos();
        var buf: [64]u8 = undefined;
        const txt: []const u8 = bufPrint(&buf, "x={d:.2}  y={d:.2}", .{ dp[0], dp[1] }) catch "";
        sink.text(.{ m[0] + 8, m[1] - 18 }, txt, .{ .size = 13, .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 } });
    }
}

fn tabBoxZoom(u: ui.Ui, s: *State) void {
    u.text("drag a box to zoom into it; double-tap to re-fit", .{});
    var xs: [400]f64 = undefined;
    var ys: [400]f64 = undefined;
    for (0..400) |i| {
        const t: f64 = float64(i) / 399.0 * 20.0;
        xs[i] = t;
        // Fine structure so zooming actually reveals detail.
        ys[i] = @sin(t) + 0.25 * @sin(t * 7.0) + 0.08 * @sin(t * 31.0);
    }
    const series = [_]z.plot_ui.Series{
        .{
            .kind = .line,
            .xs = &xs,
            .ys = &ys,
            .spec = .{ .color = .{ .r = 150, .g = 230, .b = 160, .a = 255 } },
        },
    };
    z.plot_ui.show(u, &s.p_boxzoom, .{ plot_w, plot_h - 40 }, &series, .{
        .title = "box-zoom",
        .x_label = "t",
        .y_label = "f(t)",
        .box_zoom = true,
    });
}

fn tabLegend(u: ui.Ui, s: *State) void {
    _ = u.checkbox("horizontal legend", &s.legend_h);
    u.text("tap a legend entry to hide it; double-tap to solo (double-tap again to restore)", .{});
    var xs: [80]f64 = undefined;
    var y1: [80]f64 = undefined;
    var y2: [80]f64 = undefined;
    var y3: [80]f64 = undefined;
    var y4: [80]f64 = undefined;
    for (0..80) |i| {
        const t: f64 = float64(i) / 79.0 * 10.0;
        xs[i] = t;
        y1[i] = @sin(t);
        y2[i] = @cos(t);
        y3[i] = @sin(t * 0.5);
        y4[i] = 0.5 * @sin(t * 2.0);
    }
    const series = [_]z.plot_ui.Series{
        .{ .kind = .line, .xs = &xs, .ys = &y1, .spec = .{ .thickness = 2 }, .label = "sin" },
        .{ .kind = .line, .xs = &xs, .ys = &y2, .spec = .{ .thickness = 2 }, .label = "cos" },
        .{ .kind = .line, .xs = &xs, .ys = &y3, .spec = .{ .thickness = 2 }, .label = "sin/2" },
        .{ .kind = .line, .xs = &xs, .ys = &y4, .spec = .{ .thickness = 2 }, .label = "sin2x/2" },
    };
    z.plot_ui.show(u, &s.p_legend, .{ plot_w, plot_h - 40 }, &series, .{
        .title = "legend: solo + orientation",
        .x_label = "x",
        .y_label = "y",
        .legend_horizontal = s.legend_h,
        .legend_location = if (s.legend_h) .nw else .ne,
    });
}

fn tabImage(u: ui.Ui, s: *State) void {
    u.text("a GPU texture drawn in plot space (pan/zoom moves it with the axes)", .{});
    var xs: [48]f64 = undefined;
    var ys: [48]f64 = undefined;
    for (0..48) |i| {
        const t: f64 = float64(i) / 47.0 * 8.0;
        xs[i] = t;
        ys[i] = 4.0 + 3.0 * @sin(t);
    }
    const series = [_]z.plot_ui.Series{
        .{
            .kind = .image,
            .ys = &.{},
            .tex_id = s.img_tex,
            .img_bounds = .{ 1, 1, 7, 7 },
        },
        .{
            .kind = .line,
            .xs = &xs,
            .ys = &ys,
            .spec = .{ .color = .{ .r = 255, .g = 80, .b = 80, .a = 255 }, .thickness = 2 },
            .label = "signal",
        },
    };
    z.plot_ui.show(u, &s.p_image, .{ plot_w, plot_h - 40 }, &series, .{
        .title = "image in plot space",
        .x_label = "x",
        .y_label = "y",
    });
}

fn update(f: *z.Frame, s: *State) void {
    s.frame_count += 1;
    regen(s);

    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    if (u.window("zimr plot demo", .{
        .initial_pos = .{ 16, 16 },
        .initial_size = .{ 928, 688 },
    })) |w| {
        defer w.close();

        u.text("A growing showcase of the zimr plot library. Pan/drag, wheel or", .{});
        u.text("pinch to zoom, double-tap to fit, hover/touch for values.", .{});
        _ = u.checkbox("animate", &s.animate);
        u.separator();

        // Multi-row tab strip: a wrapping grid of selectables (the built-in
        // TabBar is single-row and overflows once there are many tabs).
        const tab_names = [_][]const u8{
            "Lines",   "Drag",    "Markers", "Shaded",
            "Stems",   "InfLine", "ErrBars", "Annot",
            "Heatmap", "Histo",   "Hist2D",  "Groups",
            "Band",    "HBars",   "Dual",    "Subplots",
            "Rect",    "Select",  "Time",    "Symlog",
            "AxisCfg", "Equal",   "Pie",     "Bubbles",
            "Candles", "Digital", "HeatLbl", "DualX",
            "Theme",   "Gaps",    "Query",   "BoxZoom",
            "Legend",  "Image",
        };
        const cols: usize = 4;
        const avail: f32 = u.getContentRegionAvail()[0];
        const cw: f32 = avail / float(cols) - 6;
        for (tab_names, 0..) |name, i| {
            if (i % cols != 0) {
                u.sameLine(.{});
            }
            if (u.selectable(name, i == s.current_tab, .{ .width = cw })) {
                s.current_tab = i;
            }
        }
        u.separator();
        switch (s.current_tab) {
            0 => tabLines(u, s),
            1 => tabDrag(u, s),
            2 => tabMarkers(u, s),
            3 => tabMore(u, s),
            4 => tabStems(u, s),
            5 => tabInfLines(u, s),
            6 => tabErrorBars(u, s),
            7 => tabAnnotations(u, s),
            8 => tabHeatmap(u, s),
            9 => tabHistogram(u, s),
            10 => tabHistogram2D(u, s),
            11 => tabBarGroups(u, s),
            12 => tabBand(u, s),
            13 => tabHBars(u, s),
            14 => tabDual(u, s),
            15 => tabSubplots(u, s),
            16 => tabDragRect(u, s),
            17 => tabSelect(u, s),
            18 => tabTime(u, s),
            19 => tabSymlog(u, s),
            20 => tabAxisCfg(u, s),
            21 => tabEqual(u, s),
            22 => tabPie(u, s),
            23 => tabBubbles(u, s),
            24 => tabCandles(u, s),
            25 => tabDigital(u, s),
            26 => tabHeatLabels(u, s),
            27 => tabDualX(u, s),
            28 => tabTheme(u, s),
            29 => tabGaps(u, s),
            30 => tabQuery(u, s),
            31 => tabBoxZoom(u, s),
            32 => tabLegend(u, s),
            33 => tabImage(u, s),
            else => {},
        }
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - plot demo",
            .width = screen_w,
            .height = screen_h,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
    .memory = .managed,
};
