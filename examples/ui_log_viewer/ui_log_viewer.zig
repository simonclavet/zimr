// examples/ui_log_viewer.zig - Phase A1 + Phase 1.1 of the imgui-parity arc.
// Phone-readable from the start: canvas uses `.scale = .responsive` so
// it tracks the browser viewport, font_size is bumped to 16 (vs the
// 10-px bitmap default), and frame_padding is 10×8 so buttons hit the
// ~44-px touch-target sweet spot.  Window sized 380×840 to fit a phone
// portrait viewport; desktop users see it as a floating panel.
// Phase A1 features (already shipping):
//   - `setScrollHereY(1.0)` - auto-scroll-to-bottom when new
//     log lines arrive.
//   - `getScrollY` / `getScrollMaxY` - read scroll state.
//   - `setScrollY(0)` - jump-to-top button.
//   - `setClipboardText` - copy the entire log buffer to system
//     clipboard.
// Phase 1.1 features (added in step 1.1):
//   - `separatorText("Controls" / "Log" / "Status")` - section the panel
//     into named bands instead of plain rules.
//   - `value("lines", n)` / `value("cap", N)` / etc.
//     one-liner read-only HUD entries, comptime-dispatched on type.
//   - `textLinkOpenURL("[?]", url)` - clickable link on each ERROR
//     line that opens imgui's source on github (placeholder for "log
//     line takes you to docs about that error").  Hover tooltips show
//     the URL; right-click → "Copy link" works on desktop (phone
//     long-press support arrives with step 2.2).
//   - `invisibleButton("help-toggle", .{ 0, 36 })` - a 36-px hidden
//     hit zone at the bottom of the window that toggles a help text on
//     tap, with a textDisabled hint above pointing at it.
// Background: this is the canonical use case the scroll API was
// designed for.  Without `setScrollHereY` a log viewer either
// renders forever-growing content (window auto-resizes off-screen)
// or pins to a fixed top (stale data scrolls off).  The "stick to
// bottom unless the user is actively scrolling up" pattern below
// is the imgui demo's exact recipe.
// Controls:
//   - SPACE: emit 1 new log line (so you can watch auto-scroll).
//   - C: copy entire log to clipboard.
//   - T: jump to top.
//   - B: jump to bottom.

const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const ui = z.ui_real;

const log_cap: usize = 5000;
const line_max: usize = 96;

const LogLine = struct {
    buf: [line_max]u8 = undefined,
    len: usize = 0,

    fn text(self: *const LogLine) []const u8 {
        return self.buf[0..self.len];
    }
};

