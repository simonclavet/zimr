//! monitors - the monitors the platform reports (`z.monitorCount`, `z.monitor`, `z.currentMonitor`): each one's name,
//! where it sits on the desktop and its size in its own logical pixels, its scale and its refresh rate; the primary
//! marked, and the one holding the window highlighted. Move the window to another monitor and the highlight follows.
//! A page sees a single monitor, its screen, and cannot tell its refresh rate.
//!
//! In a window, keys place it: a digit centers the window on that monitor, M minimizes it, X maximizes it, R restores
//! it, and L limits its size to 480 by 320 at least and 1200 by 800 at most - pressed again, it lifts the limits. A
//! page cannot do any of these, so the keys are read only where there is a window to place.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const float = zm.float;

const State = struct {
    font: z.Font,
    is_size_limited: bool = false,
};

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 18);
    s.* = .{ .font = font };
}

/// The keys that place the window, on platforms with a window to place.
fn placeWindow(f: *z.Frame, s: *State) void {
    const digit_keys = [_]z.KeyboardKey{ .one, .two, .three, .four, .five, .six, .seven, .eight, .nine };
    for (digit_keys, 0..) |digit_key, monitor_index| {
        if (z.isKeyPressed(f.input, digit_key)) {
            const target: z.Monitor = z.monitor(@intCast(monitor_index)) orelse continue;
            const window_width: f32 = f.window.widthf();
            const window_height: f32 = f.window.heightf();
            const left: f32 = @max((target.width - window_width) / 2, 0);
            const top: f32 = @max((target.height - window_height) / 2, 0);
            z.setWindowPosition(@intCast(monitor_index), left, top);
        }
    }
    if (z.isKeyPressed(f.input, .m)) {
        z.showWindow(.minimized);
    }
    if (z.isKeyPressed(f.input, .x)) {
        z.showWindow(.maximized);
    }
    if (z.isKeyPressed(f.input, .r)) {
        z.showWindow(.normal);
    }
    if (z.isKeyPressed(f.input, .l)) {
        s.is_size_limited = !s.is_size_limited;
        const limits: z.SizeLimits = if (s.is_size_limited) .{
            .min_width = 480,
            .min_height = 320,
            .max_width = 1200,
            .max_height = 800,
        } else .{};
        z.setWindowSizeLimits(limits);
    }
}

fn update(f: *z.Frame, s: *State) void {
    if (comptime !z.host.is_browser) {
        placeWindow(f, s);
    }
    z.clearViewport(f, .{ .r = 24, .g = 26, .b = 34, .a = 255 });
    const white: Color = .{ .r = 240, .g = 240, .b = 240, .a = 255 };
    const dim: Color = .{ .r = 150, .g = 150, .b = 160, .a = 255 };
    const accent: Color = .{ .r = 96, .g = 165, .b = 250, .a = 255 };
    const monitor_count: u32 = z.monitorCount();
    const current_index: u32 = z.currentMonitor();
    f.gl.textf(
        .{ 24, 24 },
        "{d} monitor(s); the window is on monitor {d}",
        .{ monitor_count, current_index },
        .{ .size = 20, .color = white, .font = &s.font },
    );
    var index: u32 = 0;
    while (index < monitor_count) : (index += 1) {
        const described: z.Monitor = z.monitor(index) orelse break;
        const line_y: f32 = 72 + float(index) * 64;
        const is_current: bool = index == current_index;
        const marker: []const u8 = if (is_current) "> " else "  ";
        const primary_note: []const u8 = if (described.is_primary) ", primary" else "";
        const name_color: Color = if (is_current) accent else white;
        f.gl.textf(
            .{ 24, line_y },
            "{s}{d}: {s}{s}",
            .{ marker, index, described.name(), primary_note },
            .{ .size = 18, .color = name_color, .font = &s.font },
        );
        const detail_format: []const u8 = "    at ({d:.0}, {d:.0}), {d:.0} x {d:.0}, scale {d:.2}, {d:.0} Hz";
        f.gl.textf(
            .{ 24, line_y + 26 },
            detail_format,
            .{
                described.x,
                described.y,
                described.width,
                described.height,
                described.scale,
                described.refresh_hz,
            },
            .{ .size = 16, .color = dim, .font = &s.font },
        );
    }
    if (comptime !z.host.is_browser) {
        const help: []const u8 = if (s.is_size_limited)
            "1-9: center on a monitor   M minimize   X maximize   R restore   L lift the size limits"
        else
            "1-9: center on a monitor   M minimize   X maximize   R restore   L limit the size";
        f.gl.text(.{ 24, f.window.heightf() - 36 }, help, .{ .size = 15, .color = dim, .font = &s.font });
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - monitors",
            .width = 720,
            .height = 400,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
