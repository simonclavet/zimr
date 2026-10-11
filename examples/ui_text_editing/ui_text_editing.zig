//! ui_text_editing - the editing of text fields: selection by keyboard and mouse, the shortcuts of a text editor,
//! undo and redo, Escape, scrolling, filters, and fields of several lines.
//!
//! An active field is edited in one of two ways. In the browser, the page's own editor does it - an `<input>` or a
//! `<textarea>` placed over the field - with all the browser offers: its selection and undo, the input methods of
//! Chinese, Japanese and Korean, a phone's keyboard. Natively, zimr edits the text itself with the UI's editing core
//! (`text_edit` in ui.zig), and every field below shows a part of what that core does; the panel at the bottom lists
//! the keys and mouse actions it answers. An input method for Chinese, Japanese or Korean composes text at the caret
//! of the active field, in the browser and natively alike; natively it is off outside text fields and for a password.
//!
//! Each field starts with text that shows its feature: a line longer than its field, which scrolls with the caret;
//! accented words, edited a whole character at a time; a password, which has no words for Ctrl+arrows to stop at
//! and copies nothing; notes of several lines, one of them long; and a read-only log taller than its field, which
//! the wheel scrolls whether the field is active or not.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const bufPrint = std.fmt.bufPrint;
const z = @import("zimr");
const ui = z.ui_real;

/// Whether this build runs in the browser, where the page's own editor edits the fields.
const is_web: bool = builtin.target.cpu.arch.isWasm();

/// A field's text: its storage, `capacity` bytes, and how many of them the text uses - the pair a text field edits.
fn FieldText(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = undefined,
        len: usize = 0,

        const Self = @This();

        /// Starts the field with `initial`, as much of it as fits.
        fn set(field: *Self, initial: []const u8) void {
            const kept: usize = @min(initial.len, capacity);
            @memcpy(field.bytes[0..kept], initial[0..kept]);
            field.len = kept;
        }

        fn text(field: *const Self) []const u8 {
            return field.bytes[0..field.len];
        }
    };
}

const line_capacity: usize = 256;
const notes_capacity: usize = 4096;
const log_capacity: usize = 4096;

const long_line_text: []const u8 = "A line longer than its field: type at its end, or press End, and the text " ++
    "scrolls a quarter of the field at a time so the caret stays in view.";
const accents_text: []const u8 = "Ångström, café, naïve, über, smörgåsbord";
const password_text: []const u8 = "correct horse battery staple";
const clears_text: []const u8 = "Escape empties this field";
const notes_text: []const u8 =
    \\Notes, in a field of several lines.
    \\
    \\Up and Down keep the caret's x: go down through the short line below and back.
    \\ab
    \\Page Up and Page Down move by the lines the field shows; Home and End go to the line's ends, and with Ctrl
    \\to the text's.
    \\
    \\A line far longer than the field scrolls it sideways as the caret goes along it, and back when the caret returns.
    \\Enter breaks a line; undo takes back a word, or a new line, at a time.
    \\Triple-click selects a line; drag above or below the field to scroll while selecting.
    \\The end.
;

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,
    name: FieldText(line_capacity) = .{},
    long_line: FieldText(line_capacity) = .{},
    accents: FieldText(line_capacity) = .{},
    password: FieldText(line_capacity) = .{},
    digits: FieldText(line_capacity) = .{},
    clears: FieldText(line_capacity) = .{},
    notes: FieldText(notes_capacity) = .{},
    log: FieldText(log_capacity) = .{},
    /// The name as it was when Enter last committed it.
    committed_name: FieldText(line_capacity) = .{},
    has_committed: bool = false,
};

/// Fills the log with forty lines, more than its field shows, so the wheel has somewhere to go.
fn fillLog(log: *FieldText(log_capacity)) void {
    var used: usize = 0;
    for (1..41) |line_number| {
        const separator: []const u8 = if (line_number == 1) "" else "\n";
        const written: []const u8 = bufPrint(
            log.bytes[used..],
            "{s}frame {d:0>3}: {d} fields drawn, one active",
            .{ separator, line_number * 16, 8 },
        ) catch break;
        used += written.len;
    }
    log.len = used;
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, @embedFile("atkinson_mono_ttf"), 22);
    s.* = .{ .ui_host = z.UiHost.init(gpa, font), .font = font };
    s.long_line.set(long_line_text);
    s.accents.set(accents_text);
    s.password.set(password_text);
    s.clears.set(clears_text);
    s.notes.set(notes_text);
    fillLog(&s.log);
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