const Severity = enum {
    info,
    warn,
    err,

    fn label(self: Severity) []const u8 {
        return switch (self) {
            .info => "INFO ",
            .warn => "WARN ",
            .err => "ERROR",
        };
    }

    fn color(self: Severity) Color {
        return switch (self) {
            .info => .{ .r = 156, .g = 163, .b = 175, .a = 255 },
            .warn => .{ .r = 251, .g = 191, .b = 36, .a = 255 },
            .err => .{ .r = 248, .g = 113, .b = 113, .a = 255 },
        };
    }
};

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,

    lines: [log_cap]LogLine = std.mem.zeroes([log_cap]LogLine),
    severities: [log_cap]Severity = @splat(.info),
    line_count: usize = 0,

    auto_scroll: bool = true,
    paused: bool = false,
    next_seq: u32 = 0,
    rng: std.Random.DefaultPrng,

    // Scratch buffer for "copy all to clipboard."  Sized for the
    // worst case (every log line joined with newlines); written
    // fresh on each copy, only the live prefix is meaningful.
    // Lives on State (not module-global) per style rule 9.
    clipboard_scratch: [log_cap * (line_max + 1)]u8 = undefined,

    // Per-frame pending action set by buttons / keys, applied after
    // the log scroll region renders (so the cursor query inside
    // `setScrollHereY` is meaningful).
    pending_jump: enum { none, top, bottom } = .none,
    pending_copy: bool = false,

    // Substring filter - phase 1.2 demo.  Persistent across frames so
    // the user's typed query survives the auto-emission redraw.
    // Empty by default → passFilter says "yes" to everything.
    filter: ui.TextFilter = .{},
    // Count of lines that pass the filter this frame.  Recomputed
    // inside the line-rendering loop; surfaced in the Status section
    // so the user can see filtering is actually working.
    visible_count: usize = 0,

    // Phase 1.1 demo state: the help block at the bottom of the panel
    // is hidden by default and toggled by tapping the 28-px-tall
    // invisible button below the HUD strip.
    show_help: bool = false,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn appendLine(s: *State) void {
    if (s.line_count == log_cap) {
        return;
    }
    const r: std.Random = s.rng.random();
    s.next_seq += 1;

    // Three severity buckets, weighted 70/20/10.
    const roll = r.intRangeAtMost(u8, 0, 99);
    const sev: Severity = if (roll < 70) .info else if (roll < 90) .warn else .err;

    const subsystems: [10][]const u8 = .{
        "net",
        "auth",
        "db",
        "cache",
        "ws",
        "ipc",
        "render",
        "physics",
        "scheduler",
        "fs",
    };
    const sub: []const u8 = subsystems[r.intRangeLessThan(usize, 0, subsystems.len)];

    const info_msgs: [5][]const u8 = .{
        "connection established",
        "tick budget held",
        "warm cache hit",
        "frame submitted",
        "session refreshed",
    };
    const warn_msgs: [5][]const u8 = .{
        "retry budget halved",
        "queue depth high",
        "slow query (>500ms)",
        "GC pressure rising",
        "drift exceeds threshold",
    };
    const err_msgs: [5][]const u8 = .{
        "handshake failed",
        "deadline missed",
        "lost peer ack",
        "cascade rollback",
        "schema mismatch",
    };
    const msg: []const u8 = switch (sev) {
        .info => info_msgs[r.intRangeLessThan(usize, 0, info_msgs.len)],
        .warn => warn_msgs[r.intRangeLessThan(usize, 0, warn_msgs.len)],
        .err => err_msgs[r.intRangeLessThan(usize, 0, err_msgs.len)],
    };

    const slot: *LogLine = &s.lines[s.line_count];
    const w: []u8 = bufPrint(
        &slot.buf,
        "[{d:0>5}] {s} {s}: {s}",
        .{ s.next_seq, sev.label(), sub, msg },
    ) catch slot.buf[0..0];
    slot.len = w.len;
    s.severities[s.line_count] = sev;
    s.line_count += 1;
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, @embedFile("atkinson_mono_ttf"), 22);
    s.* = .{
        .ui_host = z.UiHost.init(gpa, font),
        .font = font,
        .rng = std.Random.DefaultPrng.init(0xa17a),
    };

    // Phone readability: load the bundled TTF (Atkinson Hyperlegible Mono),
    // bind it as the UI's active font, bump font_size to 16, and grow
    // frame_padding so buttons read as real touch targets.
    // **Both halves of the wiring matter.**  Setting `style.font_size = 16`
    // without `style.font = &loaded_ttf` leaves the UI rendering against
    // the size-10 bitmap fallback (`style.font = null`) at scale 1.6×
    // which the bitmap path doesn't handle, so widgets render blank.
    // `loadFontFromTtfBytes` populates the cache; we have to point Style at it.

    // Seed with 80 lines so the viewer opens populated.
    var i: usize = 0;
    while (i < 80) : (i += 1) {
        appendLine(s);
    }
}

/// Join every log line with '\n' into the State's scratch buffer
/// and push to the clipboard.  Worst-case buffer size is
/// `log_cap * (line_max + 1)` bytes; lines that would overflow
/// are dropped (caller sees a truncated copy rather than a
/// crash).
fn copyAll(u: ui.Ui, s: *State) void {
    const buf: []u8 = &s.clipboard_scratch;
    var off: usize = 0;
    var i: usize = 0;
    while (i < s.line_count) : (i += 1) {
        const line: []const u8 = s.lines[i].text();
        const needed: usize = line.len + 1;
        if (off + needed > buf.len) {
            break;
        }
        @memcpy(buf[off .. off + line.len], line);
        off += line.len;
        buf[off] = '\n';
        off += 1;
    }
    u.setClipboardText(buf[0..off]);
}

