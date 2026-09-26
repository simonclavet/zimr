//! ui_window_menubar - per-window menu bars ported to WebGPU. Three windows,
//! each with its own `beginMenuBar` pinned to its top (not a canvas-wide bar):
//! a Document window (File/Edit/View, with a dirty bit and undo depth), a
//! Properties window (its own Tools menu), and a Settings window (Help -> About).
//! Drag any window and its bar drags with it. A foreground draw list paints an
//! About overlay and a bottom status bar showing the last menu action.
//!
//! Ported from the GL `ui_window_menubar`. GL `UiContext` (+ shapes_texture +
//! font_cache) becomes `z.UiHost`; the widget body is unchanged (shared ui.zig).
//! The GL version opened the UI frame BEFORE `beginDrawing`; the wgpu UiHost
//! renders into the open draw frame, so here `beginDrawing`/`clearBackground`
//! come FIRST, then `ui_host.begin`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const ui = z.ui_real;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,
    document_dirty: bool = true,
    document_undo_depth: u8 = 3,
    grid_visible: bool = true,
    handles_visible: bool = false,
    rulers_visible: bool = true,
    last_action: [64]u8 = @splat(0),
    last_action_len: u8 = 0,
    show_about: bool = false,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn init(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 32);
    s.* = .{ .ui_host = z.UiHost.init(gpa, font), .font = font };
}

fn setLastAction(s: *State, msg: []const u8) void {
    const n: usize = @min(msg.len, s.last_action.len);
    @memcpy(s.last_action[0..n], msg[0..n]);
    s.last_action_len = @intCast(n);
}

