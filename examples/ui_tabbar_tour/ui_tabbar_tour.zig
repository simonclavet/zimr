//! ui_tabbar_tour - port of the GL `ui_tabbar_tour` onto the WebGPU UI host.
//! A tour of the TabBar widget across three stacked bars: (1) closeable tabs with
//! close-X + middle-click + per-tab id-isolated buttons, (2) leading/trailing pins
//! + unsaved-document asterisk + bar-level middle-click suppression, (3) force-
//! select + selected-overline. Harness swap only (UiContext+shapes_texture+
//! font_cache -> z.UiHost); the tab-bar body is unchanged real ui.zig.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const ui = z.ui_real;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const Bg: Color = .{ .r = 15, .g = 23, .b = 42, .a = 255 };

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,

    // Bar 1 - closeable tabs (open_ptr controls whether each renders).
    tab_a: bool = true,
    tab_b: bool = true,
    tab_c: bool = true,

    // Bar 2 - unsaved-document toggles.
    doc1_unsaved: bool = true,
    doc2_unsaved: bool = false,

    // Bar 3 - force-select demo.
    force_select_b: bool = false,

    // Per-tab click counters - prove id-stack isolation across tabs.
    bar1_a_clicks: u32 = 0,
    bar1_b_clicks: u32 = 0,
    bar1_c_clicks: u32 = 0,
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
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    if (u.window("TabBar tour", .{
        .initial_pos = .{ 8, 8 },
        .initial_size = .{ 460, 860 },
    })) |w| {
        defer w.close();

        // Bar 1 - closeable tabs (close-X + middle-click). Each tab owns a
        // "Click me" button that increments a separate counter -> id isolation.
        u.separatorText("Bar 1 - closeable tabs + middle-click");
        u.textWrapped("Click a tab to switch. Click the X (or middle-click the tab) to close it.", .{});
        if (u.beginTabBar("bar1", .{})) {
            defer u.endTabBar();
            if (s.tab_a and u.beginTabItem("Alpha", &s.tab_a, .{})) {
                defer u.endTabItem();
                if (u.button("Click me", .{})) {
                    s.bar1_a_clicks += 1;
                }
                u.value("alpha clicks", s.bar1_a_clicks);
            }
            if (s.tab_b and u.beginTabItem("Beta", &s.tab_b, .{})) {
                defer u.endTabItem();
                if (u.button("Click me", .{})) {
                    s.bar1_b_clicks += 1;
                }
                u.value("beta clicks", s.bar1_b_clicks);
            }
            if (s.tab_c and u.beginTabItem("Gamma", &s.tab_c, .{})) {
                defer u.endTabItem();
                if (u.button("Click me", .{})) {
                    s.bar1_c_clicks += 1;
                }
                u.value("gamma clicks", s.bar1_c_clicks);
            }
        }
        if (u.button("Reopen all", .{})) {
            s.tab_a = true;
            s.tab_b = true;
            s.tab_c = true;
        }

        // Bar 2 - leading/trailing pins + unsaved asterisk + bar-level
        // middle-click suppression. doc1/doc2 are always-open (per-frame
        // dummy open_ptr); they demo the asterisk, not closing.
        u.separatorText("Bar 2 - leading/trailing + unsaved (*)");
        u.textWrapped("Hamburger pinned LEFT, settings pinned RIGHT. doc1 shows the unsaved asterisk.", .{});
        if (u.beginTabBar("bar2", .{ .no_close_with_middle_mouse_button = true })) {
            defer u.endTabBar();
            if (u.beginTabItem("Menu", null, .{ .leading = true })) {
                defer u.endTabItem();
                u.text("Hamburger menu (leading pin).", .{});
            }
            var dummy1: bool = true;
            var dummy2: bool = true;
            if (u.beginTabItem("doc1.txt", &dummy1, .{ .unsaved_document = s.doc1_unsaved })) {
                defer u.endTabItem();
                u.textWrapped("Content of doc1. Toggle the unsaved flag below.", .{});
                _ = u.checkbox("doc1 unsaved", &s.doc1_unsaved);
            }
            if (u.beginTabItem("doc2.txt", &dummy2, .{ .unsaved_document = s.doc2_unsaved })) {
                defer u.endTabItem();
                u.textWrapped("Content of doc2. Toggle the unsaved flag below.", .{});
                _ = u.checkbox("doc2 unsaved", &s.doc2_unsaved);
            }
            if (u.beginTabItem("Cfg", null, .{ .trailing = true })) {
                defer u.endTabItem();
                u.text("Settings (trailing pin).", .{});
            }
        }

        // Bar 3 - force-select via .set_selected + selected overline.
        u.separatorText("Bar 3 - force-select + overline");
        u.textWrapped("Tick the box to force-select 'Two'. The selected tab gets a 2px overline.", .{});
        _ = u.checkbox("force-select 'Two'", &s.force_select_b);
        if (u.beginTabBar("bar3", .{ .draw_selected_overline = true })) {
            defer u.endTabBar();
            if (u.beginTabItem("One", null, .{})) {
                defer u.endTabItem();
                u.text("Tab One content.", .{});
            }
            const opts: ui.TabItemFlags = .{ .set_selected = s.force_select_b };
            if (u.beginTabItem("Two", null, opts)) {
                defer u.endTabItem();
                u.text("Tab Two content.", .{});
            }
            if (u.beginTabItem("Three", null, .{})) {
                defer u.endTabItem();
                u.text("Tab Three content.", .{});
            }
        }
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - UI TabBar tour",
            .width = 480,
            .height = 900,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
