//! text_field - single-line text input demo.
//!
//! Tap a field and type. On a phone the soft keyboard appears: a hidden DOM
//! <input> is overlaid exactly on the focused field (the "dom trick" - canvas
//! can't capture keyboard/IME, so we borrow a real <input>). What you type
//! mirrors back into the widget each frame and is echoed below the field.
//! See src/web/overlay_input.ts for the overlay; the wgpu runtime
//! (src/bridge.zig) wires it into imports.dom.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const ui = z.ui_real;

const screen_w: i32 = 800;
const screen_h: i32 = 520;

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,

    name_buf: [128]u8 = undefined,
    name_len: usize = 0,
    note_buf: [256]u8 = undefined,
    note_len: usize = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, @embedFile("atkinson_mono_ttf"), 22);
    s.* = .{ .font = font, .ui_host = z.UiHost.init(gpa, font) };
}

fn update(f: *z.Frame, s: *State) void {
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    if (u.window("Text field", .{
        .initial_pos = .{ 20, 20 },
        .initial_size = .{ 760, 480 },
    })) |w| {
        defer w.close();

        u.text("Tap a field and type.  On a phone the soft keyboard appears.", .{});
        u.separator();

        _ = u.inputTextWithHint("Name", "your name", &s.name_buf, &s.name_len, .{});
        u.text("  name  -> {s}", .{s.name_buf[0..s.name_len]});

        u.separator();

        _ = u.inputTextWithHint("Note", "a short note", &s.note_buf, &s.note_len, .{});
        u.text("  note  -> {s}", .{s.note_buf[0..s.note_len]});

        u.separator();
        u.text("A hidden DOM <input> is positioned over the focused field;", .{});
        u.text("what you type mirrors back into the widget each frame.", .{});
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - text field",
            .width = screen_w,
            .height = screen_h,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
