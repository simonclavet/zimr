//! ui_minimal_button — port of the GL `ui_minimal_button` diagnostic. The
//! GL version used three separate UiContexts to probe font binding (no font /
//! TTF size 10 / TTF size 16); on wgpu the font path is settled (z.Font +
//! UiHost), so this becomes the same shape with a single UiHost driving three
//! windows, each a self-contained button + tap counter. If all three render
//! text and the buttons increment, multi-window UI + input routing work.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

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
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 28);
    s.* = .{ .ui_host = z.UiHost.init(gpa, font), .font = font };
}

fn update(f: *z.Frame, s: *State) void {
    z.clearViewport(f, .{ .r = 15, .g = 23, .b = 42, .a = 255 });
    const u: z.ui_real.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    // Tile three windows down the actual canvas (derived from f.window each
    // frame) so they always fit, whatever the device's responsive size is —
    // a fixed 880-tall layout overflowed shorter canvases.
    const fw: f32 = f.window.widthf();
    const fh: f32 = f.window.heightf();
    const margin: f32 = 8;
    const gap: f32 = 8;
    const win_w: f32 = fw - margin * 2;
    const win_h: f32 = (fh - margin * 2 - gap * 2) / 3;
    const y_a: f32 = margin;
    const y_b: f32 = margin + win_h + gap;
    const y_c: f32 = margin + (win_h + gap) * 2;

    u.setNextWindowPos(.{ margin, y_a }, .{});
    u.setNextWindowSize(.{ win_w, win_h }, .{});
    if (u.window("A - first window", .{})) |w| {
        defer w.close();
        u.text("Three windows tiled to the canvas, one UiHost.", .{});
        u.text("If you can read this, UI text works.", .{});
        u.separator();
        if (u.button("Tap me (A)", .{})) {
            s.taps_a += 1;
        }
        u.sameLine(.{});
        u.text("Taps: {d}", .{s.taps_a});
    }

    u.setNextWindowPos(.{ margin, y_b }, .{});
    u.setNextWindowSize(.{ win_w, win_h }, .{});
    if (u.window("B - second window", .{})) |w| {
        defer w.close();
        u.text("Each window owns its own button state.", .{});
        u.separator();
        if (u.button("Tap me (B)", .{})) {
            s.taps_b += 1;
        }
        u.sameLine(.{});
        u.text("Taps: {d}", .{s.taps_b});
    }

    u.setNextWindowPos(.{ margin, y_c }, .{});
    u.setNextWindowSize(.{ win_w, win_h }, .{});
    if (u.window("C - third window", .{})) |w| {
        defer w.close();
        u.text("Input routing picks the right window.", .{});
        u.text("Tapping C must not bump A or B.", .{});
        u.separator();
        if (u.button("Tap me (C)", .{})) {
            s.taps_c += 1;
        }
        u.sameLine(.{});
        u.text("Taps: {d}", .{s.taps_c});
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - minimal button",
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
