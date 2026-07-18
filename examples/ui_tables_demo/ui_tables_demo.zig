// examples/ui_tables_demo.zig - Phase 1d capstone.
// Consolidates every table feature added across Phase 1a-d:
// - Layout: fixed + stretch columns (1a)
// - Headers + click-to-sort, multi-column shift-click (1b)
// - Scrolling inside a fixed height + sticky header (1c)
// - Alternating row backgrounds + per-row tint override (1d)
// The scenario: a CI build dashboard.  100 synthetic builds
// with name / status / duration / queue.  Failed builds get a
// red tint via tableSetRowBgColor; running builds get amber.
// Click headers to sort, shift-click to add tie-breakers.

const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const ui = z.ui_real;

const screen_w: i32 = 980;
const screen_h: i32 = 680;

const BuildStatus = enum {
    queued,
    running,
    passed,
    failed,
    cancelled,

    fn label(self: BuildStatus) []const u8 {
        return switch (self) {
            .queued => "queued",
            .running => "running",
            .passed => "passed",
            .failed => "failed",
            .cancelled => "cancelled",
        };
    }
    fn rank(self: BuildStatus) i32 {
        // Sort order: running > queued > failed > passed > cancelled.
        return switch (self) {
            .running => 0,
            .queued => 1,
            .failed => 2,
            .passed => 3,
            .cancelled => 4,
        };
    }
};

const Build = struct {
    id: u32,
    name_buf: [24]u8,
    name_len: usize,
    status: BuildStatus,
    duration_s: i32,
    queue: u32,

    fn name(self: *const Build) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

const n_builds: usize = 100;

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,

    builds: [n_builds]Build = undefined,
    initialized: bool = false,

    striped: bool = true,
    highlight_failures: bool = true,
    show_borders: bool = true,
    // P8.2 (turn 407): granular border flags exposed as
    // per-edge toggles.  Default to true to match the legacy
    // "borders draws everything" behaviour; the demo flips them
    // so users can see the effect interactively.
    borders_inner_h: bool = true,
    borders_outer_h: bool = true,
    borders_inner_v: bool = true,
    borders_outer_v: bool = true,
    // P8.3 (turn 408): padding-suppression flags.  Default false
    // (legacy padding behaviour); the demo's checkboxes flip them.
    no_pad_outer_x: bool = false,
    no_pad_inner_x: bool = false,
    // P8.4 (turn 412): sizing-mode selector for the second table
    // below.  Default `.stretch_same` matches pre-P8.4 behavior.
    sizing_mode_idx: i32 = 0,
    table_height: f32 = 380,
};

/// Names paired with `TableSizing` values, in the order the radio
/// group displays them.  Index from `State.sizing_mode_idx`.
const sizing_modes: [4]struct { label: []const u8, mode: ui.TableSizing } = .{
    .{ .label = "stretch_same", .mode = .stretch_same },
    .{ .label = "stretch_prop", .mode = .stretch_prop },
    .{ .label = "fixed_fit", .mode = .fixed_fit },
    .{ .label = "fixed_same", .mode = .fixed_same },
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, @embedFile("atkinson_mono_ttf"), 22);
    s.* = .{ .ui_host = z.UiHost.init(gpa, font), .font = font };
    var rng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0xc1c1eaf);
    const r: std.Random = rng.random();
    const branch_names: [16][]const u8 = .{
        "main",      "feature/x",    "bugfix/123", "release-1.4",
        "refactor",  "feature/auth", "deps-bump",  "ci-tune",
        "docs",      "release-1.5",  "hotfix",     "feature/ui",
        "perf-pass", "feature/db",   "wip",        "exp/gpu",
    };
    for (&s.builds, 0..) |*b, i| {
        b.id = @intCast(i + 1);
        const branch_name: []const u8 = branch_names[i % branch_names.len];
        const written: []u8 = bufPrint(&b.name_buf, "{s}#{d}", .{ branch_name, b.id }) catch b.name_buf[0..0];
        b.name_len = written.len;
        const status_roll: u8 = r.intRangeAtMost(u8, 0, 99);
        b.status = if (status_roll < 60)
            BuildStatus.passed
        else if (status_roll < 80)
            BuildStatus.failed
        else if (status_roll < 90)
            BuildStatus.running
        else if (status_roll < 97)
            BuildStatus.queued
        else
            BuildStatus.cancelled;
        b.duration_s = if (b.status == .queued) 0 else r.intRangeAtMost(i32, 15, 1800);
        b.queue = r.intRangeAtMost(u32, 1, 4);
    }
    s.initialized = true;
}

