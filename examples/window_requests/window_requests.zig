//! window_requests - asking the platform for things beyond the window's contents: fullscreen, a screen kept on, and a
//! web page opened.
//!
//! Each button makes one request. Fullscreen (`z.requestFullscreen`, or F11) is granted in the platform's time - a
//! browser grants it only during a click or a key press - so the app asks and then reads the outcome from each frame's
//! `f.window.fullscreen`; Escape in a browser, or another request, ends it. Keeping the screen awake (`z.keepAwake`)
//! holds off dimming, the screen saver and sleep, as a video player does, until it is turned off. Opening an address
//! (`z.openUrl`) shows it in a new tab beside a web app, in the default browser beside a native one; copying it
//! (`z.setClipboardText`) puts it on the system clipboard, to paste anywhere. A paste arrives as text for one frame
//! (`z.getPastedText`): from Ctrl+V, the system's own paste command, or from the paste button (`z.requestPaste`),
//! which a browser may decline without permission to read the clipboard.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const common = @import("example_common");
const zm = @import("zm");
const float = zm.float;
const Color = zm.Color;
const Vec2 = zm.Vec2;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const page_address: []const u8 = "https://ziglang.org";

const background: Color = .{ .r = 15, .g = 23, .b = 42, .a = 255 };
const button_color: Color = .{ .r = 30, .g = 64, .b = 175, .a = 255 };
const button_hovered: Color = .{ .r = 37, .g = 99, .b = 235, .a = 255 };
const text_color: Color = .{ .r = 226, .g = 232, .b = 240, .a = 255 };
const dim_color: Color = .{ .r = 148, .g = 163, .b = 184, .a = 255 };

const State = struct {
    font: z.Font,
    /// Whether the app asked for the screen to stay on; the platform does not report it back.
    is_keeping_awake: bool = false,
    /// The beginning of the last text pasted, for its status line.
    last_paste: [48]u8 = undefined,
    last_paste_length: usize = 0,
};

/// Whether cutting `text` at `cut` would split a character: the byte there continues one (UTF-8 continuation bytes
/// are `10xxxxxx`). Cutting at either end splits nothing.
fn cutsCharacter(text: []const u8, cut: usize) bool {
    const is_within_text: bool = cut > 0 and cut < text.len;
    return is_within_text and text[cut] & 0xc0 == 0x80;
}

/// Keeps the beginning of a pasted text for display: whole characters only, and line breaks shown as spaces.
fn keepPaste(s: *State, text: []const u8) void {
    var kept_length: usize = @min(text.len, s.last_paste.len);
    while (cutsCharacter(text, kept_length)) {
        kept_length -= 1;
    }
    for (text[0..kept_length], s.last_paste[0..kept_length]) |byte, *kept| {
        kept.* = if (byte == '\n' or byte == '\r') ' ' else byte;
    }
    s.last_paste_length = kept_length;
}

/// The buttons, in order.
const Button = enum { fullscreen, keep_awake, open_page, copy_address, paste };

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{ .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 18) };
}

fn deinit(gpa: Allocator, s: *State) void {
    if (s.is_keeping_awake) {
        z.keepAwake(false);
    }
    z.unloadFont(gpa, s.font);
}

fn buttonRect(button: Button) z.Rectangle {
    return .{ .x = 16, .y = 52 + float(@backingInt(button)) * 56, .width = 300, .height = 44 };
}

fn isInside(rect: z.Rectangle, point: Vec2) bool {
    const is_within_columns: bool = point[0] >= rect.x and point[0] < rect.x + rect.width;
    const is_within_rows: bool = point[1] >= rect.y and point[1] < rect.y + rect.height;
    return is_within_columns and is_within_rows;
}

/// A button's label, which says what pressing it does now.
fn labelOf(button: Button, s: *const State, is_fullscreen: bool) []const u8 {
    return switch (button) {
        .fullscreen => if (is_fullscreen) "leave fullscreen (F11)" else "enter fullscreen (F11)",
        .keep_awake => if (s.is_keeping_awake) "let the screen rest" else "keep the screen awake",
        .open_page => "open ziglang.org",
        .copy_address => "copy the address",
        .paste => "paste (or Ctrl+V)",
    };
}

fn update(f: *z.Frame, s: *State) void {
    const pointer: Vec2 = z.getMousePosition(f.input);
    const clicked: bool = z.isMouseButtonPressed(f.input, .left);
    const is_fullscreen: bool = f.window.fullscreen;
    if (z.isKeyPressed(f.input, .f11)) {
        z.requestFullscreen(!is_fullscreen);
    }
    if (z.getPastedText(f.input)) |pasted| {
        keepPaste(s, pasted);
    }
    z.clearViewport(f, background);
    for (std.enums.values(Button)) |button| {
        const rect: z.Rectangle = buttonRect(button);
        const is_hovered: bool = isInside(rect, pointer);
        if (is_hovered and clicked) {
            switch (button) {
                .fullscreen => z.requestFullscreen(!is_fullscreen),
                .keep_awake => {
                    s.is_keeping_awake = !s.is_keeping_awake;
                    z.keepAwake(s.is_keeping_awake);
                },
                .open_page => z.openUrl(page_address),
                .copy_address => z.setClipboardText(page_address),
                .paste => z.requestPaste(),
            }
        }
        f.gl.rect(rect, .{ .color = if (is_hovered) button_hovered else button_color });
        const label: []const u8 = labelOf(button, s, is_fullscreen);
        f.gl.text(.{ rect.x + 14, rect.y + 13 }, label, .{ .size = 18, .color = text_color, .font = &s.font });
    }
    const status_top: f32 = 52 + float(std.enums.values(Button).len) * 56 + 12;
    const fullscreen_text: []const u8 = if (is_fullscreen) "fullscreen: yes" else "fullscreen: no";
    const awake_text: []const u8 = if (s.is_keeping_awake) "screen kept awake: yes" else "screen kept awake: no";
    f.gl.text(.{ 16, status_top }, fullscreen_text, .{ .size = 16, .color = dim_color, .font = &s.font });
    f.gl.text(.{ 16, status_top + 24 }, awake_text, .{ .size = 16, .color = dim_color, .font = &s.font });
    const pasted_text: []const u8 = s.last_paste[0..s.last_paste_length];
    f.gl.textf(
        .{ 16, status_top + 48 },
        "last paste: {s}",
        .{pasted_text},
        .{ .size = 16, .color = dim_color, .font = &s.font },
    );
    common.caption(f.gl, s.font, "window_requests: fullscreen, a screen kept on, and a page opened");
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - window requests",
            .width = 640,
            .height = 520,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
