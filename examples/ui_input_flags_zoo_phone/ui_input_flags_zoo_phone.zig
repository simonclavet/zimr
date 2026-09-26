// examples/ui_input_flags_zoo_phone.zig - bug-hunter phone example.
//
// Visual + interactive smoke test for every InputText flag added
// in turns 439 (P9.1 char filters) and 440 (P9.2 behavior flags).
// One card per flag (or pair-of-flags-that-compose-naturally).
// Each card:
//   - Has a tap-to-focus inputText
//   - Renders a live readout BELOW the field showing the buffer
//     content, length, and the function's return value
//   - States in plain English what the field is supposed to do
//     ("type letters - they should become uppercase," etc.)
//
// Why: turns 439-440 added 10 flags across two layers:
//   - 5 char filters (chars_decimal/hex/scientific/uppercase/no_blank)
//   - 5 behavior flags (enter_returns_true/escape_clears/
//     password_mask/read_only/allow_tab_input)
// Host-path unit tests cover the wasm-side edit engine.  The
// WEB-PATH wiring (4 new JS bindings, refactored showOverlayInput,
// extended keydown listener in zimr.ts) has NO coverage outside
// the JS bundle compiling.  This example exists to surface any
// browser-side regressions the moment they appear - the same
// methodology that found 4 engine bugs in turn 437b.
//
// How to use:
//   build_standalone.py ui_input_flags_zoo_phone
//   open the html in a phone browser
//   tap each field, type characters, watch the readout
// If a readout doesn't match the expected text in the card label,
// there's a bug.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const Color = zm.Color;
const ui = z.ui_real;

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,

    // Buffers, one per card.  64 bytes is generous for phone-typed
    // content; the password card uses one too even though its content
    // is short.  Independent buffers so each field's state is
    // observable in isolation.
    buf_decimal: [64]u8 = @splat(0),
    len_decimal: usize = 0,
    buf_hex: [64]u8 = @splat(0),
    len_hex: usize = 0,
    buf_scientific: [64]u8 = @splat(0),
    len_scientific: usize = 0,
    buf_uppercase: [64]u8 = @splat(0),
    len_uppercase: usize = 0,
    buf_no_blank: [64]u8 = @splat(0),
    len_no_blank: usize = 0,

    buf_password: [64]u8 = @splat(0),
    len_password: usize = 0,
    buf_readonly: [64]u8 = @splat(0),
    len_readonly: usize = 0,
    buf_search: [64]u8 = @splat(0),
    len_search: usize = 0,
    buf_cancel: [64]u8 = @splat(0),
    len_cancel: usize = 0,
    buf_tabbed: [64]u8 = @splat(0),
    len_tabbed: usize = 0,

    // Multiline buffers (turn 441b - textarea overlay).
    buf_notes: [256]u8 = @splat(0),
    len_notes: usize = 0,
    buf_chat: [256]u8 = @splat(0),
    len_chat: usize = 0,
    buf_code: [256]u8 = @splat(0),
    len_code: usize = 0,

    // "Last frame the widget returned true" - gets bumped on every
    // frame the function returns true, so the user can tell whether
    // the widget is reporting changes / commits as expected.
    last_true_search: u32 = 0,
    last_true_cancel: u32 = 0,
    last_true_chat: u32 = 0,

    frame: u32 = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

/// Escape `\n` -> `\\n` and `\t` -> `\\t` so a buffer with newlines
/// or tabs renders as a single line in the readout.  Without
/// this, `{s}` formatting expands newlines into real line breaks,
/// making the readout span multiple lines and overlap the next
/// widget below (the layout system sized the readout for one
/// line).  Caller provides scratch space >= 2x buffer length.
fn escapeForReadout(in: []const u8, scratch: []u8) []const u8 {
    var w: usize = 0;
    for (in) |c| {
        if (w >= scratch.len) {
            break;
        }
        switch (c) {
            '\n' => {
                if (w + 2 > scratch.len) {
                    break;
                }
                scratch[w] = '\\';
                scratch[w + 1] = 'n';
                w += 2;
            },
            '\t' => {
                if (w + 2 > scratch.len) {
                    break;
                }
                scratch[w] = '\\';
                scratch[w + 1] = 't';
                w += 2;
            },
            else => {
                scratch[w] = c;
                w += 1;
            },
        }
    }
    return scratch[0..w];
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, @embedFile("atkinson_mono_ttf"), 22);
    s.* = .{ .ui_host = z.UiHost.init(gpa, font), .font = font };
    // The password field starts with content so the masking is
    // immediately visible at first paint.
    const seed: []const u8 = "hunter2";
    @memcpy(s.buf_password[0..seed.len], seed);
    s.len_password = seed.len;
    // The read-only field has content the user can see but cannot
    // edit - verifies the gate works.
    const rseed: []const u8 = "id-7f3a";
    @memcpy(s.buf_readonly[0..rseed.len], rseed);
    s.len_readonly = rseed.len;
}

