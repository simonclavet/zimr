// examples/ui_code_editor.zig - Phase A3 of the imgui-parity arc.
// Tiny "code editor" demonstrating:
//   - `Ui.inputTextMultiline(...)` - multi-line text editing with
//     Enter inserts newline, Up/Down arrow nav between lines,
//     click-to-place cursor on any line, Home/End line-aware.
//   - `Ui.pushFont(...)` / `Ui.popFont()` - scoped font swaps.
//     (Until a separate mono TTF is loaded, we use `pushStyle(
//     "font_size", ...)` for visual variety in the same default
//     font; the API surface is the point.)
//   - A simple line-number gutter rendered alongside the editor.
// Background: this is the "real-world" use case
// `inputTextMultiline` was designed for.  Note editors, in-game
// console fields, script tweakers - anything where Enter must
// mean "newline" not "submit and defocus."
// Limitations (per the A3 deliverable scope):
//   - No selection, no clipboard.  Both land in A4 with
//     `InputTextCallbackData`.
//   - No syntax highlighting.  That's a separate piece - the
//     editor's render path is `drawTextAtS` over the whole
//     buffer; coloring would need per-token submission.
//   - No scroll handling: the buffer is bounded to fit the
//     editor's height.  A scrollable variant is on the roadmap.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const Vec2 = zm.Vec2;
const Color = zm.Color;
const ui = z.ui_real;

const buf_cap: usize = 4096;
const max_lines: usize = 80;

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,

    code_buf: [buf_cap]u8 = undefined,
    code_len: usize = 0,
    last_change_frame: u32 = 0,

    show_gutter: bool = true,
    show_tutorial: bool = true,
};

const starter_code: []const u8 =
    \\const std = @import("std");
    \\
    \\pub fn main() void {
    \\    var sum: u32 = 0;
    \\    var i: u32 = 1;
    \\    while (i <= 10) : (i += 1) {
    \\        sum += i;
    \\    }
    \\    std.debug.print("sum = {d}\n", .{sum});
    \\}
;

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, @embedFile("atkinson_mono_ttf"), 22);
    s.* = .{ .ui_host = z.UiHost.init(gpa, font), .font = font };
    @memcpy(s.code_buf[0..starter_code.len], starter_code);
    s.code_len = starter_code.len;
}

/// Render N-row line-number gutter to the left of the editor.
/// Layout-only; uses `setCursorPos` to position each row and
/// `pushStyle`/`popStyle` to dim the text color.
fn drawGutter(
    u: ui.Ui,
    line_count: usize,
    top_left: Vec2,
    line_h: f32,
) void {
    u.pushStyle("text", Color{ .r = 120, .g = 130, .b = 140, .a = 255 });
    defer u.popStyle();
    var i: usize = 0;
    while (i < line_count) : (i += 1) {
        u.setCursorPos(.{ top_left[0], top_left[1] + float(i) * line_h });
        u.text("{d:>3}", .{i + 1});
    }
}

fn countLines(buf: []const u8) usize {
    var n: usize = 1;
    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        if (buf[i] == '\n') {
            n += 1;
        }
    }
    return n;
}

fn update(f: *z.Frame, s: *State) void {
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    if (u.window("Tiny code editor", .{
        .initial_pos = .{ 20, 20 },
        .initial_size = .{ 920, 600 },
    })) |w| {
        defer w.close();

        // Title in a larger font - exercises pushFont path via
        // pushStyle("font_size", ...).  The font itself stays the
        // default; we're showing the stack mechanism works.
        u.pushStyle("font_size", @as(f32, 16));
        u.text("inputTextMultiline + pushFont/popFont", .{});
        u.popStyle();

        u.textDisabled("Phase A3 - type freely; Enter inserts a newline.", .{});

        if (s.show_tutorial) {
            u.separator();
            u.bulletText("Click anywhere to place the cursor on that line.", .{});
            u.bulletText("Up / Down arrows move between lines (column preserved).", .{});
            u.bulletText("Home / End jump to start / end of CURRENT line.", .{});
            u.bulletText("Escape defocuses without committing.", .{});
        }
        u.separator();

        // Controls row.
        _ = u.checkbox("line-number gutter", &s.show_gutter);
        u.sameLine(.{});
        _ = u.checkbox("show tutorial", &s.show_tutorial);
        u.sameLine(.{});
        if (u.button("Reset to starter", .{})) {
            @memcpy(s.code_buf[0..starter_code.len], starter_code);
            s.code_len = starter_code.len;
        }

        u.separator();

        // The editor lives in a child so the gutter (rendered
        // before, via setCursorPos) and the editor (rendered after,
        // at the cursor-determined position) cohabit cleanly.
        const editor_top: Vec2 = u.getCursorPos();
        const style: z.ui_real.Style = s.ui_host.ctx.style;
        const line_h: f32 = style.font_size + float(style.line_spacing);
        const editor_h: f32 = 380;
        const gutter_w: f32 = if (s.show_gutter) 40 else 0;

        if (s.show_gutter) {
            const line_count: usize = @min(countLines(s.code_buf[0..s.code_len]), max_lines);
            drawGutter(u, line_count, editor_top, line_h);
            u.setCursorPos(.{ editor_top[0] + gutter_w, editor_top[1] });
        }

        // The multiline editor itself.  Pass remaining width (0 = auto-fill).
        const before_len: usize = s.code_len;
        const editor_w: f32 = 800 - gutter_w;
        _ = u.inputTextMultiline(
            "##editor",
            &s.code_buf,
            &s.code_len,
            .{ editor_w, editor_h },
            .{ .hint = "type some code..." },
        );
        if (s.code_len != before_len) {
            s.last_change_frame = @trunc(f.time.time * 60.0);
        }

        u.separator();

        // Status strip.
        u.labelText("buffer", "{d} / {d} bytes", .{ s.code_len, buf_cap });
        u.labelText("lines", "{d}", .{countLines(s.code_buf[0..s.code_len])});
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - ui_code_editor (Phase A3)",
            .width = 960,
            .height = 640,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
