// examples/ui_persistence.zig demo.
// Drag the window.  Resize it via the corner grip.  Scroll.  Then
// refresh the browser tab.  The window comes back where you left it
// - pos, size, scroll all persisted via localStorage.
// This is the "we did it better than imgui" payoff: imgui needs a
// caller-provided IO layer + a manual `SaveIniSettingsToDisk()`
// call; zimr persists transparently as long as the demo opts in
// with one line:
//     ctx.persistence_key = "ui_persistence_demo";
// Auto-load on first beginFrame, auto-save every 60 frames.
// Storage layout: `localStorage["zimr_ui_persistence_demo"]` holds
// a `.zon`-encoded `PersistedState` (one entry per window).  See
// `src/ui_persistence.zig` for the schema.  Open DevTools ->
// Application -> Local Storage to inspect.
// What's NOT persisted today: widget values (counters, sliders),
// collapsing-header open state, tab-bar selection.  Those land in
// later sub-steps:
//   - 5.1c: tab-bar selected_id wiring
//   - 5.1d (filed): generic widget-value pinning
//   - 5.5 (docking milestone): dock-node tree

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const ui = z.ui_real;

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,

    counter: i32 = 0,
    show_help: bool = true,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, @embedFile("atkinson_mono_ttf"), 22);
    s.* = .{ .ui_host = z.UiHost.init(gpa, font), .font = font };
    // * The one line that turns persistence on.  Auto-load fires
    // on the next beginFrame; auto-save every 60 frames after.
    // Key is namespaced "zimr_" internally so it can't collide
    // with the host page's localStorage.
    s.ui_host.ctx.persistence_key = "ui_persistence_demo";
}

fn update(f: *z.Frame, s: *State) void {
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    if (u.window("Persistent window", .{
        .initial_pos = .{ 40, 40 },
        .initial_size = .{ 420, 320 },
    })) |w| {
        defer w.close();

        u.text("This window's pos/size/scroll persist across reloads.", .{});
        u.text("Drag the title bar, then refresh the page.", .{});
        u.separator();

        if (u.button("Increment", .{})) {
            s.counter += 1;
        }
        u.sameLine(.{});
        u.text("Counter: {d}  (NOT persisted - widget values come later)", .{s.counter});

        u.separator();
        _ = u.checkbox("Show help", &s.show_help);
        if (s.show_help) {
            u.text("Persistence key: \"zimr_ui_persistence_demo\"", .{});
            u.text("Inspect: DevTools → Application → Local Storage", .{});
            u.text("Save cadence: every 60 frames (~1s at 60fps)", .{});
        }

        // Fill with stuff so the window can scroll - exercises
        // scroll_y persistence.
        u.separator();
        u.text("Scroll content below (scroll_y is persisted):", .{});
        var i: i32 = 0;
        while (i < 50) : (i += 1) {
            u.text("  line {d}", .{i});
        }
    }

    // A second window - proves multiple windows persist independently.
    if (u.window("Another window", .{
        .initial_pos = .{ 500, 100 },
        .initial_size = .{ 320, 200 },
    })) |w2| {
        defer w2.close();
        u.text("Move me independently of the other window.", .{});
        u.text("Each window's state is keyed by its title.", .{});
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - UI persistence",
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
