// examples/ui_plot/ui_plot.zig — interactive plotting demo.
//
// An ImPlot-style plot living inside a real zimr frame: a live sine and
// damped-cosine driven by sliders, with drag-to-pan and wheel-zoom on the
// plot area, and a "Fit" button to re-frame the data. Renders through
// `z.plot_ui` -> `ui.DrawList` -> the WebGPU pipeline, so it is fully
// interactive on the web — the thing a static image can't be.

const std = @import("std");
const zm = @import("zm");
const float64 = zm.float64;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const ui = z.ui_real;

const screen_w: i32 = 900;
const screen_h: i32 = 640;
const n_samples: usize = 160;

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,
    plot: z.plot_ui.PlotState = .{},

    // Live signal controls.
    freq: f32 = 1.0,
    amp: f32 = 1.0,
    show_markers: bool = false,
    frame_count: u64 = 0,

    // Per-frame data buffers.
    xs: [n_samples]f64 = undefined,
    sine: [n_samples]f64 = undefined,
    damp: [n_samples]f64 = undefined,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, @embedFile("atkinson_mono_ttf"), 22);
    s.* = .{ .ui_host = z.UiHost.init(gpa, font), .font = font };
}

fn regen(s: *State) void {
    const phase: f64 = float64(s.frame_count) * 0.03;
    const freq: f64 = s.freq;
    const amp: f64 = s.amp;
    var i: usize = 0;
    while (i < n_samples) : (i += 1) {
        const t: f64 = float64(i) / @as(f64, n_samples - 1) * 10.0;
        s.xs[i] = t;
        s.sine[i] = @sin(t * freq + phase) * amp;
        s.damp[i] = @exp(-t * 0.25) * @cos(t * 2.0 * freq + phase) * amp;
    }
}

fn update(f: *z.Frame, s: *State) void {
    s.frame_count += 1;
    regen(s);

    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    if (u.window("Interactive plot", .{
        .initial_pos = .{ 20, 20 },
        .initial_size = .{ 860, 600 },
    })) |w| {
        defer w.close();

        u.text("Drag to pan, wheel to zoom. Sliders animate the signal.", .{});
        u.separator();

        const marker: z.plot.Marker = if (s.show_markers) .circle else .none;
        const series = [_]z.plot_ui.Series{
            .{
                .kind = .shaded,
                .xs = &s.xs,
                .ys = &s.sine,
                .shaded = .{ .color = .{ .r = 33, .g = 150, .b = 243, .a = 45 }, .y_ref = 0 },
            },
            .{
                .kind = .line,
                .xs = &s.xs,
                .ys = &s.sine,
                .spec = .{ .marker = marker, .marker_size = 2.5, .color = .{ .r = 33, .g = 150, .b = 243, .a = 255 } },
                .label = "sine",
            },
            .{
                .kind = .line,
                .xs = &s.xs,
                .ys = &s.damp,
                .spec = .{ .color = .{ .r = 244, .g = 67, .b = 54, .a = 255 } },
                .label = "damped cos",
            },
        };
        z.plot_ui.show(u, &s.plot, .{ 820, 380 }, &series, .{
            .title = "live signal",
            .interactive = true,
        });

        u.separator();
        _ = u.slider("frequency", &s.freq, .{ .min = 0.2, .max = 4.0, .fmt = "{d:.2}" });
        _ = u.slider("amplitude", &s.amp, .{ .min = 0.2, .max = 3.0, .fmt = "{d:.2}" });
        _ = u.checkbox("markers", &s.show_markers);
        if (u.button("Fit", .{})) {
            s.plot.fitted = false; // request a re-fit next frame
        }
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - interactive plot",
            .width = screen_w,
            .height = screen_h,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
