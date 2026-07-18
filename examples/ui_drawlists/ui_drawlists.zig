//! ui_drawlists — port of the GL `ui_drawlists` onto the WebGPU UI host.
//! Background + foreground draw lists (imgui's GetBackground/GetForegroundDrawList):
//! the background grid renders UNDER every window, the corner watermark renders
//! ABOVE them. Drag the control window — the grid stays under it, the watermark
//! over it.
//!
//! Review note vs the GL original: it wrote raw packed hex (e.g. `0xFFEF4444`),
//! but ColorU32 is 0xAABBGGRR (R in the low byte), so that literal is actually
//! BLUE, not the red the name implied. Here colors are named `Color` literals
//! packed through `colorToU32` — explicit RGBA, no byte-order trap, and the
//! constant ones fold at comptime so there's no per-call cost.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const Vec2 = zm.Vec2;
const clamp = zm.clamp;
const ui = z.ui_real;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const backdrop: Color = .{ .r = 15, .g = 23, .b = 42, .a = 255 }; // slate-900
const grid_rgb: Color = .{ .r = 203, .g = 213, .b = 225, .a = 255 }; // slate-300 (alpha set per frame)
const accent: Color = .{ .r = 239, .g = 68, .b = 68, .a = 255 }; // red-500
const accent_dim: Color = .{ .r = 239, .g = 68, .b = 68, .a = 153 };
const accent_faint: Color = .{ .r = 239, .g = 68, .b = 68, .a = 102 };
const panel_bg: Color = .{ .r = 15, .g = 23, .b = 42, .a = 204 };

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,
    grid_spacing: f32 = 24,
    grid_alpha: f32 = 0.20,
    show_watermark: bool = true,
    show_origin: bool = true,
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
    z.clearViewport(f, backdrop); // solid base under the background draw list
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();

    // BACKGROUND draw list: a CAD grid that lives under every window.
    const bg: ui.DrawListHandle = u.getBackgroundDrawList();
    {
        var line_rgb: Color = grid_rgb;
        line_rgb.a = @trunc(clamp(s.grid_alpha * 255, 0, 255));
        const line: Color = line_rgb;
        var x: f32 = 0;
        while (x < w) : (x += s.grid_spacing) {
            bg.addLine(.{ x, 0 }, .{ x, h }, line, 1);
        }
        var y: f32 = 0;
        while (y < h) : (y += s.grid_spacing) {
            bg.addLine(.{ 0, y }, .{ w, y }, line, 1);
        }
        if (s.show_origin) {
            // A bullseye at the canvas origin so the grid feels anchored.
            const o: Vec2 = .{ 0, 0 };
            bg.addCircleFilled(o, 6, accent);
            bg.addCircle(o, 16, accent_dim, 2);
            bg.addCircle(o, 32, accent_faint, 1);
        }
    }

    // Control window: submitted between the bg + fg passes, mutates both.
    if (u.window("drawlist controls", .{
        .initial_pos = .{ 24, 96 },
        .initial_size = .{ 320, 240 },
    })) |win| {
        defer win.close();
        u.text("Background DL", .{});
        _ = u.slider("grid spacing", &s.grid_spacing, .{ .min = 8, .max = 80 });
        _ = u.slider("grid alpha", &s.grid_alpha, .{ .min = 0, .max = 1 });
        _ = u.checkbox("show origin bullseye", &s.show_origin);
        u.separator();
        u.text("Foreground DL", .{});
        _ = u.checkbox("show watermark", &s.show_watermark);
        u.separator();
        u.text("Drag this window across the grid.", .{});
        u.text("Grid stays under; watermark stays over.", .{});
    }

    // FOREGROUND draw list: a corner watermark above every window + popup.
    if (s.show_watermark) {
        const fg: ui.DrawListHandle = u.getForegroundDrawList();
        const box: z.Rectangle = .{ .x = w - 220, .y = h - 56, .width = 200, .height = 40 };
        fg.addRectFilled(box, panel_bg);
        fg.addRectOutline(box, accent);
        fg.addText("DEBUG BUILD - foreground DL", .{ box.x + 8, box.y + 12 }, 12, accent);
        // Crosshair at canvas center, drawn last to prove intra-list stacking.
        const cx: f32 = w / 2;
        const cy: f32 = h / 2;
        fg.addLine(.{ cx - 10, cy }, .{ cx + 10, cy }, accent_faint, 1);
        fg.addLine(.{ cx, cy - 10 }, .{ cx, cy + 10 }, accent_faint, 1);
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - UI drawlists",
            .width = 720,
            .height = 480,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
