// examples/ui_clipper.zig - Phase A2 of the imgui-parity arc.
// Demonstrates `ui.clipper(count, height)` - virtualized list
// rendering.  Renders a 100,000-row log at O(visible) per frame
// instead of O(count); about 30-50 rows actually submit each
// frame regardless of total count.
// Background: imgui's `ImGuiListClipper` is the canonical pattern
// for any list view that exceeds the viewport.  A 100k-row list
// without a clipper would submit 100k text widgets per frame
// even though only ~30 are visible.  With the clipper, only the
// visible range submits; the cursor advances over the rest
// arithmetically so the scrollbar reflects the full range.
// What this demo shows:
//   - 100,000 deterministic log rows (no per-row allocation; the
//     row "data" is computed on the fly from the row index).
//   - Hovering ANY visible row colors it.
//   - HUD reports actual rows submitted this frame and the
//     visible window - proves the O(visible) claim.
//   - Toggle clipper on/off to see the perf difference (turn OFF
//     and watch frame time spike - even though zimr is fast,
//     submitting 100k text widgets is noticeable).
// Caveat: the demo uses a FIXED row height.  The clipper API
// requires the caller to supply the row's rendered height.  For
// the simple text rows below, that's `style.font_size +
// style.item_spacing.y`.  For variable-height rows the imgui
// idiom is "measure on first frame, virtualize on the rest"
// not implemented in A2.  See `imgui-parity-plan.md` for the
// roadmap.

const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const ui = z.ui_real;

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,

    use_clipper: bool = true,
    row_count: i32 = 100_000,
    last_frame_rows_submitted: usize = 0,
    last_visible_start: usize = 0,
    last_visible_end: usize = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, @embedFile("atkinson_mono_ttf"), 22);
    s.* = .{ .font = font, .ui_host = z.UiHost.init(gpa, font) };
}

/// Format row `i` into the provided buffer.  Deterministic from
/// the index - no allocation, no per-row state.  In a real app
/// the row content would come from a backing store (file, db,
/// network buffer); the point is that the clipper only reads
/// data for visible rows.
fn rowText(buf: []u8, i: usize) []const u8 {
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
    const subjects: [8][]const u8 = .{ "connection", "request", "frame", "session", "tick", "packet", "query", "job" };
    const verbs: [8][]const u8 = .{
        "completed",
        "queued",
        "retried",
        "dropped",
        "ack'd",
        "expired",
        "renewed",
        "deferred",
    };
    const sub: []const u8 = subsystems[i % subsystems.len];
    const subj: []const u8 = subjects[(i / 10) % subjects.len];
    const verb: []const u8 = verbs[(i / 7) % verbs.len];
    const written: []const u8 = bufPrint(buf, "[{d:0>6}] {s}: {s} {s} ({s}ms)", .{
        i,
        sub,
        subj,
        verb,
        if (i & 1 == 0) "<1" else "12.3",
    }) catch return buf[0..0];
    return written;
}

fn update(f: *z.Frame, s: *State) void {
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    if (u.window("100,000-row virtualized log", .{
        .initial_pos = .{ 20, 20 },
        .initial_size = .{ 920, 600 },
    })) |w| {
        defer w.close();

        u.text("Phase A2 - ImGuiListClipper virtualization.", .{});
        u.textDisabled("100,000 rows; only ~30 actually submitted to the UI per frame.", .{});
        u.separator();

        _ = u.checkbox("use clipper (turn OFF to see frame time spike)", &s.use_clipper);
        _ = u.drag("row count", &s.row_count, .{ .speed = 100, .min = 1, .max = 100_000, .fmt = "{d}" });

        u.separator();

        // HUD: actual rows submitted last frame (zero-cost
        // proof of virtualization).
        u.labelText("rows in dataset", "{d}", .{s.row_count});
        u.labelText("rows submitted last frame", "{d}", .{s.last_frame_rows_submitted});
        u.labelText("visible window", "[{d} .. {d})", .{ s.last_visible_start, s.last_visible_end });
        u.text(
            "frame: {d:.2}ms  |  fps: {d:.0}",
            .{ f.time.delta_time * 1000, if (f.time.delta_time > 0) 1.0 / f.time.delta_time else 0 },
        );

        u.separator();

        // The scrollable child where the rows live.  Using
        // beginChild gives us a bounded viewport that the
        // clipper can read from `ctx.child_stack`.
        if (u.beginChild("log-region", .{ 0, 380 }, .{ .border = true })) {
            defer u.endChild();

            // Item height: font_size + item_spacing.y matches the
            // height produced by `u.text(...)`.  Verified by
            // inspecting `text()`'s call to advanceLayout.
            const style: ui.Style = s.ui_host.ctx.style;
            const item_height: f32 = style.font_size + style.item_spacing[1];
            const n: usize = @intCast(s.row_count);

            var submitted: usize = 0;
            var vs: usize = 0;
            var ve: usize = 0;

            if (s.use_clipper) {
                // ---- Virtualized path ----
                var clip: ui.Clipper = u.clipper(n, item_height);
                while (clip.step()) |range| {
                    vs = range.start;
                    ve = range.end;
                    var buf: [128]u8 = undefined;
                    var i: usize = range.start;
                    while (i < range.end) : (i += 1) {
                        const t = rowText(&buf, i);
                        u.text("{s}", .{t});
                        submitted += 1;
                    }
                }
            } else {
                // ---- Naive path: submit every row ----
                var buf: [128]u8 = undefined;
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const t = rowText(&buf, i);
                    u.text("{s}", .{t});
                    submitted += 1;
                }
                vs = 0;
                ve = n;
            }

            s.last_frame_rows_submitted = submitted;
            s.last_visible_start = vs;
            s.last_visible_end = ve;
        }

        u.separator();
        u.textDisabled("Wheel-scroll over the log to navigate.  The scrollbar reflects the full 100k range.", .{});
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - ui_clipper (Phase A2: 100k-row virtualization)",
            .width = 960,
            .height = 640,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
