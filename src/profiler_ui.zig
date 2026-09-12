//! lint:alias profiler_ui
//! profiler_ui.zig — app-callable views for the integrated profiler.
//!
//! The profiler is APP-DRIVEN: it does not grab input or impose a hotkey. The
//! app wires its own button, decides when to pause its simulation, calls
//! `profiler.freeze()`/`unfreeze()`, and renders these views inside its own ui
//! window. Typical use, on a "Profiler" button press:
//!
//!     if (toggled) { paused = !paused;
//!         if (paused) z.profiler.freeze() else z.profiler.unfreeze(); }
//!     if (!paused) { ...step simulation... }
//!     ...draw scene...
//!     if (paused) {
//!         const u = host.begin(f);          // a ui window
//!         z.profiler_ui.panel(u);
//!         host.render(f);
//!     }
//!
//! Collection lives in profiler.zig; this file only reads those buffers and
//! draws with ui.zig's DrawList. Folds to nothing when the profiler is stripped.

const profiler = @import("profiler.zig");
const std = @import("std");
const ui = @import("ui.zig");
const zm = @import("zm");
const float64 = zm.float64;
const float = zm.float;

const Ui = ui.Ui;
const Rectangle = ui.Rectangle;
const DrawListHandle = ui.DrawListHandle;
const Color = zm.Color;
const Vec2 = zm.Vec2;
const Frame = profiler.Frame;
const SourceLoc = profiler.SourceLoc;
const ZoneIter = profiler.ZoneIter;

const row_h: f32 = 18;
const text_col: Color = .{ .r = 255, .g = 255, .b = 255, .a = 235 };
const bg_col: Color = .{ .r = 20, .g = 22, .b = 28, .a = 180 };
const border_col: Color = .{ .r = 0, .g = 0, .b = 0, .a = 90 };
const hover_col: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
const strip_bg: Color = .{ .r = 16, .g = 18, .b = 24, .a = 200 };
const strip_ok: Color = .{ .r = 112, .g = 173, .b = 71, .a = 255 };
const strip_over: Color = .{ .r = 224, .g = 96, .b = 70, .a = 255 };
const strip_worst: Color = .{ .r = 255, .g = 235, .b = 120, .a = 255 };
const budget_line: Color = .{ .r = 180, .g = 180, .b = 180, .a = 90 };
const hist_col: Color = .{ .r = 90, .g = 170, .b = 220, .a = 255 };

const no_sel: u32 = 0xFFFFFFFF;
var selected_src: u32 = no_sel; // lint:off module-var: find-zone histogram selection

// Stable per-call-site fills (indexed by interned src id). Tracy-ish hues.
const palette = [_]Color{
    .{ .r = 91, .g = 155, .b = 213, .a = 255 },
    .{ .r = 112, .g = 173, .b = 71, .a = 255 },
    .{ .r = 237, .g = 125, .b = 49, .a = 255 },
    .{ .r = 165, .g = 105, .b = 189, .a = 255 },
    .{ .r = 76, .g = 175, .b = 178, .a = 255 },
    .{ .r = 224, .g = 96, .b = 130, .a = 255 },
    .{ .r = 158, .g = 180, .b = 70, .a = 255 },
    .{ .r = 99, .g = 120, .b = 210, .a = 255 },
    .{ .r = 211, .g = 158, .b = 56, .a = 255 },
    .{ .r = 120, .g = 170, .b = 120, .a = 255 },
    .{ .r = 188, .g = 92, .b = 92, .a = 255 },
    .{ .r = 130, .g = 140, .b = 160, .a = 255 },
    .{ .r = 86, .g = 180, .b = 233, .a = 255 },
    .{ .r = 200, .g = 130, .b = 200, .a = 255 },
};

fn zoneColor(src_id: u32) Color {
    return palette[src_id % palette.len];
}

