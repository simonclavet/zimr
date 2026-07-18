// examples/ui_drag_drop_flags_tour.zig
// tour demo for DragDropFlags + ItemFlags.
// Three sections in one window:
//   1. ItemFlags.disabled - toggleable disabled scope graying out
//      a row of buttons + suppressing their clicks.
//   2. ItemFlags.button_repeat - held +/- buttons that auto-repeat
//      while down (counter scrolls).
//   3. DragDropFlags - drag a colored chip into either of two slots:
//      one with the default highlight ring, the other with
//      .accept_no_draw_default_rect (no ring) + .accept_draw_as_hovered
//      (the slot button "lights up" hover-bg).  The third slot uses
//      .accept_before_delivery to peek the payload mid-drag and
//      display a "would drop here" preview.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const ui = z.ui_real;

const Bg: Color = .{ .r = 15, .g = 23, .b = 42, .a = 255 };

const Chip = struct {
    id: u32,
    label: []const u8,
    color: Color,
};

const chips = [_]Chip{
    .{ .id = 1, .label = "red", .color = .{ .r = 220, .g = 80, .b = 80, .a = 255 } },
    .{ .id = 2, .label = "blue", .color = .{ .r = 80, .g = 120, .b = 220, .a = 255 } },
    .{ .id = 3, .label = "green", .color = .{ .r = 80, .g = 200, .b = 120, .a = 255 } },
};

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,

    // Section 1.
    section1_disabled: bool = true,
    section1_a_clicks: u32 = 0,
    section1_b_clicks: u32 = 0,

    // Section 2.
    counter: i32 = 0,

    // Section 3 - last-dropped chip id per slot.
    slot_default: u32 = 0,
    slot_no_ring: u32 = 0,
    slot_peek_preview: u32 = 0, // mid-drag peek; cleared each frame
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, @embedFile("atkinson_mono_ttf"), 22);
    s.* = .{ .ui_host = z.UiHost.init(gpa, font), .font = font };
}

fn showSlotContents(
    u: ui.Ui,
    prefix: []const u8,
    chip_id: u32,
) void {
    if (chip_id == 0) {
        u.textDisabled("{s}: (empty)", .{prefix});
        return;
    }
    // Look up the chip to recover label + color.
    for (chips) |chip| {
        if (chip.id == chip_id) {
            u.textColored(chip.color, "{s}: {s}", .{ prefix, chip.label });
            return;
        }
    }
    u.text("{s}: (unknown chip)", .{prefix});
}

fn update(f: *z.Frame, s: *State) void {
    z.clearViewport(f, Bg);

    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    // Reset the per-frame peek preview.
    s.slot_peek_preview = 0;

    if (u.window("DragDropFlags + ItemFlags tour", .{
        .initial_pos = .{ 8, 8 },
        .initial_size = .{ 460, 1060 },
    })) |w| {
        defer w.close();

        // =====================================================
        // 1. ItemFlags.disabled
        // =====================================================
        u.separatorText("1. ItemFlags.disabled");
        u.textWrapped(
            "Toggle the checkbox: when true, buttons inside the disabled scope " ++
                "gray out + ignore clicks.  Counters stop incrementing.",
            .{},
        );
        _ = u.checkbox("disable next row", &s.section1_disabled);
        u.pushItemFlag(.{ .disabled = s.section1_disabled });
        {
            defer u.popItemFlag();
            if (u.button("Click A", .{})) {
                s.section1_a_clicks += 1;
            }
            u.sameLine(.{});
            if (u.button("Click B", .{})) {
                s.section1_b_clicks += 1;
            }
        }
        u.value("A clicks", s.section1_a_clicks);
        u.value("B clicks", s.section1_b_clicks);

        // =====================================================
        // 2. ItemFlags.button_repeat
        // =====================================================
        u.separatorText("2. ItemFlags.button_repeat");
        u.textWrapped(
            "Hold +/- - counter auto-repeats after a 400ms initial delay, " ++
                "then ticks every 50ms.  Tap (not hold) increments once.",
            .{},
        );
        u.pushItemFlag(.{ .button_repeat = true });
        {
            defer u.popItemFlag();
            if (u.button("-", .{})) {
                s.counter -= 1;
            }
            u.sameLine(.{});
            if (u.button("+", .{})) {
                s.counter += 1;
            }
        }
        u.sameLine(.{});
        u.value("count", s.counter);

        // =====================================================
        // 3. DragDropFlags
        // =====================================================
        u.separatorText("3. DragDropFlags");
        u.textWrapped(
            "Drag a chip below into one of the three slots.  Each slot " ++
                "uses different DragDropFlags on the target side.",
            .{},
        );

        // Sources: three colored chips.
        u.text("Sources:", .{});
        for (chips) |chip| {
            if (u.button(chip.label, .{})) {}
            // Drag-source registration immediately after the widget.
            if (u.beginDragDropSource(.{})) {
                defer u.endDragDropSource();
                u.setDragDropPayload(u32, &chip.id);
                u.textColored(chip.color, "drag: {s}", .{chip.label});
            }
            u.sameLine(.{});
        }
        u.newLine();

        // Slot 1 - default flags.
        u.text("Slot A (default highlight ring):", .{});
        _ = u.button("        drop here        ", .{});
        if (u.beginDragDropTarget(.{})) {
            defer u.endDragDropTarget();
            if (u.acceptDragDropPayload(u32, .{})) |chip_id| {
                s.slot_default = chip_id;
            }
        }
        showSlotContents(u, "A holds", s.slot_default);

        // Slot 2 - no highlight ring, draw-as-hovered.
        u.text("Slot B (no ring, draw-as-hovered):", .{});
        _ = u.button("        drop here        ", .{});
        if (u.beginDragDropTarget(.{
            .accept_no_draw_default_rect = true,
            .accept_draw_as_hovered = true,
        })) {
            defer u.endDragDropTarget();
            if (u.acceptDragDropPayload(u32, .{})) |chip_id| {
                s.slot_no_ring = chip_id;
            }
        }
        showSlotContents(u, "B holds", s.slot_no_ring);

        // Slot 3 - accept_before_delivery (peek mid-drag).
        u.text("Slot C (peek mid-drag):", .{});
        _ = u.button("        drop here        ", .{});
        if (u.beginDragDropTarget(.{})) {
            defer u.endDragDropTarget();
            // Mid-drag peek.
            if (u.acceptDragDropPayload(u32, .{ .accept_before_delivery = true })) |peeked| {
                s.slot_peek_preview = peeked;
            }
        }
        if (s.slot_peek_preview != 0) {
            u.textColored(
                .{ .r = 255, .g = 235, .b = 120, .a = 255 },
                "peek: chip {d} (release to drop)",
                .{s.slot_peek_preview},
            );
        } else {
            u.textDisabled("(drag a chip over to peek)", .{});
        }
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - DragDropFlags + ItemFlags tour",
            .width = 480,
            .height = 1100,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