fn update(f: *z.Frame, s: *State) void {
    // Descriptor app: the runner/launcher owns begin/clear/end. Paint our own bg
    // (the menu windows + status bar don't cover the whole surface).
    const bg_w: f32 = f.window.widthf();
    const bg_h: f32 = f.window.heightf();
    const bg_col: Color = .{ .r = 15, .g = 23, .b = 42, .a = 255 };
    f.gl.rect(.{ .x = 0, .y = 0, .width = bg_w, .height = bg_h }, .{ .color = bg_col });

    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    // Window #1: Document. File + Edit + View menus.
    if (u.window("Document", .{
        .initial_pos = .{ 32, 32 },
        .initial_size = .{ 420, 280 },
        .flags = .{ .menu_bar = true },
    })) |w| {
        defer w.close();

        if (u.beginMenuBar()) {
            defer u.endMenuBar();

            if (u.beginMenu("File")) {
                defer u.endMenu();
                if (u.menuItem("New", .{ .shortcut = "Ctrl+N" })) {
                    s.document_dirty = false;
                    s.document_undo_depth = 0;
                    setLastAction(s, "File -> New");
                }
                if (u.menuItem("Save", .{ .shortcut = "Ctrl+S" })) {
                    s.document_dirty = false;
                    setLastAction(s, "File -> Save");
                }
                if (u.menuItem("Save As...", .{ .shortcut = "Ctrl+Shift+S" })) {
                    s.document_dirty = false;
                    setLastAction(s, "File -> Save As");
                }
            }

            if (u.beginMenu("Edit")) {
                defer u.endMenu();
                if (u.menuItem("Undo", .{ .shortcut = "Ctrl+Z" })) {
                    if (s.document_undo_depth > 0) {
                        s.document_undo_depth -= 1;
                    }
                    setLastAction(s, "Edit -> Undo");
                }
                if (u.menuItem("Redo", .{ .shortcut = "Ctrl+Y" })) {
                    s.document_undo_depth += 1;
                    setLastAction(s, "Edit -> Redo");
                }
                if (u.menuItem("Mark Dirty", .{})) {
                    s.document_dirty = true;
                    setLastAction(s, "Edit -> Mark Dirty");
                }
            }

            if (u.beginMenu("View")) {
                defer u.endMenu();
                if (u.menuItem("Grid", .{ .selected = s.grid_visible })) {
                    s.grid_visible = !s.grid_visible;
                    setLastAction(s, "View -> Grid toggled");
                }
                if (u.menuItem("Handles", .{ .selected = s.handles_visible })) {
                    s.handles_visible = !s.handles_visible;
                    setLastAction(s, "View -> Handles toggled");
                }
                if (u.menuItem("Rulers", .{ .selected = s.rulers_visible })) {
                    s.rulers_visible = !s.rulers_visible;
                    setLastAction(s, "View -> Rulers toggled");
                }
            }
        }

        u.text("This window has its own menu bar.", .{});
        u.text("Drag the title - the bar drags with the window.", .{});
        u.separator();
        if (s.document_dirty) {
            u.textColored(.{ .r = 251, .g = 191, .b = 36, .a = 255 }, "* Document has unsaved changes", .{});
        } else {
            u.textColored(.{ .r = 34, .g = 197, .b = 94, .a = 255 }, "* Saved", .{});
        }
        u.textDisabled("undo depth: {d}", .{s.document_undo_depth});
        u.separator();
        u.text("Layers visible:", .{});
        u.textDisabled("  grid:    {s}", .{if (s.grid_visible) "on " else "off"});
        u.textDisabled("  handles: {s}", .{if (s.handles_visible) "on " else "off"});
        u.textDisabled("  rulers:  {s}", .{if (s.rulers_visible) "on " else "off"});
    }

    // Window #2: Properties. Its OWN Tools menu - independent of Document's.
    if (u.window("Properties", .{
        .initial_pos = .{ 480, 32 },
        .initial_size = .{ 320, 220 },
        .flags = .{ .menu_bar = true },
    })) |w| {
        defer w.close();

        if (u.beginMenuBar()) {
            defer u.endMenuBar();
            if (u.beginMenu("Tools")) {
                defer u.endMenu();
                if (u.menuItem("Reset View", .{})) {
                    setLastAction(s, "Tools -> Reset View");
                }
                if (u.menuItem("Snap to Grid", .{})) {
                    setLastAction(s, "Tools -> Snap to Grid");
                }
            }
        }

        u.text("Second window with its own bar.", .{});
        u.text("Menus here don't interfere with", .{});
        u.text("the Document window's File/Edit/View.", .{});
    }

    // Window #3: Settings. Help -> About toggles a foreground overlay.
    if (u.window("Settings", .{
        .initial_pos = .{ 32, 360 },
        .initial_size = .{ 360, 180 },
        .flags = .{ .menu_bar = true },
    })) |w| {
        defer w.close();

        if (u.beginMenuBar()) {
            defer u.endMenuBar();
            if (u.beginMenu("Help")) {
                defer u.endMenu();
                if (u.menuItem("About", .{ .selected = s.show_about })) {
                    s.show_about = !s.show_about;
                    setLastAction(s, "Help -> About toggled");
                }
            }
        }

        u.text("Open Help -> About to flash an", .{});
        u.text("overlay drawn on the foreground", .{});
        u.text("draw list.", .{});
    }

    // Foreground draw list - overlay banner + bottom status bar.
    const fg: ui.DrawListHandle = u.getForegroundDrawList();
    const sw_f: f32 = f.window.widthf();
    const sh_f: f32 = f.window.heightf();

    // Overlay palette - named Colors instead of packed-wire hex.
    const panel_bg: Color = Color.fromWire(0xEE111827);
    const status_bg: Color = Color.fromWire(0xCC0F172A);
    const text_light: Color = Color.fromWire(0xFFE2E8F0);
    const text_muted: Color = Color.fromWire(0xFF94A3B8);
    const text_dim: Color = Color.fromWire(0xFF64748B);

    if (s.show_about) {
        const panel_w: f32 = 360;
        const panel_h: f32 = 88;
        const panel_x: f32 = (sw_f - panel_w) / 2;
        const panel_y: f32 = 80;
        const panel: z.Rectangle = .{ .x = panel_x, .y = panel_y, .width = panel_w, .height = panel_h };
        fg.addRectFilled(panel, panel_bg);
        fg.addRectOutline(panel, text_light);
        fg.addText("zimr - per-window menu bar demo", .{ panel_x + 16, panel_y + 16 }, 14, text_light);
        fg.addText("close from Help -> About", .{ panel_x + 16, panel_y + 48 }, 12, text_muted);
    }

    // Bottom status bar.
    fg.addRectFilled(.{ .x = 0, .y = sh_f - 24, .width = sw_f, .height = 24 }, status_bg);
    if (s.last_action_len > 0) {
        const slice: []u8 = s.last_action[0..s.last_action_len];
        fg.addText(slice, .{ 12, sh_f - 18 }, 12, text_light);
    } else {
        fg.addText("(no menu action yet - pick something)", .{ 12, sh_f - 18 }, 12, text_dim);
    }
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{ .window = .{
        .title = "zimr - WebGPU - per-window menu bar",
        .width = 1000,
        .height = 640,
        .scale_mode = .responsive,
        .depth_format = null,
    } },
    .init = init,
    .deinit = deinit,
    .update = update,
};
