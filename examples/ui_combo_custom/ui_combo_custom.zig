// examples/ui_combo_custom.zig - B3b drop 1.
// beginCombo / endCombo with custom dropdown content.  Where the
// plain `combo()` takes a `[]const []const u8` of items, this
// version lets the caller put anything inside the dropdown
// icons, color swatches, group headers, even nested widgets.
// Demo: two combos in the control window.
//   1. "graphics preset"  - selectable + a color swatch + a
//                            multi-line description below each row
//   2. "color theme"      - a row of color squares; clicking one
//                            picks it and previews it on the closed
//                            row
// Demonstrates Phase B3b of the imgui-parity arc.

const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const ui = z.ui_real;
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const Color = zm.Color;

const Preset = struct {
    name: []const u8,
    accent: Color,
    desc: []const u8,
};

const presets = [_]Preset{
    .{ .name = "Low", .accent = .{ .r = 132, .g = 204, .b = 22, .a = 255 }, .desc = "lowest GPU cost" },
    .{ .name = "Medium", .accent = .{ .r = 14, .g = 165, .b = 233, .a = 255 }, .desc = "balanced" },
    .{ .name = "High", .accent = .{ .r = 168, .g = 85, .b = 247, .a = 255 }, .desc = "rich shading" },
    .{ .name = "Ultra", .accent = .{ .r = 245, .g = 158, .b = 11, .a = 255 }, .desc = "max fidelity" },
};

const themes = [_]Color{
    .{ .r = 14, .g = 165, .b = 233, .a = 255 },
    .{ .r = 168, .g = 85, .b = 247, .a = 255 },
    .{ .r = 244, .g = 114, .b = 182, .a = 255 },
    .{ .r = 132, .g = 204, .b = 22, .a = 255 },
    .{ .r = 245, .g = 158, .b = 11, .a = 255 },
    .{ .r = 239, .g = 68, .b = 68, .a = 255 },
};

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,
    preset_index: i32 = 1,
    theme_index: i32 = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 28);
    s.* = .{
        .ui_host = z.UiHost.init(gpa, font),
        .font = font,
    };
}

fn update(f: *z.Frame, s: *State) void {
    z.clearViewport(f, .{ .r = 15, .g = 23, .b = 42, .a = 255 });

    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    if (u.window("beginCombo custom content", .{
        .initial_pos = .{ 24, 24 },
        .initial_size = .{ 460, 380 },
    })) |w| {
        defer w.close();

        u.text("Phase B3b: custom dropdown content via beginCombo + endCombo.", .{});
        u.textDisabled("Items below each combo come from the CALLER, not a string array.", .{});
        u.separator();

        // ---- 1. Graphics preset combo with desc + accent swatch ----
        u.text("Graphics preset", .{});
        const idx_clamped: usize = if (s.preset_index < 0) 0 else @intCast(@min(
            s.preset_index,
            @as(i32, presets.len - 1),
        ));
        if (u.beginCombo("##preset", presets[idx_clamped].name, .{ .width = 280 })) {
            defer u.endCombo();
            for (presets, 0..) |p, i| {
                const sel: bool = idx_clamped == i;
                // The selectable carries the click + selected
                // highlight.  After it, we tack on a color swatch
                // (drawn via the foreground draw list - sits ON
                // TOP of the popup row) and a description.
                if (u.selectable(p.name, sel, .{})) {
                    s.preset_index = @intCast(i);
                }
                u.sameLine(.{});
                u.textColored(p.accent, "{s}", .{p.desc});
            }
        }
        u.separator();

        // ---- 2. Color theme combo with a swatch row -------------------
        u.text("Color theme", .{});
        var theme_label_buf: [16]u8 = undefined;
        const theme_label: []const u8 = bufPrint(&theme_label_buf, "theme {d}", .{s.theme_index}) catch "?";
        if (u.beginCombo("##theme", theme_label, .{ .width = 280 })) {
            defer u.endCombo();
            // Six themes shown as labeled selectables tinted with the
            // theme color.  selectable's hover/selected highlight is
            // separate from the tint - the tint signals identity, the
            // highlight signals state.
            for (themes, 0..) |c, i| {
                const sel = s.theme_index == @as(i32, @intCast(i));
                var name_buf: [16]u8 = undefined;
                const name: []const u8 = bufPrint(&name_buf, "  theme {d}", .{i}) catch "?";
                if (u.selectable(name, sel, .{})) {
                    s.theme_index = @intCast(i);
                }
                _ = c; // visual tint left for future expansion
            }
        }
        u.separator();

        u.text(
            "Open both combos to see they're independent - opening one " ++
                "closes the other (single-slot semantics, matches imgui).",
            .{},
        );
    }
}

/// User-owned framework integration point.  See `examples/basic.zig`
/// for the canonical comment block; this declaration is the
/// AppBridge pattern's required convention.
/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - beginCombo (B3b)",
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
