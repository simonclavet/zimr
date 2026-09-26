// examples/ui_drag_drop_source.zig - Phase 2a drag-drop source demo.
// Source side only - there's no drop target yet, so dragging a
// button shows the preview tooltip following the cursor, but
// nothing gets received.  Phase 2b adds beginDragDropTarget /
// acceptDragDropPayload and wires the receive side.
// What to look at:
// - Click any of the build chips and drag it.  The preview
//   tooltip appears at the cursor showing the build label.
// - Drag-and-release without a target -> nothing happens, the
//   preview disappears.
// - Status text below the chips shows the current drag state
//   (idle / pending / active <typename>).

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const ui = z.ui_real;

const screen_w: i32 = 800;
const screen_h: i32 = 520;

const BuildPayload = struct {
    id: u32,
};

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,

    labels: [6][]const u8 = .{
        "main#1042",
        "feature/x#1041",
        "bugfix/123#1038",
        "release-1.4#1035",
        "deps-bump#1029",
        "wip#1015",
    },
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

    if (u.window("Drag-drop source - Phase 2a", .{
        .initial_pos = .{ 20, 20 },
        .initial_size = .{ 760, 480 },
    })) |w| {
        defer w.close();

        u.text("Click + hold + drag any chip below.  Source side only - no targets yet.", .{});
        u.separator();

        u.text("Draggable build chips:", .{});

        for (s.labels, 0..) |label, i| {
            const payload: BuildPayload = .{ .id = @intCast(1000 + i) };
            if (u.button(label, .{})) {
                // Click-without-drag -> no-op for this demo.
            }
            if (u.beginDragDropSource(.{})) {
                u.setDragDropPayload(BuildPayload, &payload);
                u.text("Build #{d}", .{payload.id});
                u.endDragDropSource();
            }
            if (i < s.labels.len - 1) {
                u.sameLine(.{});
            }
        }

        u.separator();

        // Status readout - peek at the drag state directly for the
        // demo.  In production code, callers usually just look at
        // begin*/end* returns.
        const dd: *z.ui_real.DragDropState = &s.ui_host.ctx.drag_drop;
        const phase_str: []const u8 = switch (dd.phase) {
            .idle => "idle",
            .pending => "pending (mouse held, no movement yet)",
            .active => "active",
        };
        u.text("Drag state: {s}", .{phase_str});
        if (dd.phase == .active) {
            u.text("  payload type: {s}", .{dd.typeName()});
            u.text("  payload size: {d} bytes", .{dd.payload_len});
        }

        u.separator();
        u.text("Try: click and drag any chip slowly to see 'pending' transition to 'active'.", .{});
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - UI drag-drop source",
            .width = screen_w,
            .height = screen_h,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
