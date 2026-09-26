// examples/ui_drag_drop_demo.zig - Phase 2b drag-drop capstone.
// Source + target wired together.  Five named lanes ("backlog",
// "queued", "running", "passed", "failed") each containing a
// list of build chips.  Drag any chip from one lane to another
// to move it.  Builds the full picture of imgui-style drag-drop
// in zimr.
// What to look at:
// - Click + drag any chip -> preview tooltip follows cursor.
// - Hover another lane -> outline ring lights up on the lane.
// - Release over a lane -> build moves there.
// - Release outside any lane -> no move, drag is cancelled.
// - Status counts at the bottom update live.

const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const ui = z.ui_real;

const screen_w: i32 = 1080;
const screen_h: i32 = 680;

const Lane = enum {
    backlog,
    queued,
    running,
    passed,
    failed,

    fn label(self: Lane) []const u8 {
        return switch (self) {
            .backlog => "Backlog",
            .queued => "Queued",
            .running => "Running",
            .passed => "Passed",
            .failed => "Failed",
        };
    }
};

const Build = struct {
    id: u32,
    name_buf: [20]u8,
    name_len: usize,
    lane: Lane,

    fn name(self: *const Build) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

/// Payload type for the drag.  Just the build id - cheaper than
/// copying the whole build, and the lane state owns the storage
/// anyway.
const DragPayload = struct {
    build_id: u32,
};

const max_builds: usize = 12;

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,

    builds: [max_builds]Build = undefined,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, @embedFile("atkinson_mono_ttf"), 22);
    s.* = .{ .font = font, .ui_host = z.UiHost.init(gpa, font) };
    const branches = [_][]const u8{
        "main",
        "feature/x",
        "bugfix/123",
        "release-1.4",
        "deps-bump",
        "wip",
        "ci-tune",
        "docs",
        "perf",
        "exp/gpu",
        "hotfix",
        "refactor",
    };
    const start_lanes = [_]Lane{
        .backlog,
        .backlog,
        .backlog,
        .queued,
        .queued,
        .running,
        .running,
        .passed,
        .passed,
        .passed,
        .failed,
        .failed,
    };
    for (&s.builds, 0..) |*b, i| {
        b.id = @intCast(1000 + i);
        const written: []u8 = bufPrint(&b.name_buf, "{s}#{d}", .{ branches[i], b.id }) catch b.name_buf[0..0];
        b.name_len = written.len;
        b.lane = start_lanes[i];
    }
}

fn findBuildIndex(builds: []const Build, id: u32) ?usize {
    for (builds, 0..) |b, i| {
        if (b.id == id) {
            return i;
        }
    }
    return null;
}

fn laneCount(builds: []const Build, lane: Lane) usize {
    var n: usize = 0;
    for (builds) |b| {
        if (b.lane == lane) {
            n += 1;
        }
    }
    return n;
}

fn drawLane(
    u: ui.Ui,
    s: *State,
    lane: Lane,
) void {
    // Lane label with count.
    u.text("{s}  ({d})", .{ lane.label(), laneCount(&s.builds, lane) });

    // Lane container: a `child` block holds chips + provides a
    // hit-rect for beginDragDropTarget.
    if (u.beginChild(@tagName(lane), .{ 180, 360 }, .{ .border = true })) {
        defer u.endChild();
        for (s.builds) |b| {
            if (b.lane != lane) {
                continue;
            }
            _ = u.button(b.name(), .{});
            if (u.beginDragDropSource(.{})) {
                const payload: DragPayload = .{ .build_id = b.id };
                u.setDragDropPayload(DragPayload, &payload);
                u.text("{s}", .{b.name()});
                u.endDragDropSource();
            }
        }
    }

    // The child block becomes the target.  beginDragDropTarget
    // reads w.last_item_id / last_item_rect from the closed child.
    if (u.beginDragDropTarget(.{})) {
        if (u.acceptDragDropPayload(DragPayload, .{})) |payload| {
            if (findBuildIndex(&s.builds, payload.build_id)) |idx| {
                s.builds[idx].lane = lane;
            }
        }
        u.endDragDropTarget();
    }
}

fn update(f: *z.Frame, s: *State) void {
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    if (u.window("Drag-drop demo - Kanban lanes", .{
        .initial_pos = .{ 20, 20 },
        .initial_size = .{ 1040, 640 },
    })) |w| {
        defer w.close();

        u.text("Drag any build chip between lanes.  Hover-over highlights the target.", .{});
        u.separator();

        // Five lanes side-by-side.
        drawLane(u, s, .backlog);
        u.sameLine(.{});
        drawLane(u, s, .queued);
        u.sameLine(.{});
        drawLane(u, s, .running);
        u.sameLine(.{});
        drawLane(u, s, .passed);
        u.sameLine(.{});
        drawLane(u, s, .failed);

        u.separator();

        const dd: *z.ui_real.DragDropState = &s.ui_host.ctx.drag_drop;
        const phase_str: []const u8 = switch (dd.phase) {
            .idle => "idle",
            .pending => "pending",
            .active => "active",
        };
        u.text("drag: {s}", .{phase_str});
        if (dd.phase == .active) {
            u.sameLine(.{});
            u.text("    payload: {s} ({d} bytes)", .{ dd.typeName(), dd.payload_len });
        }
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - UI drag-drop demo",
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