/// The fields of one line, each showing a feature.
fn singleLineFields(u: ui.Ui, s: *State) void {
    u.text("Fields of one line", .{});
    const committed: bool = u.inputText("Name", &s.name.bytes, &s.name.len, .{
        .width = 420,
        .hint = "type a name, then Enter",
        .enter_returns_true = true,
    });
    if (committed) {
        s.committed_name.set(s.name.text());
        s.has_committed = true;
    }
    if (s.has_committed) {
        u.textDisabled("Enter committed: \"{s}\"", .{s.committed_name.text()});
    }
    _ = u.inputText("Long line", &s.long_line.bytes, &s.long_line.len, .{ .width = 420 });
    _ = u.inputText("Accents", &s.accents.bytes, &s.accents.len, .{ .width = 420 });
    _ = u.inputText("Password", &s.password.bytes, &s.password.len, .{ .width = 420, .password_mask = true });
    u.textDisabled("A password has no words for Ctrl+arrows to stop at, and copies nothing.", .{});
    _ = u.inputText("Digits", &s.digits.bytes, &s.digits.len, .{
        .width = 420,
        .hint = "digits only - typed or pasted",
        .chars_decimal = true,
    });
    _ = u.inputText("Clears", &s.clears.bytes, &s.clears.len, .{ .width = 420, .escape_clears = true });
}

/// The fields of several lines: notes to edit, and a log to read and scroll.
fn multilineFields(u: ui.Ui, s: *State) void {
    u.text("Fields of several lines", .{});
    _ = u.inputTextMultiline("Notes", &s.notes.bytes, &s.notes.len, .{ 560, 170 }, .{});
    _ = u.inputTextMultiline("Log", &s.log.bytes, &s.log.len, .{ 560, 110 }, .{ .read_only = true });
    u.textDisabled("The wheel scrolls either field under the mouse, active or not.", .{});
}

/// The keys and mouse actions the editing core answers.
fn keysPanel(u: ui.Ui) void {
    u.text("Keys and mouse", .{});
    u.bulletText("Shift with any move selects; Ctrl moves by word.", .{});
    u.bulletText("Ctrl+A selects all; Ctrl+C, Ctrl+X, Ctrl+V copy, cut and paste.", .{});
    u.bulletText("Ctrl+Insert, Shift+Delete and Shift+Insert copy, cut and paste too.", .{});
    u.bulletText("Ctrl+Z undoes a word at a time; Ctrl+Y or Ctrl+Shift+Z redoes.", .{});
    u.bulletText("Ctrl+Backspace and Ctrl+Delete delete a word.", .{});
    u.bulletText("Double-click selects a word, triple-click the line; drag to select, Shift+click to extend.", .{});
    u.bulletText("Escape puts back the text the field had when it became active.", .{});
    u.bulletText("Several lines: Up and Down keep the caret's x; Page Up, Page Down; Ctrl+Home, Ctrl+End.", .{});
    u.bulletText("An input method for Chinese, Japanese or Korean composes at the caret.", .{});
    u.bulletText("Outside text fields, and in a password, the input method is off.", .{});
}

fn update(f: *z.Frame, s: *State) void {
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);
    if (u.window("Text editing", .{ .initial_pos = .{ 20, 20 }, .initial_size = .{ 780, 860 } })) |window| {
        defer window.close();
        const editor_note: []const u8 = if (is_web)
            "In the browser, the page's own editor edits the active field."
        else
            "Natively, zimr's editing core edits the active field.";
        u.textDisabled("{s}", .{editor_note});
        u.separator();
        singleLineFields(u, s);
        u.separator();
        multilineFields(u, s);
        u.separator();
        keysPanel(u);
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - UI text editing",
            .width = 820,
            .height = 900,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
