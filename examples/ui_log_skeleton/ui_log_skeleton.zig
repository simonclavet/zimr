// examples/ui_log_skeleton.zig
// Bisection step 3.  ui_minimal_button proved font setup
// is fine.  ui_minimal_one_context proved one-context
// many-widgets is fine.  Remaining suspects in `ui_log_viewer`:
//   - `separatorText`
//   - `beginChild` + `endChild` clip/scroll plumbing
//   - The 80-iteration `textColored` loop inside the child
//   - `textLinkOpenURL`
//   - `invisibleButton`
// This example exercises log_viewer's STRUCTURE (separators +
// child window + scrollable region + new-text-helper widgets)
// but with MINIMAL content - 4 textColored lines instead of 80.
// Two windows:
//   Window 1 - "structure only".  All log_viewer's structural
//              widgets but only 4 lines of textColored, no
//              textLinkOpenURL, no invisibleButton, no textWrapped.
//              Tests separatorText + beginChild + textColored
//              without the new-text-helper widgets.
//   Window 2 - "structure + new widgets".  Same plus
//              textLinkOpenURL, invisibleButton, textWrapped.
//              Adds the four turn-266 features.
// Outcomes:
//   - Both render -> bug is in the 80-line loop (the content,
//     not the structure).  Probably a per-line glyph budget
//     issue, or specific content in the random log strings
//     hitting a UTF-8 / line-width edge case.
//   - Window 1 renders, Window 2 blank -> one of the four
//     turn-266 helpers (textLinkOpenURL, invisibleButton,
//     textWrapped) is the culprit.
//   - Both blank -> the structural combo (separatorText +
//     beginChild + textColored) is the culprit.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const ui = z.ui_real;

const Bg: Color = .{ .r = 15, .g = 23, .b = 42, .a = 255 };

// Colors matching log_viewer's severity coloring.
const ColInfo: Color = .{ .r = 156, .g = 163, .b = 175, .a = 255 };
const ColWarn: Color = .{ .r = 250, .g = 204, .b = 21, .a = 255 };
const ColErr: Color = .{ .r = 248, .g = 113, .b = 113, .a = 255 };

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,

    show_help_1: bool = false,
    show_help_2: bool = false,
    btn_count: u32 = 0,
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
    // Same setup as ui_log_viewer (the broken one).
}

fn update(f: *z.Frame, s: *State) void {
    z.clearViewport(f, Bg);

    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    // Window 1 - structure only.
    // separatorText + beginChild + textColored loop (4 lines) + nothing
    //'s new helpers.
    if (u.window("Window 1 - structure only", .{
        .initial_pos = .{ 8, 8 },
        .initial_size = .{ 380, 520 },
    })) |w| {
        defer w.close();

        u.text("Structure: separator + child + 4 textColored.", .{});
        u.separatorText("Controls");
        if (u.button("Bump count", .{})) {
            s.btn_count += 1;
        }
        u.sameLine(.{});
        u.text("count = {d}", .{s.btn_count});

        u.separatorText("Log");
        if (u.beginChild("w1-log", .{ 0, 220 }, .{ .border = true })) {
            defer u.endChild();
            u.textColored(ColInfo, "info  net  connection established", .{});
            u.textColored(ColInfo, "info  db   warm cache hit", .{});
            u.textColored(ColWarn, "warn  fs   queue depth high", .{});
            u.textColored(ColErr, "error auth retry budget exhausted", .{});
        }
        u.separatorText("Status");
        u.text("Bottom of window 1.", .{});
    }

    // Window 2 - structure + new widgets.
    // Adds textLinkOpenURL, invisibleButton, textWrapped.
    if (u.window("Window 2 - + new helpers", .{
        .initial_pos = .{ 8, 540 },
        .initial_size = .{ 380, 540 },
    })) |w| {
        defer w.close();

        u.text("Plus textLinkOpenURL, invisibleButton, textWrapped.", .{});
        u.separatorText("Controls");
        if (u.button("Another button", .{})) {}

        u.separatorText("Log");
        if (u.beginChild("w2-log", .{ 0, 220 }, .{ .border = true })) {
            defer u.endChild();
            u.textColored(ColInfo, "info  net  connection established", .{});
            u.textColored(ColErr, "error auth retry budget exhausted", .{});
            // The new helper inside the child.  Per-row pushIdInt
            // disambiguates the [?] label (identical-label rows
            // would collide on the ID stack otherwise).
            u.sameLine(.{});
            u.pushIdInt(0);
            _ = u.textLinkOpenURL("[?]", "https://example.com");
            u.popId();
            u.textColored(ColWarn, "warn  fs   queue depth high", .{});
        }

        u.separatorText("Status");
        u.value("count", s.btn_count);
        const hint: []const u8 = if (s.show_help_2) "(tap below to hide ↓)" else "(tap below for help ↓)";
        u.textDisabled("{s}", .{hint});
        if (u.invisibleButton("w2-help-toggle", .{ 0, 36 })) {
            s.show_help_2 = !s.show_help_2;
        }
        if (s.show_help_2) {
            u.textWrapped(
                "This is a wrapped help paragraph identical in shape to the one " ++
                    "at the bottom of ui_log_viewer.  If you see this text after " ++
                    "tapping the invisible band above, the textWrapped widget is " ++
                    "working correctly.",
                .{},
            );
        }
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - log_viewer skeleton",
            .width = 400,
            .height = 1100,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
