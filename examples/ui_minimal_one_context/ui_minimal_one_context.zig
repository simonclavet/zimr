//! ui_minimal_one_context — port of the GL `ui_minimal_one_context` onto
//! the WebGPU UI host. Three windows submitted through ONE UiHost (text +
//! button + tap counter each). Harness swap only; the widget body is unchanged.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const Bg: Color = .{ .r = 15, .g = 23, .b = 42, .a = 255 };

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,
    taps_a: u32 = 0,
    taps_b: u32 = 0,
    taps_c: u32 = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24);
    s.* = .{ .ui_host = z.UiHost.init(gpa, font), .font = font };
}

fn update(f: *z.Frame, s: *State) void {
    z.clearViewport(f, Bg);
    const u: z.ui_real.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    if (u.window("Window A", .{
        .initial_pos = .{ 8, 8 },
        .initial_size = .{ 380, 260 },
    })) |w| {
        defer w.close();
        u.text("ONE-context test, window A.", .{});
        u.text("If text appears here, baseline works in one context.", .{});
        if (u.button("Tap me (A)", .{})) {
            s.taps_a += 1;
        }
        u.text("Tap count: {d}", .{s.taps_a});
    }

    if (u.window("Window B", .{
        .initial_pos = .{ 8, 280 },
        .initial_size = .{ 380, 260 },
    })) |w| {
        defer w.close();
        u.text("Second window in the same context.", .{});
        u.text("If A renders but B is blank, context corruption.", .{});
        if (u.button("Tap me (B)", .{})) {
            s.taps_b += 1;
        }
        u.text("Tap count: {d}", .{s.taps_b});
    }

    if (u.window("Window C", .{
        .initial_pos = .{ 8, 560 },
        .initial_size = .{ 380, 280 },
    })) |w| {
        defer w.close();
        u.text("Third window in the same context.", .{});
        u.text("Now we have N widgets submitted in this one context.", .{});
        if (u.button("Tap me (C)", .{})) {
            s.taps_c += 1;
        }
        u.text("Tap count: {d}", .{s.taps_c});
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - minimal one-context",
            .width = 400,
            .height = 880,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
