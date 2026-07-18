// examples/imgui_phone_demo.zig
//
// Phone-focused ImGui demo.  Walks through the user-facing widget
// surface on a portrait-aspect, finger-driven canvas.  Five tabs
// (Basic / Input / Color / Pick / Info) shaped to fit one screen at
// a time on mobile, with widget targets sized for touch.
//
// Two zimr-specific choices that matter for phone:
//
//   1. Font setup uses `loadFontFromTtfBytes` + a FontCache and
//      `style.font = &font_cache.font`.  This is the pattern that
//      survives `style.font_size` overrides; the older
//      `loadFontFromTtfData` path renders blank widget chrome
//      whenever font_size is bumped (known regression, see the
//      `ui_minimal_button.zig` diagnostic example).
//
//   2. Touch radio groups use `selectable()` for full-row hit
//      targets instead of `radioButton()`, whose hit area is just
//      the small dot + label (~22px tall at font_size 16, well
//      under iOS's 44pt minimum).
//
// Tab color theme is configured for the turn-411 hover-wins-over-
// active priority — see the `update` body for the palette rationale.

const std = @import("std");
const zm = @import("zm");
const float = zm.float;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const ui = z.ui_real;

const State = struct {
    ui_host: z.UiHost = undefined,
    font: z.Font = undefined,

    counter: i32 = 0,
    slider_val: f32 = 0.5,
    progress: f32 = 0,
    check_a: bool = true,
    check_b: bool = false,
    difficulty: i32 = 1,

    name_buf: [64]u8 = undefined,
    name_len: usize = 0,
    note_buf: [128]u8 = undefined,
    note_len: usize = 0,
    int_val: i32 = 42,

    rgb: [3]f32 = .{ 0.40, 0.78, 0.95 },

    selected: i32 = 0,
    items: [6][]const u8 = .{
        "Astatine", "Bismuth", "Calcium", "Dysprosium", "Europium", "Francium",
    },

    show_floater: bool = false,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, @embedFile("atkinson_mono_ttf"), 22);
    // `.{ .ui_host = ... }` applies every other field's declared default (the
    // widget seed values); the old `var result: State = undefined` discarded them.
    s.* = .{ .font = font, .ui_host = z.UiHost.init(gpa, font) };
}

fn tabBasic(u: ui.Ui, s: *State) void {
    u.text("Counter: {d}", .{s.counter});
    if (u.button("-1", .{})) {
        s.counter -= 1;
    }
    u.sameLine(.{});
    if (u.button("+1", .{})) {
        s.counter += 1;
    }
    u.sameLine(.{});
    if (u.button("Reset", .{})) {
        s.counter = 0;
    }

    u.separator();
    _ = u.slider("Slider", &s.slider_val, .{ .min = 0, .max = 1 });

    u.text("Auto progress:", .{});
    u.progressBar(s.progress, .{ 0, 16 }, "");

    u.separator();
    _ = u.checkbox("Check A", &s.check_a);
    _ = u.checkbox("Check B", &s.check_b);

    u.separator();
    // Difficulty via SELECTABLE rows (full-width touch targets)
    // instead of radioButton (22px tall hit rect).  Visual: highlighted
    // row when selected.  Behaviour: tap-to-pick, like radio.
    u.text("Difficulty:", .{});
    if (u.selectable("Easy", s.difficulty == 0, .{})) {
        s.difficulty = 0;
    }
    if (u.selectable("Medium", s.difficulty == 1, .{})) {
        s.difficulty = 1;
    }
    if (u.selectable("Hard", s.difficulty == 2, .{})) {
        s.difficulty = 2;
    }
}

fn tabInput(u: ui.Ui, s: *State) void {
    _ = u.inputText("Name", &s.name_buf, &s.name_len, .{});

    u.separator();
    u.text("Note:", .{});
    _ = u.inputTextMultiline(
        "Note",
        &s.note_buf,
        &s.note_len,
        .{ 0, 120 },
        .{},
    );

    u.separator();
    _ = u.drag(
        "Integer",
        &s.int_val,
        .{ .speed = 1, .min = 0, .max = 100, .fmt = "{d}" },
    );

    u.separator();
    if (u.button("Clear all", .{})) {
        s.name_len = 0;
        s.note_len = 0;
        s.int_val = 0;
    }
}

fn tabColor(u: ui.Ui, s: *State) void {
    _ = u.colorEdit("Color", &s.rgb, .{});
    u.text("R: {d:.2}", .{s.rgb[0]});
    u.text("G: {d:.2}", .{s.rgb[1]});
    u.text("B: {d:.2}", .{s.rgb[2]});
}

fn tabPick(u: ui.Ui, s: *State) void {
    u.text("Selected: {s}", .{
        if (s.selected >= 0 and s.selected < @as(i32, @intCast(s.items.len)))
            s.items[@intCast(s.selected)]
        else
            "(none)",
    });
    u.separator();
    for (s.items, 0..) |item, i| {
        const idx: i32 = @intCast(i);
        if (u.selectable(item, s.selected == idx, .{})) {
            s.selected = idx;
        }
    }
}

