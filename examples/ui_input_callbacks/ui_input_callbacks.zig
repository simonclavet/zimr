// examples/ui_input_callbacks.zig - Phase A4 of the imgui-parity arc.
// Demonstrates the `InputTextOpts` callback slots - the imgui-
// parity equivalent of `ImGuiInputTextCallbackData` adapted to
// zimr's caller-owned-buffer model.  Four widgets, one per
// callback type:
//   - **Decimal-only** - `char_filter` callback rejects every
//     non-digit codepoint.  Type letters; nothing appears.
//   - **Password mask** - `edit` callback maintains a parallel
//     "what to display" buffer where every char is replaced with
//     '*'.  Real characters stored in the actual buffer.
//   - **Autocomplete** - `completion` callback (Tab key) looks at
//     the current buffer prefix and replaces it with the matching
//     dictionary entry.  Try typing "imm" then Tab.
//   - **Command history** - `history` callback (Up/Down arrows)
//     scrolls through a fixed list of past commands.
// What this exercises that A1-A3 didn't: the callback dispatch
// pipeline.  The same `InputTextCallback` signature carries
// CharFilter, Completion, History, and Edit events - the slot
// the callback is wired into determines which event delivers
// it.  Caller state flows through `InputTextOpts.user_data`
// (an opaque pointer, cast typed inside each callback).

const std = @import("std");
const startsWith = std.mem.startsWith;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const ui = z.ui_real;

// Callback state - one struct per widget.  These are the typed
// targets the `user_data` pointers cast back to.
const PasswordState = struct {
    mask: [64]u8 = std.mem.zeroes([64]u8),
    mask_len: usize = 0,
    show_plaintext: bool = false,
};

const Dictionary = struct {
    words: []const []const u8,
};

const History = struct {
    entries: [8][]const u8 = .{
        "git status",
        "git log --oneline -10",
        "git checkout main",
        "zig build smoke-test",
        "zig fmt --check src/",
        "grep -rnE 'TODO' src/",
        "ls -la zig-out/web/",
        "python3 scripts/build_standalone.py basic",
    },
    cursor: usize = 0,
};

// Callbacks.  Each receives an `*InputTextCallbackData` whose
// `event` field tells it which slot fired.  `data.user_data` is
// the opaque pointer set via `InputTextOpts.user_data`.
/// Drop non-digit codepoints.  Stateless - no `user_data` needed.
fn decimalFilter(data: *ui.InputTextCallbackData) void {
    const cp: u32 = data.event_char;
    const is_digit: bool = cp >= '0' and cp <= '9';
    if (!is_digit) {
        data.event_char = 0;
    }
}

/// After every edit, refresh the mask buffer from the real buffer.
/// One '*' per real char.  The display field then shows the mask.
fn passwordEdit(data: *ui.InputTextCallbackData) void {
    const state: *PasswordState = @ptrCast(@alignCast(data.user_data.?));
    const real_len: usize = data.buf_len.*;
    const n: usize = @min(real_len, state.mask.len);
    @memset(state.mask[0..n], '*');
    state.mask_len = n;
}

/// Tab pressed in single-line.  Find the longest dictionary word
/// that starts with the current buffer; if found, replace the
/// buffer with that word.
fn autocompleteTab(data: *ui.InputTextCallbackData) void {
    const dict: *const Dictionary = @ptrCast(@alignCast(data.user_data.?));
    const current: []const u8 = data.buf[0..data.buf_len.*];
    if (current.len == 0) {
        return;
    }
    for (dict.words) |w| {
        if (w.len < current.len) {
            continue;
        }
        const prefix_match: bool = startsWith(u8, w, current);
        if (prefix_match) {
            _ = data.setBuffer(w);
            return;
        }
    }
}

/// Up / Down arrow in single-line.  Replace buffer with the prior
/// (or next) history entry.
fn historyArrow(data: *ui.InputTextCallbackData) void {
    const hist: *History = @ptrCast(@alignCast(data.user_data.?));
    switch (data.history_dir) {
        .up => {
            if (hist.cursor > 0) {
                hist.cursor -= 1;
            }
        },
        .down => {
            if (hist.cursor + 1 < hist.entries.len) {
                hist.cursor += 1;
            }
        },
    }
    _ = data.setBuffer(hist.entries[hist.cursor]);
}

