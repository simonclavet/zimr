// examples/ui_imgui_extras.zig - Turn 188 imgui gap-fill helpers demo.
// Five new helpers in one screen:
//   - inputTextWithHint: placeholder text in dimmed color when empty
//   - sliderAngle: radians stored, degrees displayed/dragged
//   - beginItemTooltip / endItemTooltip: hover→tooltip shorthand
//   - calcTextSize: public text measurement for custom layouts
//   - setKeyboardFocusHere: programmatic focus on the next widget

const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Vec2 = zm.Vec2;
const ui = z.ui_real;

const screen_w: i32 = 760;
const screen_h: i32 = 520;

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,

    search_buf: [128]u8 = std.mem.zeroes([128]u8),
    search_len: usize = 0,
    name_buf: [64]u8 = std.mem.zeroes([64]u8),
    name_len: usize = 0,

    yaw_rad: f32 = 0,
    pitch_rad: f32 = 0,

    request_search_focus: bool = true, // focus search on first frame
    focus_button_clicked: bool = false,
    badge_text: [24]u8 = std.mem.zeroes([24]u8),
    badge_len: usize = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, @embedFile("atkinson_mono_ttf"), 22);
    s.* = .{ .ui_host = z.UiHost.init(gpa, font), .font = font };
    const written: []u8 = bufPrint(&s.badge_text, "v2.7-alpha", .{}) catch s.badge_text[0..0];
    s.badge_len = written.len;
}

fn update(f: *z.Frame, s: *State) void {
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    if (u.window("ImGui extras - Turn 188", .{
        .initial_pos = .{ 20, 20 },
        .initial_size = .{ 720, 480 },
    })) |w| {
        defer w.close();

        // ---- inputTextWithHint
        u.text("inputTextWithHint - placeholder vanishes on focus/typing:", .{});
        // Programmatically focus the search field once at startup
        // (or whenever request_search_focus flips back to true).
        if (s.request_search_focus) {
            u.setKeyboardFocusHere();
            s.request_search_focus = false;
        }
        _ = u.inputTextWithHint("Search", "type to search...", &s.search_buf, &s.search_len, .{});
        _ = u.inputTextWithHint("Name", "First Last", &s.name_buf, &s.name_len, .{});

        if (u.button("Focus search again", .{})) {
            // Clear + refocus on next frame's submission.
            s.search_len = 0;
            s.request_search_focus = true;
        }
        if (u.beginItemTooltip()) {
            defer u.endItemTooltip();
            u.text("Programmatically grabs focus on the next frame.", .{});
            u.text("(uses setKeyboardFocusHere before the inputText)", .{});
        }

        u.separator();

        // ---- sliderAngle
        u.text("sliderAngle - radians stored, degrees shown:", .{});
        _ = u.sliderAngle("Yaw", &s.yaw_rad, .{});
        _ = u.sliderAngle("Pitch", &s.pitch_rad, .{ .min_deg = -90, .max_deg = 90 });
        u.labelText("yaw (rad)", "{d:.4}", .{s.yaw_rad});
        u.labelText("pitch (rad)", "{d:.4}", .{s.pitch_rad});

        u.separator();

        // ---- beginItemTooltip
        u.text("beginItemTooltip - shorthand for hover-conditional tooltips:", .{});
        if (u.button("Hover me", .{})) {}
        if (u.beginItemTooltip()) {
            defer u.endItemTooltip();
            u.text("This tooltip only opens when the button is hovered.", .{});
            u.text("It replaces the if(isItemHovered) beginTooltip pattern.", .{});
        }

        u.separator();

        // ---- calcTextSize
        u.text("calcTextSize - measure text without drawing it:", .{});
        const sample: []const u8 = "Sample text for measurement.";
        const sz: Vec2 = u.calcTextSize(sample);
        u.labelText("width", "{d:.1}px", .{sz[0]});
        u.labelText("height", "{d:.1}px", .{sz[1]});
        u.text("(use this when laying out custom widgets)", .{});

        // ---- setKeyboardFocusHere already exercised above ----
        u.separator();
        u.textDisabled("setKeyboardFocusHere was used at the top to focus the search field.", .{});
        u.textDisabled("Click 'Focus search again' to retrigger it.", .{});
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - UI imgui extras",
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
