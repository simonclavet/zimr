// examples/ui_dev_tools.zig - P2.4 demo for the developer tools
// surface introduced in P2 (turns 385-387):
//   - `UiContext.metrics: Metrics` (P2.2, turn 386) - frame counters,
//     time history, drawlist + cmd accumulators, window counts.
//   - `UiContext.debug_log: BoundedArray(DebugEvent, 256)` (P2.1,
//     turn 385) - internal event ring populated by openPopup,
//     closeCurrentPopup, drag-threshold-cross, and dropAccepted.
//
// What this demo shows:
//
//   1. The marquee payoff of P1's inspector arriving early - the
//      Metrics panel is literally `u.inspect("Metrics", &ctx.metrics)`.
//      Field discovery is automatic; no per-field widget code in the
//      example.
//
//   2. A DebugLog viewer that walks `debugLogSlice(ctx)` and renders
//      one row per event.  Doesn't go through inspect because the
//      ring's storage layer (BoundedArray's `buffer: [256]DebugEvent`)
//      would surface 256 elements where only `len` are meaningful.
//      Future inspector helper (P9?) could special-case BoundedArray;
//      for now it's a 6-line manual loop.
//
//   3. A few interactive trigger widgets that generate events so
//      the viewer isn't empty:
//        - "Open popup" button -> popup_opened entry.
//        - Drag-drop source row + target slot -> drag_started +
//          drop_accepted entries.
//        - "Bad slider" with `min == max` deliberately triggers
//          the P2.3 lint #1 warning.  Look at the browser console
//          for `[zimr lint]`.  Fires once.
//
// Phone-friendly: responsive scale, font_size 16, full-screen host
// window that scrolls when content overflows.

const std = @import("std");
const zm = @import("zm");
const float = zm.float;
const bufPrint = std.fmt.bufPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const ui = z.ui_real;

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,

    // Drag-source payload - gets dropped onto the slot below to
    // exercise the drag_started + drop_accepted log entries.
    drag_value: i32 = 7,
    slot_value: i32 = 0,

    // Bad slider value - feeding it to a slider with min == max
    // exercises lint #1.  Value is just a placeholder; the slider
    // returns false because the range is degenerate.
    bad_value: f32 = 0.5,
};

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

    const sw: f32 = float(f.window.screen_width);
    const sh: f32 = float(f.window.screen_height);
    const margin: f32 = 8;

    if (u.window("Devtools", .{
        .initial_pos = .{ margin, margin },
        .initial_size = .{ sw - 2 * margin, sh - 2 * margin },
    })) |w| {
        defer w.close();

        u.text("Dear ImGui's Metrics + Log windows, zimr edition.", .{});
        u.text("Frame {d} -- look at console for [zimr lint] hits.", .{
            s.ui_host.ctx.metrics.frame_count,
        });
        u.separator();

        // ---- Section 1: Metrics panel ------------------------------
        // The whole point of P1 shipping early: this is one line.
        // `inspect` walks the Metrics struct fields, opens its own
        // tree node, and dispatches each field (u32 -> read-only int,
        // f32 -> read-only float, history array -> readonly preview).
        _ = u.inspect("Metrics (live)", &s.ui_host.ctx.metrics);

        // ---- Section 2: DebugLog viewer ----------------------------
        // BoundedArray's storage exposes a 256-slot buffer but only
        // `len` slots are valid; debugLogSlice borrows just the
        // populated prefix.  Render newest-first by reversing the
        // walk index.
        if (u.treeNode("DebugLog (newest first)", .{ .default_open = true })) {
            defer u.treePop();
            const events: []const ui.DebugEvent = ui.debugLogSlice(&s.ui_host.ctx);
            if (events.len == 0) {
                u.text("(no events yet -- try the triggers below)", .{});
            } else {
                u.text("{d} event(s) in ring (cap {d})", .{
                    events.len,
                    ui.debug_log_cap,
                });
                // Walk newest -> oldest.  10 rows max so phone
                // viewport stays usable.
                const show_n: usize = @min(events.len, 10);
                var i: usize = 0;
                while (i < show_n) : (i += 1) {
                    const idx: usize = events.len - 1 - i;
                    const ev: ui.DebugEvent = events[idx];
                    u.text("[{d:>6}] {s}: {s}", .{
                        ev.frame,
                        @tagName(ev.kind),
                        ev.messageSlice(),
                    });
                }
                if (events.len > 10) {
                    u.text("... ({d} older)", .{events.len - 10});
                }
            }
        }

        u.separator();

        // ---- Section 3: Event triggers -----------------------------
        if (u.treeNode("Triggers (generate events)", .{ .default_open = true })) {
            defer u.treePop();

            // Button -> openPopup.  Two adjacent clicks within the
            // same frame would also exercise lint #4 (double-open),
            // but that's hard to do from a UI: it'd take submitting
            // two `openPopup` calls in the same widget tree pass.
            // The lint catches the programmer-error case where a
            // helper function calls openPopup unconditionally on
            // every frame.
            if (u.button("Open popup", .{})) {
                u.openPopup("dev_tools_demo_popup");
            }
            if (u.beginPopup("dev_tools_demo_popup")) {
                defer u.endPopup();
                u.text("Popup body.", .{});
                if (u.button("Close", .{})) {
                    u.closeCurrentPopup();
                }
            }

            // Drag-drop trigger.  Source widget + target slot below.
            // Moving past the drag threshold logs drag_started;
            // dropping onto the slot logs drop_accepted.
            u.text("Drag the {d} below onto the slot:", .{s.drag_value});
            var label_buf: [32]u8 = undefined;
            const drag_label: []const u8 = bufPrint(
                &label_buf,
                "drag {d}",
                .{s.drag_value},
            ) catch "drag";
            _ = u.button(drag_label, .{});
            if (u.beginDragDropSource(.{})) {
                defer u.endDragDropSource();
                u.setDragDropPayload(i32, &s.drag_value);
                u.text("dragging {d}...", .{s.drag_value});
            }

            u.text("Slot (current: {d}):", .{s.slot_value});
            _ = u.button("[ drop here ]", .{ .size = .{ 200, 0 } });
            if (u.beginDragDropTarget(.{})) {
                defer u.endDragDropTarget();
                if (u.acceptDragDropPayload(i32, .{})) |dropped| {
                    s.slot_value = dropped;
                }
            }

            // Slider with degenerate bounds -> lint #1.
            // Fires once at process startup; subsequent submissions
            // skip the warn.
            u.separator();
            u.text("Bad-bounds slider (triggers lint #1):", .{});
            _ = u.slider("min == max", &s.bad_value, .{ .min = 0.5, .max = 0.5 });
        }
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - Devtools (P2.4)",
            .width = 480,
            .height = 900,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
