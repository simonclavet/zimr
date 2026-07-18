// examples/ui_mini_plot_smoke.zig
//
// Throwaway validation tool for the architectural pillars.
// Renders a single line plot using `u.miniPlot` so we can see
// with our own eyes that canvas + arcs + state + style + input
// + animation actually compose without surprises.
//
// **This file will be deleted when real `beginPlot` lands.**
//
// Generates a synthetic time-series each frame: a sine wave
// whose amplitude grows over the first few seconds.  This
// exercises:
//   - Auto-fit on the first frame
//   - The spring animation between old and new Y limits as the
//     amplitude grows
//   - The R-key reset path (press R to force refit)
//
// Not a phone example; the keyboard reset is desktop-only.
//
// Build:
//   zig build install -Dfocus=ui_mini_plot_smoke

const std = @import("std");
const zm = @import("zm");
const float = zm.float;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const ui = z.ui_real;

const samples: usize = 128;

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,

    elapsed: f32 = 0,
    xs: [samples]f32 = blk: {
        var arr: [samples]f32 = undefined;
        for (&arr, 0..) |*v, i| {
            v.* = @floatFromInt(i);
        }
        break :blk arr;
    },
    ys: [samples]f32 = @splat(0),
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, @embedFile("atkinson_mono_ttf"), 22);
    s.* = .{ .ui_host = z.UiHost.init(gpa, font), .font = font };
}

fn update(f: *z.Frame, s: *State) void {
    z.clearViewport(f, .{ .r = 18, .g = 22, .b = 32, .a = 255 });

    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    s.elapsed += u.ctx.input.delta_time;

    // Amplitude ramps from 1 to 10 over the first 6 seconds,
    // then sits at 10.  The miniPlot's auto-fit limits should
    // grow with it; the spring animation produces a visible
    // smooth zoom-out as the new max settles.
    const amp: f32 = @min(1.0 + s.elapsed * 1.5, 10.0);
    for (&s.ys, 0..) |*y, i| {
        const t: f32 = float(i) * 0.1;
        y.* = amp * @sin(t + s.elapsed);
    }

    if (u.window("miniPlot smoke", .{
        .initial_pos = .{ 10, 10 },
        .initial_size = .{ 780, 460 },
    })) |w| {
        defer w.close();

        u.text("amplitude grows from 1.0 to 10.0 over 6s. press R to reset auto-fit.", .{});
        u.separator();

        // The plot lives in its own rect inside the window.
        const r: ui.Rectangle = .{ .x = 0, .y = 0, .width = 720, .height = 320 };
        const did_reset: bool = u.miniPlot("trace", r, &s.xs, &s.ys);
        if (did_reset) {
            u.text("(R-key edge fired this frame)", .{});
        }
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - miniPlot smoke test",
            .width = 800,
            .height = 480,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
