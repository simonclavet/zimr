// examples/ui_dock_persistence.zig - dock layout persistence demo.
//
// Three docked windows + a Counter that survives across refreshes
// independently of the layout.  Proves the persistence pipeline
// works end-to-end:
//   1. First load   : default 3-column layout (Tools | Viewport | Notes).
//   2. Drag a tab   : Notes can be dragged to a new spot.
//   3. F5 refresh   : layout returns where you left it.
//   4. Clear button : localStorage cleared; next refresh starts fresh.
//
// The save cadence is 60 frames (~1s at 60fps).  If you drag a
// tab and refresh too fast, the save may not have flushed yet.
// Wait ~2 seconds before refreshing to be safe.
//
// What this exercises (zimr machinery, no new features):
//   - `UiContext.persistence_key` - opt-in identifier under which
//     localStorage stores the .zon payload.
//   - `tryAutoLoad` on first frame, `tryAutoSave` every 60 frames
//     in endFrame.  See `src/ui_persistence.zig`.
//   - Dock-tree persistence (turn 334): the split tree, leaf
//     window assignments, and size_ref locks all serialize.
//
// Phone-friendly setup matches `ui_dock_basic`: `.responsive`
// scale, font_size = 16, dimensions derived from viewport so
// rotation reflows correctly.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const Vec2 = zm.Vec2;
const ui = z.ui_real;

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,

    // The counter is a non-layout piece of state that lets the
    // user verify the demo is responsive across refreshes (you
    // can see the dock layout restored AND a fresh counter).
    counter: i32 = 0,

    // Layout-build gate.  Set to true after the first successful
    // dockBuilder pass.  Reset when the user clicks "Clear layout
    // and restart" — next frame rebuilds defaults from scratch.
    layout_built: bool = false,
    root: ui.Id = 0,

    // Visible status string for "did clear succeed" feedback.
    clear_status_buf: [128]u8 = @splat(0),
    clear_status_len: usize = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, @embedFile("atkinson_mono_ttf"), 22);
    s.* = .{ .ui_host = z.UiHost.init(gpa, font), .font = font };

    // The key under which our state is persisted.  The JS layer
    // adds a "zimr_" prefix → localStorage key becomes
    // "zimr_dock_persistence_demo".
    s.ui_host.ctx.persistence_key = "dock_persistence_demo";
}

fn update(f: *z.Frame, s: *State) void {
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    const sw: f32 = float(f.window.screen_width);
    const sh: f32 = float(f.window.screen_height);
    const margin: f32 = 8;

    if (u.window("Host", .{
        .initial_pos = .{ margin, margin },
        .initial_size = .{ sw - 2 * margin, sh - 2 * margin },
    })) |w| {
        defer w.close();

        u.text("Drag tabs to rearrange. Refresh → layout returns.", .{});
        u.text("Counter (always survives): {d}", .{s.counter});

        if (u.button("+1", .{})) {
            s.counter += 1;
        }
        u.sameLine(.{});
        if (u.button("Reset counter", .{})) {
            s.counter = 0;
        }
        u.sameLine(.{});
        if (u.button("Clear layout and restart", .{})) {
            // True "start fresh" requires three things, in order:
            //
            //   1. Drop the localStorage entry so the NEXT page load
            //      sees no persisted state.
            //   2. Null the persistence_key so this session's future
            //      auto-save cycles (every 60 frames, in endFrame)
            //      don't write the LIVE in-memory state (which may
            //      include dragged-out windows) right back over the
            //      cleared entry.  Without this, the dock tree resets
            //      visually but the very next save undoes the Clear.
            //   3. Tear down the dock tree and flip `layout_built` so
            //      the next frame rebuilds defaults.
            //
            // Idempotent: if the user clicks twice in a row the
            // `orelse` skips the work the second time (no key to
            // remove, save is already disabled).
            if (s.ui_host.ctx.persistence_key) |key| {
                const status: i32 = z.dom.persistence_remove(key);
                const msg: []const u8 = switch (status) {
                    0 => "Cleared. Refresh page to start truly fresh.",
                    2 => "localStorage unavailable (host build?).",
                    else => "Unknown status.",
                };
                const copy_n: usize = @min(msg.len, s.clear_status_buf.len);
                @memcpy(s.clear_status_buf[0..copy_n], msg[0..copy_n]);
                s.clear_status_len = copy_n;

                s.ui_host.ctx.persistence_key = null;
                u.dockBuilderRemoveNode(s.root);
                s.layout_built = false;
            }
        }

        if (s.clear_status_len > 0) {
            u.text("{s}", .{s.clear_status_buf[0..s.clear_status_len]});
        }
        u.separator();

        // The dockspace fills the remaining content area.  Sized
        // to leave room for the controls above + a small bottom
        // gutter; precise content-region math arrives in P6 of
        // the v7 plan.
        const dockspace_size: Vec2 = .{
            sw - 2 * margin - 24,
            sh - 2 * margin - 200,
        };
        s.root = u.dockSpace("MainDock", dockspace_size, .{});

        if (!s.layout_built and s.root != 0) {
            const left_split: ui.SplitResult =
                u.dockBuilderSplitNode(s.root, .left, 0.30);
            if (left_split.a != 0 and left_split.b != 0) {
                const right_split: ui.SplitResult =
                    u.dockBuilderSplitNode(left_split.b, .right, 0.40);
                if (right_split.a != 0 and right_split.b != 0) {
                    u.dockBuilderDockWindow("Tools", left_split.a);
                    u.dockBuilderDockWindow("Viewport", right_split.a);
                    u.dockBuilderDockWindow("Notes", right_split.b);

                    u.dockBuilderSetCentralNode(right_split.a);
                    u.dockBuilderFinish(s.root);
                    s.layout_built = true;
                }
            }
        }
    }

    if (u.window("Tools", .{})) |w| {
        defer w.close();
        u.text("Toolbox panel.", .{});
        u.text("Drag this tab to a new dock node.", .{});
    }

    if (u.window("Viewport", .{})) |w| {
        defer w.close();
        u.text("Central viewport.", .{});
        u.text("Tabs and trees would live here.", .{});
    }

    if (u.window("Notes", .{})) |w| {
        defer w.close();
        u.text("Free-form notes.", .{});
        u.text("Refresh the page to see this layout persist.", .{});
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - Docking persistence",
            .width = 480,
            .height = 800,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