fn update(f: *z.Frame, s: *State) void {
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    // Background log emission - at ~10 lines/sec while not paused.
    if (!s.paused) {
        const r: std.Random = s.rng.random();
        if (r.intRangeAtMost(u8, 0, 5) == 0) {
            appendLine(s);
        }
    }

    // Keyboard shortcuts.
    if (z.isKeyPressed(f.input, .space)) {
        appendLine(s);
    }
    if (z.isKeyPressed(f.input, .c)) {
        s.pending_copy = true;
    }
    if (z.isKeyPressed(f.input, .t)) {
        s.pending_jump = .top;
    }
    if (z.isKeyPressed(f.input, .b)) {
        s.pending_jump = .bottom;
    }

    if (u.window("Log viewer", .{
        .initial_pos = .{ 8, 8 },
        .initial_size = .{ 380, 840 },
    })) |w| {
        defer w.close();

        u.text("zimr log viewer - Phase 1.1 demo.", .{});
        u.textDisabled("Tap Add to grow the log; auto-scroll pins newest to the bottom.", .{});

        // ---- Controls section ------------------------------------------
        u.separatorText("Controls");

        // 2-column grid so every control fits in a 380-wide window with
        // frame_padding (10, 8).tried 3 rows of mixed-width
        // buttons; that still pushed the right column past the edge
        //.  Two columns
        // are predictable - same width slot every row.
        // Row 1: auto-scroll  |  paused
        // Row 2: Add 1        |  Add 100   ← Add 1 added
        //                                    (phones can't press SPACE)
        // Row 3: Clear        |  Copy
        // Row 4: Top          |  Bot
        _ = u.checkbox("auto-scroll", &s.auto_scroll);
        u.sameLine(.{});
        _ = u.checkbox("paused", &s.paused);

        if (u.button("Add 1", .{})) {
            appendLine(s);
        }
        u.sameLine(.{});
        if (u.button("Add 100", .{})) {
            var i: usize = 0;
            while (i < 100) : (i += 1) appendLine(s);
        }

        if (u.button("Clear", .{})) {
            s.line_count = 0;
            s.next_seq = 0;
        }
        u.sameLine(.{});
        if (u.button("Copy", .{})) {
            s.pending_copy = true;
        }

        if (u.button("Top", .{})) {
            s.pending_jump = .top;
        }
        u.sameLine(.{});
        if (u.button("Bot", .{})) {
            s.pending_jump = .bottom;
        }

        // ---- Log section -----------------------------------------------
        u.separatorText("Log");

        // Filter input: type "error" to show only error lines, "-test"
        // to hide lines containing "test", "error,-test" for both.
        // Hint shown in the empty box surfaces the syntax.  Returned
        // bool (filter changed?) ignored - we re-evaluate every line
        // every frame anyway; passFilter is O(n*m) which dominates the
        // change-detection cost.
        _ = s.filter.draw(u, "Filter", "inc,-exc (e.g. error,-test)");

        // Apply jump-to-top / jump-to-bottom BEFORE submitting lines so
        // the setScrollY takes effect this frame.  Targets the OUTER
        // window's scroll - zimr's `beginChild` doesn't have its own
        // scroll state today (filed as Phase 1.6 in the plan), so the
        // canonical "fixed controls + scrollable log inside a child"
        // pattern from imgui's demo doesn't work yet.  Workaround: scroll
        // the whole window; controls scroll off the top as the user
        // pulls down to see older lines.  Less ideal UX, but fully
        // functional and avoids depending on a feature that isn't
        // shipped yet.
        switch (s.pending_jump) {
            .none => {},
            .top => u.setScrollY(0),
            .bottom => u.setScrollY(u.getScrollMaxY()),
        }
        s.pending_jump = .none;

        // Reset per-frame visible counter; populate in the loop so the
        // Status section can show it.  This is a render-loop output,
        // not real state - recomputed every frame from filter state.
        s.visible_count = 0;

        var i: usize = 0;
        while (i < s.line_count) : (i += 1) {
            const line: []const u8 = s.lines[i].text();
            // Filter check FIRST - skip the textColored entirely if
            // the line doesn't pass.  Cheaper than rendering then
            // hiding, and (more importantly) the filtered-out rows
            // don't consume layout height, so the visible result is
            // a properly-condensed list.
            if (!s.filter.passFilter(line)) {
                continue;
            }
            s.visible_count += 1;

            u.textColored(s.severities[i].color(), "{s}", .{line});
            // Error rows get a clickable "[?]" link that opens
            // imgui's source on github.  Per-row `pushIdInt(i)` /
            // `popId()` disambiguates the widget IDs - every row's
            // link has the same label so without the int seed
            // they'd collide on the ID stack and only the first
            // would respond to clicks.
            if (s.severities[i] == .err) {
                u.sameLine(.{});
                u.pushIdInt(@intCast(i)); // Zig 0.16 cleanup: was `@as(i64, @intCast(i))`
                _ = u.textLinkOpenURL("[?]", "https://github.com/ocornut/imgui/blob/master/imgui.h");
                u.popId();
            }
        }

        // Auto-scroll-to-bottom: only when enabled AND we're already
        // near the bottom (avoids fighting the user when they scroll up
        // to inspect older lines).  Reuse the canonical imgui recipe,
        // operating on the OUTER window's scroll (not a child's).
        if (s.auto_scroll and u.getScrollY() >= u.getScrollMaxY() - 1.0) {
            u.setScrollHereY(1.0);
        }

        // ---- Status section --------------------------------------------
        u.separatorText("Status");

        // HUD strip - `value` calls demonstrating the comptime type
        // dispatch (usize, comptime_int, u32 all flow through the
        // same one-arg-anytype signature).  On a narrow phone window
        // these wrap to multiple rows automatically.
        u.value("lines", s.line_count);
        u.sameLine(.{});
        u.value("cap", log_cap);
        u.sameLine(.{});
        u.value("seq", s.next_seq);
        // Filter row - only shown when the filter is doing something,
        // so users without a filter typed don't see noise.  When
        // active, `shown` reads the visible-this-frame count, making
        // the filter's effect visible without scrolling.
        if (s.filter.isActive()) {
            u.value("shown", s.visible_count);
            u.sameLine(.{});
            u.textDisabled("(filter active)", .{});
        }
        const auto_label: []const u8 = if (s.auto_scroll) "(auto-scroll: on)" else "(auto-scroll: off)";
        u.textDisabled("{s}", .{auto_label});

        // ---- Help band (invisibleButton demo) --------------------------
        // 36-px-tall hidden hit zone (bigger than before for phone
        // thumbs) with a textDisabled hint above pointing at it.  Tap
        // → toggles `show_help`.  Demonstrates invisibleButton without
        // needing a "draw your own visuals on top via cursor-rewind"
        // trick (setCursorScreenPos lands in step 4.2; this version
        // just stacks hint + zone vertically).
        const help_hint: []const u8 = if (s.show_help) "(tap below to hide help ↓)" else "(tap below for help ↓)";
        u.textDisabled("{s}", .{help_hint});
        if (u.invisibleButton("help-toggle", .{ 0, 36 })) {
            s.show_help = !s.show_help;
        }
        if (s.show_help) {
            u.textWrapped(
                "Phase 1.1 demo: separatorText sections this panel into Controls / Log / Status " ++
                    "(replacing what used to be plain separator rules).  value() shows counts on " ++
                    "the HUD strip above - one fn handles bool / int / float / enum / string via " ++
                    "Zig's comptime type dispatch (no overloads).  textLinkOpenURL on each ERROR " ++
                    "row ([?] markers) opens imgui's source on github in a new tab - try one.  " ++
                    "You just tapped an invisibleButton (36-px hidden hit zone above this " ++
                    "paragraph) to reveal this text.  Tap it again to hide.",
                .{},
            );
        }
    }

    // Apply pending clipboard copy outside the window scope (it
    // doesn't depend on `current_window`).
    if (s.pending_copy) {
        copyAll(u, s);
        s.pending_copy = false;
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - log viewer",
            .width = 400,
            .height = 880,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
