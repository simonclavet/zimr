//! ui_smoke_button — port of the GL `ui_smoke_button` onto the WebGPU UI
//! host. One window, one text line, one button: the minimal UI text+button path.
//! Harness swap only (UiContext+shapes_texture+font_cache → z.UiHost); the widget
//! body is the same real ui.zig.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,
    counter: i32 = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 28);
    s.* = .{ .ui_host = z.UiHost.init(gpa, font), .font = font };
}

fn update(f: *z.Frame, s: *State) void {
    z.clearViewport(f, .{ .r = 15, .g = 23, .b = 42, .a = 255 });
    const u: z.ui_real.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    if (u.window("Smoke", .{
        .initial_pos = .{ 20, 20 },
        .initial_size = .{ 440, 280 },
    })) |w| {
        defer w.close();
        u.text("Hello.", .{});
        u.text("If you can read this, UI text works.", .{});
        u.separator();
        if (u.button("Tap me", .{})) {
            s.counter += 1;
        }
        u.sameLine(.{});
        u.text("Taps: {d}", .{s.counter});
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - UI smoke (button)",
            .width = 480,
            .height = 320,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
