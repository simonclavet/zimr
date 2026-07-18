//! ui_dock_simple — the simplest docking demo.
//!
//! A full-window dockspace with three windows arranged by the builder API:
//! "Outline" and "Files" share a tabbed column on the left, "Editor" fills the
//! central area on the right. At runtime you can drag a tab out and re-dock it on
//! any edge (split) or center (tab), and drag the splitter between panels to
//! resize. Exercises `u.dockSpace` + the `dockBuilder*` API + drag-to-dock + the
//! splitter — all from `src/ui.zig`'s docking system.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Vec2 = zm.Vec2;
const Color = zm.Color;
const ui = z.ui_real;

const bg: Color = .{ .r = 18, .g = 22, .b = 32, .a = 255 };

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,
    /// The builder runs ONCE (dockBuilderSplitNode is not idempotent — it would
    /// split again every frame). After that the layout is live and user-editable.
    built: bool = false,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, @embedFile("atkinson_mono_ttf"), 20);
    s.* = .{ .ui_host = z.UiHost.init(gpa, font), .font = font };
}

fn update(f: *z.Frame, s: *State) void {
    z.clearViewport(f, bg);
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    const vw: f32 = f.window.widthf();
    const vh: f32 = f.window.heightf();

    // Full-window borderless host that simply contains the dockspace.
    if (u.window("##dockhost", .{
        .initial_pos = .{ 0, 0 },
        .initial_size = .{ vw, vh },
        .flags = .{
            .no_title_bar = true,
            .no_resize = true,
            .no_move = true,
            .no_collapse = true,
            .no_background = true,
        },
    })) |w| {
        defer w.close();
        const avail: Vec2 = u.getContentRegionAvail();
        const ds: ui.Id = u.dockSpace("MainDock", avail, .{});
        if (!s.built) {
            s.built = true;
            // Carve a 28%-wide left column off the root, then dock into the leaves.
            const cols: ui.SplitResult = u.dockBuilderSplitNode(ds, .left, 0.28);
            u.dockBuilderDockWindow("Outline", cols.a);
            u.dockBuilderDockWindow("Files", cols.a); // tabbed with Outline
            u.dockBuilderDockWindow("Editor", cols.b);
            u.dockBuilderSetCentralNode(cols.b);
            u.dockBuilderFinish(ds);
        }
    }

    // The docked windows — submitted as ordinary windows. Because the builder
    // gave each a dock_node_id, the dock system routes them into their leaves
    // (their own title bars are suppressed; the leaf's tab bar drives selection).
    if (u.window("Outline", .{})) |w| {
        defer w.close();
        u.text("Scene", .{});
        u.bulletText("Camera", .{});
        u.bulletText("Sun (directional)", .{});
        u.bulletText("Ground", .{});
        u.bulletText("Player", .{});
    }
    if (u.window("Files", .{})) |w| {
        defer w.close();
        u.text("src/", .{});
        u.bulletText("main.zig", .{});
        u.bulletText("game.zig", .{});
        u.bulletText("build.zig", .{});
    }
    if (u.window("Editor", .{})) |w| {
        defer w.close();
        u.text("Drag a tab out of its column, then drop it on an", .{});
        u.text("edge (to split) or the center (to tab). Drag the", .{});
        u.text("splitter between the two columns to resize.", .{});
        u.separator();
        u.text("fn main() void {{", .{});
        u.text("    // your game here", .{});
        u.text("}}", .{});
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - docking",
            .width = 900,
            .height = 600,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
