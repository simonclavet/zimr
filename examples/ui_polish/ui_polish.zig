// examples/ui_polish.zig - Phase 3 polish showcase.
// Demonstrates the four Phase 3 additions:
//   - pushStyle/popStyle: temporarily override Style fields
//     (reflection-based, comptime-typed).  See the "chunky" button
//     row and the accent-colored section.
//   - getCursorPos/setCursorPos: stash + restore the layout cursor
//     for pixel-precise placement (corner badge in upper right).
//   - labelText: imgui-parity "value | label" same-row readout.
//   - textDisabled: dimmed-color text variant for hints.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const Vec2 = zm.Vec2;
const ui = z.ui_real;

const screen_w: i32 = 760;
const screen_h: i32 = 540;

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,

    health: i32 = 87,
    score: i32 = 14250,
    level: u32 = 9,
    last_save: f32 = 12.5,

    chunky: bool = true,
    accent_section: bool = true,
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
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    if (u.window("Polish - Phase 3 additions", .{
        .initial_pos = .{ 20, 20 },
        .initial_size = .{ 720, 500 },
    })) |w| {
        defer w.close();

        // ---- P4.2: theme preset switcher
        u.text("applyPreset - swap every color slot in one call:", .{});
        if (u.button("dark", .{})) {
            s.ui_host.ctx.style.applyPreset(.dark);
        }
        u.sameLine(.{});
        if (u.button("light", .{})) {
            s.ui_host.ctx.style.applyPreset(.light);
        }
        u.sameLine(.{});
        if (u.button("classic", .{})) {
            s.ui_host.ctx.style.applyPreset(.classic);
        }
        u.textDisabled("(font + padding survive the swap; only colors change)", .{});

        u.separator();

        // ---- labelText readouts
        u.text("labelText - value-first / label-after on the same row:", .{});
        u.labelText("Health", "{d}%", .{s.health});
        u.labelText("Score", "{d}", .{s.score});
        u.labelText("Level", "{d}", .{s.level});
        u.labelText("Last save", "{d:.1}s ago", .{s.last_save});

        u.separator();

        // ---- textDisabled hint
        u.text("textDisabled - dimmed-color variant for hints:", .{});
        u.textDisabled("(use Tab to focus widgets, Enter to commit)", .{});
        u.textDisabled("Currently {d}/{d} fields filled", .{ 3, 4 });

        u.separator();

        // ---- pushStyle: chunky-button row
        u.text("pushStyle('frame_padding', ...) - chunky buttons:", .{});
        _ = u.checkbox("chunky", &s.chunky);
        if (s.chunky) {
            u.pushStyle("frame_padding", Vec2{ 14, 10 });
        } else {
            u.pushStyle("frame_padding", Vec2{ 4, 3 });
        }
        defer u.popStyle();
        if (u.button("Save", .{})) {}
        u.sameLine(.{});
        if (u.button("Load", .{})) {}
        u.sameLine(.{});
        if (u.button("Reset", .{})) {}

        u.separator();

        // ---- pushStyle: accent-colored section
        u.text("pushStyle('text', ...) - accent-colored section:", .{});
        _ = u.checkbox("accent section", &s.accent_section);
        if (s.accent_section) {
            u.pushStyle("text", Color{ .r = 251, .g = 191, .b = 36, .a = 255 }); // amber-400
            u.text("This text uses the amber accent.", .{});
            u.text("So does this line.", .{});
            u.popStyle();
        } else {
            u.text("This text uses the default color.", .{});
            u.text("So does this line.", .{});
        }

        u.separator();

        // ---- setCursorPos: corner badge
        u.text("setCursorPos - pixel-precise corner badge top-right:", .{});
        const saved: Vec2 = u.getCursorPos();
        // Render a small badge at the window's top-right corner.
        u.setCursorPos(.{ 600, 30 });
        u.pushStyle("text", Color{ .r = 16, .g = 185, .b = 129, .a = 255 }); // emerald-500
        u.text("v2.7-alpha", .{});
        u.popStyle();
        u.setCursorPos(saved); // restore for normal flow

        u.textDisabled("(the badge above sits at fixed coords regardless of scroll)", .{});
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - UI polish",
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