/// Draw the flamegraph (icicle: time on x, depth downward) for one frame at the
/// current cursor, filling the available content width. Call inside a ui window.
pub fn flamegraph(u: Ui, frame: Frame) void {
    if (!profiler.enabled) {
        return;
    }
    const avail: Vec2 = u.getContentRegionAvail();
    const origin: Vec2 = u.getCursorScreenPos();
    const w: f32 = avail[0];
    if (w <= 1) {
        return;
    }

    // pass 1: depth extent + the actual work span (so the bar fills the width
    // rather than leaving the post-work idle time as dead space).
    var max_depth: u16 = 0;
    var t_lo: f64 = 0;
    var t_hi: f64 = 0;
    var have: bool = false;
    var it: ZoneIter = profiler.frameZones(frame);
    while (it.next()) |z| {
        if (z.depth > max_depth) {
            max_depth = z.depth;
        }
        if (!have or z.t0 < t_lo) {
            t_lo = z.t0;
        }
        if (!have or z.t1 > t_hi) {
            t_hi = z.t1;
        }
        have = true;
    }

    const rows_i: u32 = @as(u32, max_depth) + 1;
    const rows: f32 = float(rows_i);
    const h: f32 = row_h * rows + 6;
    u.dummy(.{ w, h });

    const dl: DrawListHandle = u.getWindowDrawList();
    dl.addRectFilled(.{ .x = origin[0], .y = origin[1], .width = w, .height = h }, bg_col);
    if (!have) {
        dl.addText("no frame data", .{ origin[0] + 6, origin[1] + 6 }, 13, text_col);
        return;
    }
    const span: f64 = t_hi - t_lo;
    if (span <= 0) {
        return;
    }

    const mouse: Vec2 = u.getMousePos();
    var it2: ZoneIter = profiler.frameZones(frame);
    while (it2.next()) |z| {
        const fx0: f32 = @floatCast((z.t0 - t_lo) / span);
        const fx1: f32 = @floatCast((z.t1 - t_lo) / span);
        const x0: f32 = origin[0] + fx0 * w;
        var x1: f32 = origin[0] + fx1 * w;
        if (x1 - x0 < 1) {
            x1 = x0 + 1;
        }
        const depth_f: f32 = float(z.depth);
        const y0: f32 = origin[1] + row_h * depth_f;
        const rh: f32 = row_h - 1;
        const rect: Rectangle = .{ .x = x0, .y = y0, .width = x1 - x0, .height = rh };
        dl.addRectFilled(rect, zoneColor(z.src));

        const hovered: bool = mouse[0] >= x0 and mouse[0] <= x1 and
            mouse[1] >= y0 and mouse[1] <= y0 + rh;
        var oc: Color = border_col;
        if (hovered) {
            oc = hover_col;
        }
        dl.addRectOutline(rect, oc);

        const loc: SourceLoc = profiler.srcOf(z.src);
        if (x1 - x0 > 26) {
            dl.addText(loc.name, .{ x0 + 3, y0 + 2 }, 12, text_col);
        }
        if (hovered) {
            const dur_ms: f64 = z.t1 - z.t0;
            u.setTooltip("{s}  {d:.3} ms", .{ loc.name, dur_ms });
        }
    }
}

/// The default profiler view: a header line plus the flamegraph of the WORST
/// frame in the rolling ~2s window (the hitch). Call inside a ui window; the
/// app owns the surrounding button / pause / freeze.
fn statGreater(_: void, a: profiler.SrcStat, b: profiler.SrcStat) bool {
    return a.total_ms > b.total_ms;
}