fn sortBuilds(
    specs: *const ui.TableSortSpecs,
    a: Build,
    b: Build,
) bool {
    for (specs.items()) |spec| {
        const ord: i32 = switch (spec.column_index) {
            0 => @as(i32, @intCast(a.id)) - @as(i32, @intCast(b.id)),
            1 => switch (std.mem.order(u8, a.name(), b.name())) {
                .lt => -1,
                .gt => 1,
                .eq => 0,
            },
            2 => a.status.rank() - b.status.rank(),
            3 => a.duration_s - b.duration_s,
            4 => @as(i32, @intCast(a.queue)) - @as(i32, @intCast(b.queue)),
            else => 0,
        };
        if (ord != 0) {
            return switch (spec.direction) {
                .ascending => ord < 0,
                .descending => ord > 0,
            };
        }
    }
    return false;
}

fn update(f: *z.Frame, s: *State) void {
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    if (u.window("Tables - full showcase", .{
        .initial_pos = .{ 20, 20 },
        .initial_size = .{ 940, 640 },
    })) |w| {
        defer w.close();

        u.text("CI build dashboard.  {d} builds.  All table features: layout + sort + scroll + tints.", .{n_builds});
        u.separator();

        _ = u.checkbox("striped rows", &s.striped);
        u.sameLine(.{});
        _ = u.checkbox("highlight failures/running", &s.highlight_failures);
        u.sameLine(.{});
        _ = u.checkbox("borders", &s.show_borders);
        // P8.2 demo (turn 407): granular border toggles.  Each
        // checkbox flips one of the four `borders_*` sub-flags.
        // The master `borders` checkbox above AND-gates them all.
        u.text("Border edges:", .{});
        u.sameLine(.{});
        _ = u.checkbox("inner H", &s.borders_inner_h);
        u.sameLine(.{});
        _ = u.checkbox("outer H", &s.borders_outer_h);
        u.sameLine(.{});
        _ = u.checkbox("inner V", &s.borders_inner_v);
        u.sameLine(.{});
        _ = u.checkbox("outer V", &s.borders_outer_v);
        // P8.3 demo (turn 408): no_pad_outer_x / no_pad_inner_x
        // toggles.  Watch column 0's content slide flush against
        // the outer-left edge when outer-X is checked; watch
        // columns 1..N-1 tighten up against their dividers when
        // inner-X is checked.
        u.text("No-pad X:", .{});
        u.sameLine(.{});
        _ = u.checkbox("outer X", &s.no_pad_outer_x);
        u.sameLine(.{});
        _ = u.checkbox("inner X", &s.no_pad_inner_x);
        _ = u.slider("table height", &s.table_height, .{ .min = 200, .max = 540, .fmt = "{d:.0}" });

        u.separator();

        if (u.beginTable("builds", 5, .{
            .borders = s.show_borders,
            .borders_inner_h = s.borders_inner_h,
            .borders_outer_h = s.borders_outer_h,
            .borders_inner_v = s.borders_inner_v,
            .borders_outer_v = s.borders_outer_v,
            .no_pad_outer_x = s.no_pad_outer_x,
            .no_pad_inner_x = s.no_pad_inner_x,
            .outer_height = s.table_height,
            .freeze_rows = 1,
            .row_bg = s.striped,
        })) {
            u.tableSetupColumn("Build", .{ .sizing = .fixed, .width = 70 });
            u.tableSetupColumn("Name", .{ .sizing = .stretch });
            u.tableSetupColumn("Status", .{ .sizing = .fixed, .width = 100 });
            u.tableSetupColumn("Duration", .{ .sizing = .fixed, .width = 100 });
            u.tableSetupColumn("Queue", .{ .sizing = .fixed, .width = 80 });

            u.tableHeadersRow();
            if (u.tableGetSortSpecs()) |specs| {
                std.mem.sort(Build, &s.builds, specs, sortBuilds);
            }

            for (s.builds) |b| {
                u.tableNextRow();
                if (s.highlight_failures) {
                    switch (b.status) {
                        .failed => u.tableSetRowBgColor(.{ .r = 220, .g = 60, .b = 60, .a = 50 }),
                        .running => u.tableSetRowBgColor(.{ .r = 240, .g = 180, .b = 40, .a = 60 }),
                        else => {},
                    }
                }
                _ = u.tableNextColumn();
                u.text("#{d}", .{b.id});
                _ = u.tableNextColumn();
                u.text("{s}", .{b.name()});
                _ = u.tableNextColumn();
                // P8.1 demo (turn 406): per-cell bg color via
                // tableSetCellBgColor.  Highlights ONLY the Status
                // column based on the build's current state; the
                // cell bg paints OVER the row bg (more specific
                // override wins) but UNDER the cell text.  Effect:
                // a colored chip behind the status label, regardless
                // of the row's overall highlight.
                if (s.highlight_failures) {
                    switch (b.status) {
                        .failed => u.tableSetCellBgColor(.{ .r = 200, .g = 40, .b = 40, .a = 120 }),
                        .running => u.tableSetCellBgColor(.{ .r = 220, .g = 160, .b = 30, .a = 140 }),
                        .passed => u.tableSetCellBgColor(.{ .r = 40, .g = 160, .b = 80, .a = 90 }),
                        else => {},
                    }
                }
                u.text("{s}", .{b.status.label()});
                _ = u.tableNextColumn();
                if (b.duration_s == 0) {
                    u.text("--", .{});
                } else {
                    const m: i32 = @divTrunc(b.duration_s, 60);
                    const sec: i32 = @mod(b.duration_s, 60);
                    u.text("{d}m{d:0>2}s", .{ m, sec });
                }
                _ = u.tableNextColumn();
                u.text("q{d}", .{b.queue});
            }
            u.endTable();
        }

        u.separator();
        u.text("Try: shift-click 'Status' then 'Duration' to group failures by length.", .{});

        // ---- P8.4 sizing-mode showcase (turn 412) -------------------
        // A small second table next to a mode selector so each of
        // the four `TableSizing` policies can be flipped through
        // and the layout change observed.  Three columns with
        // intentionally different content widths so the mode
        // differences pop:
        //   - "Id" (narrow numbers)
        //   - "Description" (long varied text)
        //   - "Tag" (short labels)
        u.separator();
        u.text("P8.4 sizing modes: each policy in TableSizing controls how unspecified columns size themselves.", .{});
        for (sizing_modes, 0..) |sm, i| {
            if (i > 0) {
                u.sameLine(.{});
            }
            // selectable() acts as a single-select radio chip.
            if (u.selectable(sm.label, s.sizing_mode_idx == @as(i32, @intCast(i)), .{})) {
                s.sizing_mode_idx = @intCast(i);
            }
        }
        const active_mode: ui.TableSizing = sizing_modes[@intCast(s.sizing_mode_idx)].mode;
        if (u.beginTable("sizing_demo", 3, .{
            .sizing = active_mode,
            .row_bg = true,
            .outer_height = 140,
        })) {
            // No per-column `sizing` override — every column inherits
            // from the table's policy.  Switching the mode above
            // shows how the same data lays out under each policy.
            u.tableSetupColumn("Id", .{});
            u.tableSetupColumn("Description", .{});
            u.tableSetupColumn("Tag", .{});
            u.tableHeadersRow();
            const rows: [4]struct { id: []const u8, desc: []const u8, tag: []const u8 } = .{
                .{ .id = "1", .desc = "short", .tag = "A" },
                .{ .id = "12", .desc = "medium length", .tag = "BB" },
                .{ .id = "123", .desc = "a noticeably longer description for this row", .tag = "CCC" },
                .{ .id = "1234", .desc = "tiny", .tag = "DDDD" },
            };
            for (rows) |row| {
                u.tableNextRow();
                _ = u.tableNextColumn();
                u.text("{s}", .{row.id});
                _ = u.tableNextColumn();
                u.text("{s}", .{row.desc});
                _ = u.tableNextColumn();
                u.text("{s}", .{row.tag});
            }
            u.endTable();
        }
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - UI tables demo",
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