// App state.
const State = struct {
    ui_host: z.UiHost,
    font: z.Font,

    // Decimal-only field.
    age_buf: [16]u8 = std.mem.zeroes([16]u8),
    age_len: usize = 0,

    // Password field.
    pwd_buf: [64]u8 = std.mem.zeroes([64]u8),
    pwd_len: usize = 0,
    pwd_state: PasswordState = .{},

    // Autocomplete.
    auto_buf: [64]u8 = std.mem.zeroes([64]u8),
    auto_len: usize = 0,

    // History.
    hist_buf: [64]u8 = std.mem.zeroes([64]u8),
    hist_len: usize = 0,
    history: History = .{},
};

// Dictionary lives at module scope as a `const` (not `var`), so
// it satisfies Rule 9 - no module-level mutable globals.
const dict_words = [_][]const u8{
    "immediate",  "imgui",       "implement", "implicit", "import",
    "improve",    "include",     "increment", "indent",   "index",
    "initialize", "input",       "insert",    "inspect",  "install",
    "instance",   "instantiate", "integer",   "interact", "interface",
};
const dictionary = Dictionary{ .words = &dict_words };

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, @embedFile("atkinson_mono_ttf"), 22);
    s.* = .{ .ui_host = z.UiHost.init(gpa, font), .font = font };
}

fn update(f: *z.Frame, s: *State) void {
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    if (u.window("inputText callbacks", .{
        .initial_pos = .{ 20, 20 },
        .initial_size = .{ 680, 560 },
    })) |w| {
        defer w.close();

        u.text("Phase A4 - InputTextCallbackData.", .{});
        u.textDisabled("Four widgets, one per callback slot.", .{});
        u.separator();

        // ---- Decimal-only (char_filter)
        u.text("1. CharFilter - type anything; only digits pass through:", .{});
        _ = u.inputText("Age", &s.age_buf, &s.age_len, .{
            .width = 200,
            .char_filter = decimalFilter,
        });
        u.textDisabled("(buffer: \"{s}\")", .{s.age_buf[0..s.age_len]});

        u.separator();

        // ---- Password mask (edit)
        u.text("2. Edit - buffer holds the real chars, display shows '*':", .{});
        _ = u.checkbox("show plaintext", &s.pwd_state.show_plaintext);
        _ = u.inputText("Password", &s.pwd_buf, &s.pwd_len, .{
            .width = 240,
            .edit = passwordEdit,
            .user_data = &s.pwd_state,
        });
        if (s.pwd_state.show_plaintext) {
            u.textDisabled("(plaintext: \"{s}\")", .{s.pwd_buf[0..s.pwd_len]});
        } else {
            u.textDisabled("(masked: \"{s}\")", .{s.pwd_state.mask[0..s.pwd_state.mask_len]});
        }

        u.separator();

        // ---- Autocomplete (completion)
        u.text("3. Completion - type a prefix, press Tab.  Try \"imm\":", .{});
        _ = u.inputText("Word", &s.auto_buf, &s.auto_len, .{
            .width = 320,
            .completion = autocompleteTab,
            .user_data = @ptrCast(@constCast(&dictionary)),
        });
        u.textDisabled("Dictionary: {d} words starting with i-...", .{dict_words.len});

        u.separator();

        // ---- History (history)
        u.text("4. History - Up/Down arrows scroll through prior commands:", .{});
        _ = u.inputText("Command", &s.hist_buf, &s.hist_len, .{
            .width = 460,
            .history = historyArrow,
            .user_data = &s.history,
        });
        u.textDisabled("(cursor: {d} of {d})", .{ s.history.cursor + 1, s.history.entries.len });

        u.separator();

        u.text("Implementation notes:", .{});
        u.bulletText("Each slot is an optional InputTextCallback pointer on InputTextOpts.", .{});
        u.bulletText("CharFilter + Edit fire in both inputText and inputTextMultiline.", .{});
        u.bulletText("Completion (Tab) + History (Up/Down) fire only in single-line.", .{});
        u.bulletText("user_data is opaque; caller casts to whatever typed state they need.", .{});
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - ui_input_callbacks (Phase A4)",
            .width = 720,
            .height = 600,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
