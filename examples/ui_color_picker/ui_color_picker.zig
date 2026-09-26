//! ui_color_picker - port of the GL `ui_color_picker` onto the WebGPU UI
//! host. Side-by-side bar + wheel `colorPicker` layouts, alpha toggles, a size
//! slider, and an inline `colorEdit` comparison. The port swaps the GL
//! `UiContext` (+ shapes_texture + font_cache) for `z.UiHost`; the widget body
//! is unchanged - it's the same real `ui.zig` (Dear ImGui) Ui method set.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,
    bar_rgba: [4]f32 = .{ 0.85, 0.25, 0.35, 1.0 },
    wheel_rgba: [4]f32 = .{ 0.20, 0.55, 0.95, 1.0 },
    edit_rgb: [3]f32 = .{ 0.4, 0.85, 0.3 },
    show_alpha_bar: bool = true,
    show_alpha_wheel: bool = true,
    size_pick: f32 = 180,
    /// A permanent pointer into our OWN State (`bar_rgba`). This field is the
    /// concrete proof of in-place `init`: under return-by-value there is no `s`
    /// to point at until after the struct already exists, so `&s.bar_rgba` could
    /// not be produced inside init at all. Here it is set once, at init, and read
    /// every frame for the app's lifetime.
    active_rgba: *[4]f32,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 28);
    // Fill the whole struct first: still an exhaustive literal, so a forgotten
    // field is a compile error. `active_rgba` can't reference `s` yet (the struct
    // doesn't exist until this assignment completes), so it is placeholder-set
    // here and wired on the next line - the one pattern a self-referential field
    // needs. `ui_host` holds a FrameArena; building it at its FINAL address means
    // its internal pointers are valid unconditionally, not just by RLS grace.
    s.* = .{ .ui_host = z.UiHost.init(gpa, font), .active_rgba = undefined, .font = font };
    // `s` is now permanently placed. `&s.bar_rgba` stays valid for every frame.
    s.active_rgba = &s.bar_rgba;
}

fn update(f: *z.Frame, s: *State) void {
    z.clearViewport(f, .{ .r = 16, .g = 18, .b = 26, .a = 255 });

    const u: z.ui_real.Ui = s.ui_host.begin(f);
    if (u.window("Color picker - bar + wheel layouts", .{
        .initial_pos = .{ 20, 20 },
        .initial_size = .{ 960, 640 },
    })) |w| {
        defer w.close();

        u.text("colorPicker: bar | wheel layout, alpha on/off", .{});
        u.separator();

        _ = u.slider("picker size", &s.size_pick, .{ .min = 120, .max = 260, .fmt = "{d:.0}" });
        _ = u.checkbox("bar: show alpha", &s.show_alpha_bar);
        u.sameLine(.{});
        _ = u.checkbox("wheel: show alpha", &s.show_alpha_wheel);

        u.separator();
        u.text("Bar layout:", .{});
        if (s.show_alpha_bar) {
            _ = u.colorPicker("bar rgba", &s.bar_rgba, .{ .layout = .bar, .alpha = true, .size = s.size_pick });
        } else {
            var rgb: [3]f32 = .{ s.bar_rgba[0], s.bar_rgba[1], s.bar_rgba[2] };
            if (u.colorPicker("bar rgb", &rgb, .{ .layout = .bar, .size = s.size_pick })) {
                s.bar_rgba[0] = rgb[0];
                s.bar_rgba[1] = rgb[1];
                s.bar_rgba[2] = rgb[2];
            }
        }

        u.separator();
        u.text("Wheel layout:", .{});
        if (s.show_alpha_wheel) {
            _ = u.colorPicker("wheel rgba", &s.wheel_rgba, .{ .layout = .wheel, .alpha = true, .size = s.size_pick });
        } else {
            var rgb: [3]f32 = .{ s.wheel_rgba[0], s.wheel_rgba[1], s.wheel_rgba[2] };
            if (u.colorPicker("wheel rgb", &rgb, .{ .layout = .wheel, .size = s.size_pick })) {
                s.wheel_rgba[0] = rgb[0];
                s.wheel_rgba[1] = rgb[1];
                s.wheel_rgba[2] = rgb[2];
            }
        }

        u.separator();
        u.text("Inline colorEdit (per-channel 3-slider variant):", .{});
        _ = u.colorEdit("inline edit", &s.edit_rgb, .{});

        // Reads through the pointer stored in init - proof it survived: it always
        // mirrors the live bar_rgba above (edit the bar picker and watch it move).
        u.separator();
        u.text("active_rgba (via a stable pointer stored in init): R{d:.2} G{d:.2} B{d:.2}", .{
            s.active_rgba[0], s.active_rgba[1], s.active_rgba[2],
        });
    }
    s.ui_host.render(f);

    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - UI color picker",
            .width = 1000,
            .height = 680,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