fn tabInfo(
    u: ui.Ui,
    s: *State,
    f: *z.Frame,
) void {
    u.text("zimr phone demo v5", .{});
    u.separator();

    u.text("Canvas: {d} x {d}", .{ f.window.screen_width, f.window.screen_height });
    const fps: f32 = if (f.time.delta_time > 0) 1.0 / f.time.delta_time else 0;
    u.text("FPS: {d:.0}", .{fps});

    u.separator();
    if (u.button(if (s.show_floater) "Hide overlay" else "Show overlay", .{})) {
        s.show_floater = !s.show_floater;
    }

    u.separator();
    u.textWrapped(
        "Font setup: window B's pattern (FontCache + bumped size 16). " ++
            "If chrome renders here, B's pattern is the right one. " ++
            "Difficulty + Pick lists use selectable() for finger-sized rows.",
        .{},
    );
}

fn update(f: *z.Frame, s: *State) void {
    z.clearViewport(f, .{ .r = 18, .g = 22, .b = 32, .a = 255 });

    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    // Style applied EVERY frame.  imgui_demo's pattern — the
    // `update` body is where the user expresses their per-frame
    // intent, including the visual theme.  Cheap (just a handful
    // of field writes) and avoids any "did initState run before
    // any widget read this field" timing question.
    const style: *ui.Style = u.style();
    style.font = &s.ui_host.font_cache.font;
    style.font_size = 16;
    style.frame_padding = .{ 12, 10 };
    style.item_spacing = .{ 8, 10 };
    style.title_bar_height = 32;

    // Tab color palette is laid out for zimr's hover-wins-over-active
    // priority (turn 411):
    //
    //   tab          — idle, deepest navy
    //   tab_active   — selected/persistent, bright sky blue
    //   tab_hovered  — press-feedback, even brighter (near-white blue)
    //
    // Touching a tab momentarily flashes tab_hovered (your finger is
    // ON the tab); releasing settles the active tab to tab_active
    // and inactives back to tab.  Each step up in brightness has to
    // be clearly distinguishable on a phone screen at arm's length,
    // hence the deliberate gaps in the b-channel.
    style.tab = .{ .r = 30, .g = 36, .b = 50, .a = 255 };
    style.tab_active = .{ .r = 70, .g = 130, .b = 210, .a = 255 };
    style.tab_hovered = .{ .r = 120, .g = 190, .b = 255, .a = 255 };

    // Buttons follow the same accent ramp so the chrome reads
    // consistently across button + tab widgets.
    style.button = .{ .r = 40, .g = 70, .b = 110, .a = 255 };
    style.button_hovered = .{ .r = 60, .g = 100, .b = 160, .a = 255 };
    style.button_active = .{ .r = 90, .g = 140, .b = 220, .a = 255 };

    s.progress += f.time.delta_time * 0.25;
    if (s.progress > 1.0) {
        s.progress = 0.0;
    }

    const W: f32 = float(f.window.screen_width);
    const H: f32 = float(f.window.screen_height);
    u.setNextWindowPos(.{ 0, 0 }, .{});
    u.setNextWindowSize(.{ W, H }, .{});
    if (u.window("phone-demo", .{
        .flags = .{
            .no_title_bar = true,
            .no_resize = true,
            .no_move = true,
            .no_collapse = true,
            .no_saved_settings = true,
        },
    })) |w| {
        defer w.close();

        if (u.beginTabBar("tabs", .{})) {
            defer u.endTabBar();
            if (u.beginTabItem("Basic", null, .{})) {
                tabBasic(u, s);
                u.endTabItem();
            }
            if (u.beginTabItem("Input", null, .{})) {
                tabInput(u, s);
                u.endTabItem();
            }
            if (u.beginTabItem("Color", null, .{})) {
                tabColor(u, s);
                u.endTabItem();
            }
            if (u.beginTabItem("Pick", null, .{})) {
                tabPick(u, s);
                u.endTabItem();
            }
            if (u.beginTabItem("Info", null, .{})) {
                tabInfo(u, s, f);
                u.endTabItem();
            }
        }
    }

    if (s.show_floater) {
        u.setNextWindowSize(.{ W - 60, 200 }, .{ .once = true });
        u.setNextWindowPos(.{ 30, H * 0.35 }, .{ .once = true });
        if (u.window("Overlay (drag me)", .{
            .flags = .{ .no_collapse = true, .no_saved_settings = true },
        })) |w| {
            defer w.close();
            u.text("Drag the title bar to move.", .{});
            u.separator();
            if (u.button("Close", .{})) {
                s.show_floater = false;
            }
        }
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - phone demo",
            .width = 400,
            .height = 880,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