/// A horizontal history of recent frame durations (newest at the right), green
/// under the 60fps budget, red over it, with a budget guide line. The worst
/// frame's bar is tinted so you can see where the hitch sits in the window.
pub fn frameStrip(u: Ui) void {
    if (!profiler.enabled) {
        return;
    }
    const fc: usize = profiler.frameCount();
    if (fc == 0) {
        return;
    }
    const avail: Vec2 = u.getContentRegionAvail();
    const origin: Vec2 = u.getCursorScreenPos();
    const w: f32 = avail[0];
    const h: f32 = 44;
    u.dummy(.{ w, h });
    const dl: DrawListHandle = u.getWindowDrawList();
    dl.addRectFilled(.{ .x = origin[0], .y = origin[1], .width = w, .height = h }, strip_bg);

    const budget_ms: f64 = 1000.0 / 60.0;
    const max_bars: usize = 180;
    const shown: usize = @min(fc, max_bars);
    const shown_f: f32 = float(shown);
    const bw: f32 = w / shown_f;

    var worst_dur: f64 = budget_ms * 1.2;
    var worst_i: usize = 0;
    var i: usize = 0;
    while (i < shown) : (i += 1) {
        if (profiler.frameAt(i)) |f| {
            if (f.dur > worst_dur) {
                worst_dur = f.dur;
                worst_i = i;
            }
        }
    }
    const inner_h: f32 = h - 4;
    i = 0;
    while (i < shown) : (i += 1) {
        const f: profiler.Frame = profiler.frameAt(i) orelse continue;
        const xi: usize = shown - 1 - i; // newest at the right
        const xi_f: f32 = float(xi);
        const x0: f32 = origin[0] + xi_f * bw;
        const frac: f32 = @floatCast(f.dur / worst_dur);
        const bh: f32 = @min(frac, 1.0) * inner_h;
        const y1: f32 = origin[1] + h - 2;
        var col: Color = strip_ok;
        if (i == worst_i) {
            col = strip_worst;
        } else if (f.dur > budget_ms) {
            col = strip_over;
        }
        dl.addRectFilled(.{ .x = x0, .y = y1 - bh, .width = @max(bw - 1, 1), .height = bh }, col);
    }
    const by: f32 = origin[1] + h - 2 - @as(f32, @floatCast(budget_ms / worst_dur)) * inner_h;
    dl.addLine(.{ origin[0], by }, .{ origin[0] + w, by }, budget_line, 1);
}

/// Per-zone statistics across the rolling window, ranked by total time — the
/// "what to optimise" report. Steadier than one frame, and it surfaces phases
/// too thin to read in the flamegraph at coarse timer resolution.
pub fn statsTable(u: Ui) void {
    if (!profiler.enabled) {
        return;
    }
    var buf: [128]profiler.SrcStat = undefined;
    const n: usize = profiler.aggregate(&buf);
    if (n == 0) {
        u.text("no data yet", .{});
        return;
    }
    std.mem.sort(profiler.SrcStat, buf[0..n], {}, statGreater);

    if (u.beginTable("prof_stats", 5, .{})) {
        u.tableSetupColumn("zone", .{});
        u.tableSetupColumn("count", .{});
        u.tableSetupColumn("total ms", .{});
        u.tableSetupColumn("mean ms", .{});
        u.tableSetupColumn("max ms", .{});
        u.tableHeadersRow();
        var r: usize = 0;
        while (r < n) : (r += 1) {
            const st: profiler.SrcStat = buf[r];
            if (st.count == 0) {
                break; // zero-count rows sorted to the bottom
            }
            const count_f: f64 = float64(st.count);
            const mean: f64 = st.total_ms / count_f;
            const name: []const u8 = profiler.srcOf(st.src).name;
            u.tableNextRow();
            _ = u.tableNextColumn();
            if (u.selectable(name, st.src == selected_src, .{})) {
                selected_src = if (st.src == selected_src) no_sel else st.src;
            }
            _ = u.tableNextColumn();
            u.text("{d}", .{st.count});
            _ = u.tableNextColumn();
            u.text("{d:.3}", .{st.total_ms});
            _ = u.tableNextColumn();
            u.text("{d:.3}", .{mean});
            _ = u.tableNextColumn();
            u.text("{d:.3}", .{st.max_ms});
        }
        u.endTable();
    }
    if (selected_src != no_sel) {
        u.separator();
        zoneHistogram(u, selected_src);
    }
}

