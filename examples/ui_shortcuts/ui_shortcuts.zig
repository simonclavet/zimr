// examples/ui_shortcuts.zig - B2 capstone.
// Keyboard chords + Ui.shortcut: classic Ctrl+S save patterns,
// arrow-key navigation with auto-repeat, modifier strictness
// (Ctrl+S does NOT fire a bare S shortcut), Esc-to-clear.
// Each chord is listed with its display string, last-fired
// frame index, and current fire-count.  Press any of the
// listed combinations and watch the readout update.
// Demonstrates Phase B2 of the imgui-parity arc.

const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const ui = z.ui_real;

const Color = zm.Color;

const Binding = struct {
    label: []const u8,
    chord: ui.KeyChord,
    opts: ui.ShortcutOpts = .{},
};

const bindings = [_]Binding{
    .{ .label = "Ctrl+S   (save)", .chord = .{ .key = .s, .ctrl = true } },
    .{ .label = "Ctrl+Z   (undo)", .chord = .{ .key = .z, .ctrl = true } },
    .{ .label = "Ctrl+Shift+Z   (redo)", .chord = .{ .key = .z, .ctrl = true, .shift = true } },
    .{ .label = "Esc   (cancel)", .chord = .{ .key = .escape } },
    .{ .label = "Space   (toggle)", .chord = .{ .key = .space } },
    .{ .label = "Up arrow + repeat   (increment)", .chord = .{ .key = .up }, .opts = .{ .repeat = true } },
    .{ .label = "Down arrow + repeat   (decrement)", .chord = .{ .key = .down }, .opts = .{ .repeat = true } },
};

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,
    // Per-binding tracking.  `last_frame` is the frame index at the
    // most recent fire (so the row can highlight briefly); `count`
    // is the cumulative fire count.
    fires: [bindings.len]u32 = @splat(0),
    last_frame: [bindings.len]u32 = @splat(0),
    frame_index: u32 = 0,
    // Simulated app state driven by the shortcuts - a notepad save
    // dirtybit + an undo stack depth + a counter for arrow keys.
    dirty: bool = true,
    undo_depth: u8 = 0,
    counter: i32 = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, @embedFile("atkinson_mono_ttf"), 22);
    s.* = .{
        .ui_host = z.UiHost.init(gpa, font),
        .font = font,
    };
}

/// Mutate the demo's app state in response to a chord fire.  Modeling
/// the kinds of work a real editor / tool would do.  Pattern-matches
/// on the chord's primary key + modifier set - there's no map lookup
/// because the binding table is comptime.
fn applySideEffect(s: *State, chord: ui.KeyChord) void {
    switch (chord.key) {
        .s => if (chord.ctrl) {
            s.dirty = false; // Ctrl+S: save the doc.
        },
        .z => if (chord.ctrl) {
            if (chord.shift) {
                // Ctrl+Shift+Z: redo.
                s.undo_depth -|= 1;
                if (s.undo_depth != 0xff) {
                    s.dirty = true;
                }
            } else {
                // Ctrl+Z: undo.
                if (s.undo_depth < 99) {
                    s.undo_depth += 1;
                    s.dirty = true;
                }
            }
        },
        .escape => {
            // Cancel - reset counter, doc stays dirty if it was.
            s.counter = 0;
        },
        .space => {
            s.dirty = !s.dirty;
        },
        .up => s.counter += 1,
        .down => s.counter -= 1,
        else => {},
    }
}

fn update(f: *z.Frame, s: *State) void {
    const u: ui.Ui = s.ui_host.begin(f);

    s.frame_index += 1;

    z.clearViewport(f, .{ .r = 15, .g = 23, .b = 42, .a = 255 });

    const sw: i32 = @intCast(f.window.screen_width);

    const white: Color = .{ .r = 241, .g = 245, .b = 249, .a = 255 };
    const dim: Color = .{ .r = 148, .g = 163, .b = 184, .a = 255 };
    const accent: Color = .{ .r = 245, .g = 158, .b = 11, .a = 255 };
    const subtle: Color = .{ .r = 30, .g = 41, .b = 59, .a = 255 };
    const flash: Color = .{ .r = 251, .g = 191, .b = 36, .a = 255 };

    // Header.
    f.gl.text(.{ 24, 22 }, "keyboard shortcuts (B2)", .{ .size = 20, .color = white, .font = &s.font });
    f.gl.text(
        .{ 24, 54 },
        "press any combination below. modifier strictness is enforced.",
        .{ .size = 12, .color = dim, .font = &s.font },
    );

    // Bindings table.  Each chord checked once per frame; on fire the
    // matching row is highlighted briefly + a small wired state mutates.
    const row_h: i32 = 32;
    const row_pad: i32 = 4;
    var i: usize = 0;
    while (i < bindings.len) : (i += 1) {
        const bind: Binding = bindings[i];
        const row_y: i32 = 96 + @as(i32, @intCast(i)) * (row_h + row_pad);
        const fired: bool = u.shortcut(bind.chord, bind.opts);
        if (fired) {
            s.fires[i] += 1;
            s.last_frame[i] = s.frame_index;
            applySideEffect(s, bind.chord);
        }
        const flash_age: u32 = s.frame_index - s.last_frame[i];
        const recently_fired: bool = s.fires[i] > 0 and flash_age < 12;
        const bg: Color = if (recently_fired) flash else subtle;

        const rect: z.Rectangle = .{
            .x = 24,
            .y = @floatFromInt(row_y),
            .width = @floatFromInt(sw - 48),
            .height = @floatFromInt(row_h),
        };
        f.gl.rect(rect, .{ .color = bg });

        // Label on the left.
        const label_color: Color = if (recently_fired) subtle else white;
        f.gl.text(.{ 36, float(row_y + 10) }, bind.label, .{ .size = 12, .color = label_color, .font = &s.font });

        // Fire count on the right.
        var buf: [32]u8 = undefined;
        const count_text: []const u8 = bufPrint(&buf, "fires: {d}", .{s.fires[i]}) catch "?";
        const cx: f32 = float(sw - 130);
        const cy: f32 = float(row_y + 10);
        f.gl.text(.{ cx, cy }, count_text, .{ .size = 12, .color = label_color, .font = &s.font });
    }

    // Wired state readout - proves that the shortcuts are doing
    // real work, not just incrementing a counter.
    const status_y: i32 = 96 + @as(i32, @intCast(bindings.len)) * (row_h + row_pad) + 24;
    var status_buf: [128]u8 = undefined;
    const status: []const u8 = bufPrint(
        &status_buf,
        "doc state - dirty: {s} | undo depth: {d} | counter: {d}",
        .{
            if (s.dirty) "yes" else "no",
            s.undo_depth,
            s.counter,
        },
    ) catch "?";
    f.gl.text(.{ 24, status_y }, status, .{ .size = 14, .color = accent, .font = &s.font });
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - ui shortcuts (B2 capstone)",
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
