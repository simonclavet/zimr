// examples/ui_dock_basic.zig - docking arc demo (phone-friendly,
//).
// Shows off everything that landed in the 5.5e-i sub-steps:
//   - Drag-to-dock with smooth-pull overlay (5.5e).  Grab the
//     "Floating Notes" window's title bar and drag it over the
//     dockspace - five drop zones light up; whichever zone the
//     cursor pulls toward strongest wins.  Release to dock.
//   - Pre-dock pos/size restore (5.5h).  After dragging Notes
//     into the dock, click the Reset button to tear down the
//     layout - Notes pops back to where it was floating.
//   - DockNodeFlags (5.5f).  The Tools leaf is configured
//     `no_split` + `no_docking_over_me`: try dragging Notes
//     over Tools and notice the overlay doesn't appear there.
//   - Splitter drag (5.5i).  Grab the seam between Tools and
//     the right group; drag to resize.  Brightens on hover.
//   - size_ref lock (5.5g).  Tools is initially locked at
//     a sensible fraction of the viewport.  The "Unlock Tools"
//     button clears the lock so Tools resizes proportionally.
// Phone-friendly setup:
//   - `.scale = .responsive` - canvas coords track CSS pixels
//     1:1, so widgets size correctly regardless of viewport.
//   - `style.font_size = 24` - readable on phone (3x the
//     default 10).  Default widget heights (buttons, title
//     bars, item spacing) follow proportionally - bigger
//     touch targets come for free.
//   - All window/dockspace dimensions derived from
//     `f.window.screen_width/height` so the layout fills the
//     viewport on phone AND desktop.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const Color = zm.Color;
const Vec2 = zm.Vec2;
const ui = z.ui_real;

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,

    layout_built: bool = false,
    counter: i32 = 0,
    tools_locked: bool = true,
    // Stable handles so the Reset / Lock buttons don't have to
    // walk the tree.
    root: ui.Id = 0,
    tools_parent_split: ui.Id = 0,
    tools_locked_px: f32 = 200,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, @embedFile("atkinson_mono_ttf"), 22);
    s.* = .{ .ui_host = z.UiHost.init(gpa, font), .font = font };
    // Bump font_size off the bitmap default (10) so labels are
    // legible without being huge.  `.scale = .responsive` keeps
    // input/draw coords 1:1 with CSS pixels - no stretching that
    // would desync mouse position from where widgets render.
}

fn update(f: *z.Frame, s: *State) void {
    z.clearViewport(f, Color.raywhite);

    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    const sw: f32 = float(f.window.screen_width);
    const sh: f32 = float(f.window.screen_height);
    // Lock the Tools panel at ~30 % of the viewport width.
    // Re-read each frame so rotating the phone keeps Tools at
    // a sensible width.
    s.tools_locked_px = @max(160, sw * 0.30);

    // Host window fills the viewport with a small margin so the
    // user can still see the edge of the canvas.
    const margin: f32 = 8;
    if (u.window("Host", .{
        .initial_pos = .{ margin, margin },
        .initial_size = .{ sw - 2 * margin, sh - 2 * margin },
    })) |w| {
        defer w.close();

        u.text("Drag 'Notes' onto the dock. Grab seam to resize.", .{});
        if (u.button("Reset", .{})) {
            u.dockBuilderRemoveNode(s.root);
            s.layout_built = false;
        }
        u.sameLine(.{});
        if (u.button(if (s.tools_locked) "Unlock Tools" else "Lock Tools", .{})) {
            s.tools_locked = !s.tools_locked;
            if (s.tools_parent_split != 0) {
                u.dockBuilderSetSizeRef(
                    s.tools_parent_split,
                    .a,
                    if (s.tools_locked) s.tools_locked_px else null,
                );
            }
        }
        u.separator();

        // Dockspace fills the rest of the Host content area.
        // Use a fixed size hint that reaches near the host's
        // bottom edge; the auto-fill via getContentRegionAvail
        // is more idiomatic but the simple form is enough for
        // this demo.
        const dockspace_size: Vec2 = .{ sw - 2 * margin - 24, sh - 2 * margin - 180 };
        s.root = u.dockSpace("MainDockSpace", dockspace_size, .{});

        // Build the default layout once per "session" (after
        // reset the flag flips back to false, rebuilding).
        if (!s.layout_built and s.root != 0) {
            const split: ui.SplitResult = u.dockBuilderSplitNode(s.root, .left, 0.30);
            if (split.a != 0 and split.b != 0) {
                u.dockBuilderDockWindow("Tools", split.a);
                u.dockBuilderDockWindow("Viewport", split.b);
                u.dockBuilderDockWindow("Console", split.b);

                // Tools panel locked at the viewport-relative px.
                // Won't scale when the dockspace resizes;
                // right group absorbs the remainder.  Plus
                // no_split (can't sub-split it) and
                // no_docking_over_me (incoming drags skip
                // this leaf entirely).  Mark central node on
                // the right group for persistence (5.5k).
                u.dockBuilderSetSizeRef(s.root, .a, s.tools_locked_px);
                u.dockBuilderSetNodeFlags(split.a, .{
                    .no_split = true,
                    .no_docking_over_me = true,
                });
                u.dockBuilderSetCentralNode(split.b);
                s.tools_parent_split = s.root;
                s.tools_locked = true;

                u.dockBuilderFinish(s.root);
                s.layout_built = true;
            }
        }
    }

    if (u.window("Tools", .{})) |w| {
        defer w.close();
        u.text("Locked.", .{});
        u.text("No drop here.", .{});
        u.separator();
        if (u.button("+1", .{})) {
            s.counter += 1;
        }
        u.sameLine(.{});
        u.text("Count: {d}", .{s.counter});
    }

    if (u.window("Viewport", .{})) |w| {
        defer w.close();
        u.text("Central leaf.", .{});
        u.text("Drag the seam to resize.", .{});
    }

    if (u.window("Console", .{})) |w| {
        defer w.close();
        u.text("> 5.5e-i shipped", .{});
        u.text("> 5.5j next: tab close", .{});
    }

    // Floating window - drag its title bar onto the dock to
    // exercise the smooth-pull overlay.  No dockBuilder calls
    // -> starts floating.  Position lower-center so its title
    // bar is well within the viewport on phone.
    if (u.window("Notes", .{
        .initial_pos = .{ sw * 0.10, sh * 0.55 },
        .initial_size = .{ sw * 0.80, sh * 0.30 },
    })) |w| {
        defer w.close();
        u.text("Drag my title onto the dock.", .{});
        u.text("Watch the 5-zone overlay.", .{});
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - Docking demo",
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