/// Find-zone view: the per-frame distribution of one selected call site across the
/// window. A tall single bar means the zone is steady; a long tail means it spikes.
fn zoneHistogram(u: Ui, src: u32) void {
    if (!profiler.enabled) {
        return;
    }
    var series: [256]f64 = undefined;
    const n: usize = profiler.frameSeriesFor(src, &series);
    if (n == 0) {
        return;
    }
    var lo: f64 = series[0];
    var hi: f64 = series[0];
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (series[i] < lo) {
            lo = series[i];
        }
        if (series[i] > hi) {
            hi = series[i];
        }
    }
    if (hi <= lo) {
        hi = lo + 0.001;
    }
    const name: []const u8 = profiler.srcOf(src).name;
    u.text("{s}  per-frame {d:.3} - {d:.3} ms  ({d} frames)", .{ name, lo, hi, n });

    const bins: usize = 24;
    var counts: [24]u32 = @splat(0);
    var maxc: u32 = 1;
    i = 0;
    while (i < n) : (i += 1) {
        const frac: f64 = (series[i] - lo) / (hi - lo);
        const scaled: f64 = frac * float64(bins);
        var bi: usize = @intFromFloat(scaled);
        if (bi >= bins) {
            bi = bins - 1;
        }
        counts[bi] += 1;
        if (counts[bi] > maxc) {
            maxc = counts[bi];
        }
    }

    const avail: Vec2 = u.getContentRegionAvail();
    const origin: Vec2 = u.getCursorScreenPos();
    const width: f32 = avail[0];
    const height: f32 = 70;
    u.dummy(.{ width, height });
    const dl: DrawListHandle = u.getWindowDrawList();
    dl.addRectFilled(.{ .x = origin[0], .y = origin[1], .width = width, .height = height }, strip_bg);
    const bin_w: f32 = width / float(bins);
    const maxc_f: f32 = float(maxc);
    var b: usize = 0;
    while (b < bins) : (b += 1) {
        const cf: f32 = float(counts[b]);
        const bar_h: f32 = (cf / maxc_f) * (height - 4);
        const bf: f32 = float(b);
        const x0: f32 = origin[0] + bf * bin_w;
        const y_base: f32 = origin[1] + height - 2;
        const bw_draw: f32 = @max(bin_w - 1, 1);
        dl.addRectFilled(.{ .x = x0, .y = y_base - bar_h, .width = bw_draw, .height = bar_h }, hist_col);
    }
}

/// The default profiler view: header + frame strip, then a tab bar with the
/// worst-frame flamegraph and the window statistics. Call inside a ui window;
/// the app owns the surrounding button / pause / freeze.
pub fn panel(u: Ui) void {
    if (!profiler.enabled) {
        return;
    }
    const wf: ?Frame = profiler.worstFrame();
    if (wf == null) {
        u.text("profiler: recording, no frames yet", .{});
        return;
    }
    const frame: Frame = wf.?;
    const fps: f64 = if (frame.dur > 0) 1000.0 / frame.dur else 0;
    const res_us: f64 = profiler.timerResolutionMs() * 1000.0;
    u.text("worst frame in last 2s: {d:.2} ms  ({d:.0} fps)   timer ~{d:.0}us", .{ frame.dur, fps, res_us });
    const gpu_mean: f64 = profiler.gpuMsMean();
    if (gpu_mean > 0) {
        u.text("CPU ~{d:.2} ms   GPU ~{d:.2} ms", .{ profiler.frameMeanMs(), gpu_mean });
    }
    if (profiler.autoFroze()) {
        u.text("** auto-froze on a spike **", .{});
    }
    frameStrip(u);
    if (u.beginTabBar("prof_tabs", .{})) {
        if (u.beginTabItem("Flamegraph", null, .{})) {
            flamegraph(u, frame);
            u.endTabItem();
        }
        if (u.beginTabItem("Statistics", null, .{})) {
            statsTable(u);
            u.endTabItem();
        }
        u.endTabBar();
    }
}
