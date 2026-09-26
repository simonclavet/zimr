// examples/undo_redo.zig - snapshot-based undo / redo over an edited string.
// Ports raylib's core `undo_redo`: every edit pushes a snapshot of the text, so
// undo/redo is just moving a cursor through that history (and a fresh edit drops
// whatever redo branch was ahead of it).
//
// Editing is driven by UI BUTTONS (word buttons, Backspace, Undo, Redo) so the
// whole example is testable by tapping on a phone. A hardware keyboard still
// works too: typed characters arrive via `z.getCharPressed`, and Backspace via
// `isKeyPressed` - both feed the exact same edit path as the buttons.
//
// What this exercises (the engine work this drove):
//   - `z.getCharPressed(f.input)` - the typed-character queue (raylib's
//     GetCharPressed), newly exported for text input.
//
// Leak-clean (`.memory = .managed`): the UiHost is deinit'd; the atlas is
// engine-owned.

const std = @import("std");
const Allocator = std.mem.Allocator;

const z = @import("zimr");
const zm = @import("zm");

// Atkinson Hyperlegible Mono - the Braille Institute's legibility font.
// Distinct letterforms (slashed zero, unambiguous I/l/1), and a deliberate
// break from raylib's look. Latin-only content, so its cmap is plenty:
// ASCII + Latin-1 accented in full. (It has NO Cyrillic and almost no Greek,
// which is why the Unicode examples stay on RobotoMono.)
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const Color = zm.Color;
const c = Color;

const max_len: usize = 96;
const max_hist: usize = 64;

/// One point in the edit history: the whole string, not a diff. Snapshots are
/// the simplest correct undo model - no inverse operations to get wrong.
const Snapshot = struct {
    buf: [max_len]u8 = undefined,
    len: usize = 0,

    fn text(self: *const Snapshot) []const u8 {
        return self.buf[0..self.len];
    }
};

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,
    ui_font: z.Font,
    history: [max_hist]Snapshot = @splat(.{}),
    hist_count: usize = 1, // index 0 is the initial empty snapshot
    hist_pos: usize = 0,
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const ui_font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24);
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 28);
    s.* = .{ .ui_host = z.UiHost.init(gpa, ui_font), .font = font, .ui_font = ui_font };
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    z.unloadFont(gpa, s.ui_font);
    s.ui_host.deinit();
}

fn current(s: *const State) *const Snapshot {
    return &s.history[s.hist_pos];
}

/// Commit `work` as a new state: drop any redo branch (everything after the
/// cursor), then append - sliding the window down if the history is full.
fn pushState(s: *State, work: Snapshot) void {
    if (s.hist_pos + 1 >= max_hist) {
        for (0..max_hist - 1) |i| {
            s.history[i] = s.history[i + 1];
        }
        s.history[max_hist - 1] = work;
        s.hist_count = max_hist;
        s.hist_pos = max_hist - 1;
        return;
    }
    s.history[s.hist_pos + 1] = work;
    s.hist_pos += 1;
    s.hist_count = s.hist_pos + 1;
}

fn appendText(s: *State, add: []const u8) void {
    var work: Snapshot = s.history[s.hist_pos];
    for (add) |ch| {
        if (work.len < max_len) {
            work.buf[work.len] = ch;
            work.len += 1;
        }
    }
    pushState(s, work);
}

fn backspace(s: *State) void {
    var work: Snapshot = s.history[s.hist_pos];
    if (work.len == 0) {
        return;
    }
    work.len -= 1;
    pushState(s, work);
}

fn undo(s: *State) void {
    if (s.hist_pos > 0) {
        s.hist_pos -= 1;
    }
}

fn redo(s: *State) void {
    if (s.hist_pos + 1 < s.hist_count) {
        s.hist_pos += 1;
    }
}

fn update(f: *z.Frame, s: *State) void {
    const fw: f32 = f.window.widthf();

    // Hardware keyboard, if there is one - same edit path as the buttons.
    var typed: [max_len]u8 = undefined;
    var typed_len: usize = 0;
    while (z.getCharPressed(f.input)) |cp| {
        if (cp >= 32 and cp < 127 and typed_len < max_len) {
            typed[typed_len] = @intCast(cp);
            typed_len += 1;
        }
    }
    if (typed_len > 0) {
        appendText(s, typed[0..typed_len]);
    }
    if (z.isKeyPressed(f.input, .backspace)) {
        backspace(s);
    }

    z.clearViewport(f, c.raywhite);

    const u: z.ui_real.Ui = s.ui_host.begin(f);

    u.setNextWindowPos(.{ 8, 8 }, .{});
    u.setNextWindowSize(.{ fw - 16.0, 290 }, .{});
    if (u.window("Edit", .{})) |w| {
        defer w.close();
        u.text("Tap words to append. Every edit pushes a", .{});
        u.text("snapshot; Undo/Redo walk the history.", .{});
        u.separator();

        if (u.button("zimr ", .{})) {
            appendText(s, "zimr ");
        }
        u.sameLine(.{});
        if (u.button("undo ", .{})) {
            appendText(s, "undo ");
        }
        u.sameLine(.{});
        if (u.button("redo ", .{})) {
            appendText(s, "redo ");
        }

        if (u.button("rocks! ", .{})) {
            appendText(s, "rocks! ");
        }
        u.sameLine(.{});
        if (u.button("Backspace", .{})) {
            backspace(s);
        }

        u.separator();
        if (u.button("<< UNDO", .{})) {
            undo(s);
        }
        u.sameLine(.{});
        if (u.button("REDO >>", .{})) {
            redo(s);
        }
        u.text("history: {d} / {d}", .{ s.hist_pos + 1, s.hist_count });
    }

    // The edited text, drawn plainly so the history is the visible subject.
    const cur: *const Snapshot = current(s);
    const box: z.Rectangle = .{ .x = 16, .y = 320, .width = fw - 32.0, .height = 60 };
    f.gl.rect(box, .{ .color = .{ .r = 236, .g = 236, .b = 242, .a = 255 } });
    f.gl.rect(box, .{ .color = c.gray, .outline = 2 });
    // Caret sits at the true end of the text. MEASURE it - don't assume a
    // monospace advance (`len * size * 0.6` was visibly off to the right):
    // measureText walks the font's real per-glyph advances, so this is exact for
    // any font, proportional or not.
    const text_size: f32 = 24.0;
    const text_w: f32 = z.measureText(s.font, cur.text(), text_size)[0];
    f.gl.text(
        .{ box.x + 10, box.y + 16 },
        cur.text(),
        .{ .size = text_size, .color = c.black, .font = &s.font },
    );

    // Blinking caret at the measured end of the string.
    if (@mod(f.time.time, 1.0) < 0.5) {
        const caret_x: f32 = box.x + 10.0 + text_w;
        f.gl.rect(
            .{ .x = caret_x, .y = box.y + 14.0, .width = 2, .height = 30 },
            .{ .color = c.maroon },
        );
    }

    s.ui_host.render(f);
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - core - undo / redo",
            .width = 800,
            .height = 450,
            .scale_mode = .responsive,
            .depth_format = null,
            .clear = .{ .r = 245.0 / 255.0, .g = 245.0 / 255.0, .b = 245.0 / 255.0, .a = 1.0 },
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
    .memory = .managed,
};