/// Render one card: label-with-expectation, the inputText, and a
/// readout line.  Keeps the visual structure consistent so the
/// user's eye can scan a long page quickly.
fn card(
    u: ui.Ui,
    label: []const u8,
    expect: []const u8,
    buf: []u8,
    len: *usize,
    opts: ui.InputTextOpts,
) bool {
    u.textColored(Color.hex(0xE0E0E0FF), "{s}", .{label});
    u.textColored(Color.hex(0x909090FF), "expect: {s}", .{expect});
    const changed: bool = u.inputText(label, buf, len, opts);
    // Readout: show what the buffer holds and its length.  This is
    // what makes the example a bug-hunter - every keypress the user
    // makes is reflected here, and any discrepancy with the
    // `expect:` line above is a bug.
    u.textColored(Color.hex(0x60D0FFFF), "buf=\"{s}\" len={d}", .{ buf[0..len.*], len.* });
    u.spacing();
    return changed;
}

fn update(f: *z.Frame, s: *State) void {
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    s.frame +%= 1;

    const fw: f32 = float(f.window.screen_width);
    const fh: f32 = float(f.window.screen_height);
    u.setNextWindowPos(.{ 0, 0 }, .{});
    u.setNextWindowSize(.{ fw, fh }, .{});
    if (u.window("zoo", .{
        .flags = .{
            .no_title_bar = true,
            .no_resize = true,
            .no_move = true,
            .no_collapse = true,
        },
    })) |w| {
        defer w.close();

        u.textColored(Color.hex(0xFFFFFFFF), "input flags zoo", .{});
        u.textColored(Color.hex(0x909090FF), "tap each field, type, watch the blue readout.", .{});
        u.separator();

        // ---- P9.1 char filters

        _ = card(
            u,
            "chars_decimal",
            "digits + . + - (no letters)",
            &s.buf_decimal,
            &s.len_decimal,
            .{ .chars_decimal = true, .input_mode = .decimal },
        );

        _ = card(
            u,
            "chars_hexadecimal",
            "0-9 a-f A-F only (no g, no .)",
            &s.buf_hex,
            &s.len_hex,
            .{ .chars_hexadecimal = true },
        );

        _ = card(
            u,
            "chars_scientific",
            "digits + . + - + e/E (1.5e-3 ok, x rejected)",
            &s.buf_scientific,
            &s.len_scientific,
            .{ .chars_scientific = true, .input_mode = .decimal },
        );

        _ = card(
            u,
            "chars_uppercase",
            "lowercase letters become uppercase (a -> A)",
            &s.buf_uppercase,
            &s.len_uppercase,
            .{ .chars_uppercase = true },
        );

        _ = card(
            u,
            "chars_no_blank",
            "space + tab rejected; type 'a b' yields 'ab'",
            &s.buf_no_blank,
            &s.len_no_blank,
            .{ .chars_no_blank = true },
        );

        u.separator();

        // ---- P9.2 behavior flags

        _ = card(
            u,
            "password_mask",
            "seed=hunter2, rendered as *******",
            &s.buf_password,
            &s.len_password,
            .{ .password_mask = true },
        );

        _ = card(
            u,
            "read_only",
            "id-7f3a — cannot type / cannot backspace",
            &s.buf_readonly,
            &s.len_readonly,
            .{ .read_only = true },
        );

        // For enter_returns_true: bump last_true_search whenever
        // the widget returns true.  Caller should observe the
        // counter ONLY when Enter is pressed (or focus drops on
        // web), not on every keystroke.
        const search_committed: bool = card(
            u,
            "enter_returns_true",
            "type chars (counter stable); press Enter (counter++)",
            &s.buf_search,
            &s.len_search,
            .{ .enter_returns_true = true },
        );
        if (search_committed) {
            s.last_true_search = s.frame;
        }
        u.textColored(Color.hex(0xFFB060FF), "  last commit at frame {d} (now {d})", .{
            s.last_true_search,
            s.frame,
        });
        u.spacing();

        // For escape_clears: type something, press Escape, buffer
        // should clear.  Pair with enter_returns_true so the user
        // can also verify that Esc is NOT counted as a commit on
        // host (counter stays put) but the buffer does clear.
        const cancel_committed: bool = card(
            u,
            "enter_returns_true + escape_clears",
            "type chars; Esc clears AND defocuses; commit counter unchanged",
            &s.buf_cancel,
            &s.len_cancel,
            .{ .enter_returns_true = true, .escape_clears = true },
        );
        if (cancel_committed) {
            s.last_true_cancel = s.frame;
        }
        u.textColored(Color.hex(0xFFB060FF), "  last commit at frame {d}", .{s.last_true_cancel});
        u.spacing();

        _ = card(
            u,
            "allow_tab_input",
            "press Tab — should insert \\t (visible as gap)",
            &s.buf_tabbed,
            &s.len_tabbed,
            .{ .allow_tab_input = true },
        );

        u.separator();
        u.textColored(Color.hex(0xFFFFFFFF), "multiline (textarea overlay)", .{});
        u.textColored(Color.hex(0x909090FF), "tap to open native textarea with soft keyboard.", .{});
        u.spacing();

        // ---- Multiline cards (turn 441b)

        u.textColored(Color.hex(0xE0E0E0FF), "default multiline", .{});
        u.textColored(Color.hex(0x909090FF), "expect: Enter inserts newline; multi-line input works", .{});
        _ = u.inputTextMultiline("notes", &s.buf_notes, &s.len_notes, .{ 380, 100 }, .{});
        var scratch_notes: [600]u8 = undefined;
        const esc_notes: []const u8 = escapeForReadout(s.buf_notes[0..s.len_notes], &scratch_notes);
        u.textColored(Color.hex(0x60D0FFFF), "buf=\"{s}\"  len={d}", .{ esc_notes, s.len_notes });
        u.spacing();

        u.textColored(Color.hex(0xE0E0E0FF), "chat box: ctrl_enter_for_newline + enter_returns_true", .{});
        u.textColored(Color.hex(0x909090FF), "expect: Enter commits (counter++); Ctrl+Enter inserts \\n", .{});
        const chat_committed: bool = u.inputTextMultiline("chat", &s.buf_chat, &s.len_chat, .{ 380, 100 }, .{
            .enter_returns_true = true,
            .ctrl_enter_for_newline = true,
        });
        if (chat_committed) {
            s.last_true_chat = s.frame;
        }
        var scratch_chat: [600]u8 = undefined;
        const esc_chat: []const u8 = escapeForReadout(s.buf_chat[0..s.len_chat], &scratch_chat);
        u.textColored(Color.hex(0x60D0FFFF), "buf=\"{s}\"  len={d}", .{ esc_chat, s.len_chat });
        u.textColored(Color.hex(0xFFB060FF), "  last commit at frame {d} (now {d})", .{ s.last_true_chat, s.frame });
        u.spacing();

        u.textColored(Color.hex(0xE0E0E0FF), "code editor: allow_tab_input multiline", .{});
        u.textColored(Color.hex(0x909090FF), "expect: Tab inserts \\t; doesn't lose focus", .{});
        _ = u.inputTextMultiline("code", &s.buf_code, &s.len_code, .{ 380, 100 }, .{
            .allow_tab_input = true,
        });
        var scratch_code: [600]u8 = undefined;
        const esc_code: []const u8 = escapeForReadout(s.buf_code[0..s.len_code], &scratch_code);
        u.textColored(Color.hex(0x60D0FFFF), "buf=\"{s}\"  len={d}", .{ esc_code, s.len_code });
        u.spacing();

        u.separator();
        u.textColored(Color.hex(0x909090FF), "if a field rejects what it should accept", .{});
        u.textColored(Color.hex(0x909090FF), "or accepts what it should reject — it's a bug.", .{});
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - input flags zoo (phone)",
            .width = 420,
            .height = 900,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
