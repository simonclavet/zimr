// examples/ui_demo/ui_demo.zig
//
// The simplest possible test of the REAL ui.zig (Dear ImGui) on the WebGPU
// backend: a dark background + one ImGui window with a label, a slider, a
// checkbox, and a button (with a click counter). No fractal, no scene — just
// the UI, so any UI rendering issue is isolated here.
//
// Build:      zig build wgpu-ui-demo
// Standalone: zig build wgpu-ui-demo-standalone

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");

const roboto_mono_ttf = @embedFile("roboto_mono_ttf");

const width: u32 = 800;
const height: u32 = 600;

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,
    slider_val: f32,
    checked: bool,
    clicks: i32,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, roboto_mono_ttf, 28);
    s.* = .{
        .ui_host = z.UiHost.init(gpa, font),
        .font = font,
        .slider_val = 0.5,
        .checked = true,
        .clicks = 0,
    };
}

fn update(f: *z.Frame, s: *State) void {
    z.clearViewport(f, .{ .r = 16, .g = 18, .b = 26, .a = 255 });

    const ui: z.ui_real.Ui = s.ui_host.begin(f);
    if (ui.window("Hello ImGui", .{
        .initial_pos = .{ 60, 60 },
        .initial_size = .{ 320, 240 },
    })) |w| {
        defer w.close();
        ui.text("The real ui.zig, on WebGPU.", .{});
        ui.text("clicks: {d}", .{s.clicks});
        _ = ui.slider("value", &s.slider_val, .{ .min = 0, .max = 1 });
        _ = ui.checkbox("enabled", &s.checked);
        if (ui.button("click me", .{})) {
            s.clicks += 1;
        }
    }
    s.ui_host.render(f);

    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - UI demo (real ImGui)",
            .width = width,
            .height = height,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
