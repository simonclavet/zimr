// examples/hello_world.zig - a first look at zimr.
// Renders "Hello, World!" with the default font, a circle that
// follows the mouse (or a finger), and a UI window whose slider
// sets the circle's radius: text, shapes, input and immediate-mode
// UI, each in a few lines.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const Vec2 = zm.Vec2;
const float = zm.float;

const State = struct {
    font: z.Font,
    /// The immediate-mode UI (`z.ui_real`): it keeps what the UI remembers between frames - where its windows are,
    /// which widget is being dragged.
    ui_host: z.UiHost,
    /// The circle's radius in CSS pixels, set by the UI's slider.
    circle_radius: f32 = 30,
};

/// User-owned framework integration point.  See `examples/basic.zig`
/// for the canonical comment block; this declaration is the
/// AppBridge pattern's required convention.
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

fn deinit(gpa: Allocator, s: *State) void {
    s.ui_host.deinit();
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 32);
    s.* = .{
        .font = font,
        .ui_host = z.UiHost.init(gpa, font),
    };
}

fn update(f: *z.Frame, s: *State) void {
    z.clearViewport(f, .{ .r = 30, .g = 30, .b = 40, .a = 255 });

    // The UI is built first, so its answer to "is the mouse over me?" is known before the scene uses the mouse; it
    // is drawn last (`render`, below), on top of everything.
    const u: z.ui_real.Ui = s.ui_host.begin(f);
    if (u.window("Circle", .{})) |w| {
        defer w.close();
        _ = u.slider("radius", &s.circle_radius, .{ .min = 4, .max = 120, .fmt = "{d:.0} px" });
    }
    const is_mouse_on_ui: bool = u.wantCaptureMouse();

    // Responsive coord space - these update on resize / rotation
    // and the runtime's per-frame ortho reset keeps draw coords
    // 1:1 with CSS pixels.  See zimr.zig per-frame size block.
    const sw: f32 = f.window.widthf();
    const sh: f32 = f.window.heightf();
    const cx: f32 = sw / 2;
    const cy: f32 = sh / 2;

    const white: Color = .{ .r = 240, .g = 240, .b = 240, .a = 255 };
    const dim: Color = .{ .r = 140, .g = 140, .b = 150, .a = 255 };
    const accent: Color = .{ .r = 96, .g = 165, .b = 250, .a = 255 };

    // Concentric rectangles centred in the canvas.  Smallest
    // dimension caps their size so they stay square-ish on any
    // aspect ratio (phone portrait, phone landscape, desktop wide).
    const min_dim: f32 = @min(sw, sh);
    var i: i32 = 1;
    while (i <= 4) : (i += 1) {
        const half: f32 = min_dim * float(i) / 12.0;
        const rec: z.Rectangle = .{
            .x = cx - half,
            .y = cy - half,
            .width = 2 * half,
            .height = 2 * half,
        };
        f.gl.rect(
            .{ .x = rec.x, .y = rec.y, .width = rec.width, .height = rec.height },
            .{ .color = accent, .outline = 2 },
        );
    }

    f.gl.text(.{ cx - 90, cy - 18 }, "Hello, World!", .{ .size = 32, .color = white, .font = &s.font });

    f.gl.textf(
        .{ cx - 110, cy + 30 },
        "viewport: {d} x {d} CSS px",
        .{ sw, sh },
        .{ .size = 14, .color = dim, .font = &s.font },
    );

    f.gl.text(
        .{ 16, sh - 24 },
        "move the mouse; drag the slider to resize the circle",
        .{ .size = 12, .color = dim, .font = &s.font },
    );

    // The circle at the mouse - but not while the mouse is on the UI window, where it would cover the slider.
    if (!is_mouse_on_ui) {
        const mouse: Vec2 = z.getMousePosition(f.input);
        const circle_color: Color = .{ .r = 250, .g = 180, .b = 60, .a = 200 };
        f.gl.circle(mouse, s.circle_radius, .{ .color = circle_color });
        f.gl.circle(mouse, s.circle_radius, .{ .color = white, .outline = 2 });
    }

    s.ui_host.render(f);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - hello_world",
            .width = 640,
            .height = 400,
            // Logical coordinate space tracks the canvas's CSS
            // pixels - runtime resets `rlOrtho` each frame so
            // draw coords are 1:1 with `f.window.screen_width`.
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
