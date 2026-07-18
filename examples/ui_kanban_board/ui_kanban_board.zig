// examples/ui_kanban_board.zig - P8.6 part 1 sort-flag demo.
//
// Kanban-themed task list demonstrating the new TableColumnOpts
// flags: `no_sort`, `no_sort_ascending`, `no_sort_descending`,
// and `default_sort`.  Single-table view (not a 4-lane board);
// the plan called for draggable cards across 4 lanes, but card
// drag-reorder needs hit-test + drag-state machinery that
// doesn't exist yet.  Filed in §13 backlog under "feature
// surfaced after kanban example".
//
// What each flag does, demonstrated here:
//
//   - Title column   → `no_sort = true`.  Click the header,
//                      nothing happens; visually no sort
//                      indicator.  Sorting alphabetically by
//                      task title isn't meaningful in a
//                      kanban context.
//
//   - Priority col   → `default_sort = .descending`,
//                      `no_sort_ascending = true`.  Opens
//                      sorted high-to-low.  Click again, stays
//                      descending — can't flip to ascending
//                      because least-important-at-top is never
//                      a useful kanban view.
//
//   - Age (days) col → `default_sort = .descending`.  Opens
//                      oldest-first (staleness = visibility).
//                      Click freely; both directions allowed.
//
//   - Status column  → no flags; cycles ascending → descending
//                      → none → ascending normally.
//
// `default_sort` seeds the table's sort spec at column-setup
// time.  Multiple columns with `default_sort` set: leftmost
// wins.  Once the user clicks ANY header, the user's choice
// sticks across frames — `default_sort` does NOT re-seed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const ui = z.ui_real;

const screen_w: i32 = 900;
const screen_h: i32 = 600;

const Status = enum {
    backlog,
    active,
    review,
    done,

    fn label(self: Status) []const u8 {
        return switch (self) {
            .backlog => "Backlog",
            .active => "Active",
            .review => "Review",
            .done => "Done",
        };
    }

    fn color(self: Status) Color {
        // Muted lane colours - the visual cue that this is a
        // kanban-derived view even rendered as a flat table.
        return switch (self) {
            .backlog => .{ .r = 120, .g = 120, .b = 130, .a = 255 },
            .active => .{ .r = 90, .g = 150, .b = 220, .a = 255 },
            .review => .{ .r = 220, .g = 170, .b = 90, .a = 255 },
            .done => .{ .r = 100, .g = 180, .b = 110, .a = 255 },
        };
    }
};

const Card = struct {
    title: []const u8,
    priority: i32, // 1..5, higher = more urgent
    age_days: i32,
    status: Status,
};

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,

    cards: [12]Card = .{
        .{ .title = "Migrate auth to OAuth2", .priority = 5, .age_days = 12, .status = .active },
        .{ .title = "Fix login race condition", .priority = 5, .age_days = 3, .status = .review },
        .{ .title = "Add dark mode toggle", .priority = 2, .age_days = 28, .status = .backlog },
        .{ .title = "Upgrade Postgres 14 → 16", .priority = 4, .age_days = 7, .status = .active },
        .{ .title = "Onboarding tour rewrite", .priority = 3, .age_days = 19, .status = .backlog },
        .{ .title = "Refactor billing service", .priority = 4, .age_days = 41, .status = .backlog },
        .{ .title = "Implement webhook retries", .priority = 3, .age_days = 5, .status = .review },
        .{ .title = "Polish landing page hero", .priority = 1, .age_days = 60, .status = .backlog },
        .{ .title = "CSV export bug — empty cells", .priority = 4, .age_days = 2, .status = .active },
        .{ .title = "Quarterly review prep", .priority = 2, .age_days = 9, .status = .done },
        .{ .title = "Security audit follow-ups", .priority = 5, .age_days = 33, .status = .review },
        .{ .title = "Switch CI to self-hosted", .priority = 3, .age_days = 15, .status = .done },
    },
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, @embedFile("atkinson_mono_ttf"), 22);
    s.* = .{ .font = font, .ui_host = z.UiHost.init(gpa, font) };
}

/// Compare two cards using the table's current sort spec.  Walks
/// the spec list in priority order; first column that yields a
/// definite ordering wins.  Column-index → field mapping is
/// hardcoded to match the tableSetupColumn order in update().
fn sortCards(
    specs: *const ui.TableSortSpecs,
    a: Card,
    b: Card,
) bool {
    for (specs.items()) |spec| {
        const ord: i32 = switch (spec.column_index) {
            0 => switch (std.mem.order(u8, a.title, b.title)) {
                .lt => -1,
                .gt => 1,
                .eq => 0,
            },
            1 => if (a.priority < b.priority) @as(i32, -1) else if (a.priority > b.priority) @as(i32, 1) else 0,
            2 => if (a.age_days < b.age_days) @as(i32, -1) else if (a.age_days > b.age_days) @as(i32, 1) else 0,
            3 => blk: {
                const ai: i32 = @intFromEnum(a.status);
                const bi: i32 = @intFromEnum(b.status);
                break :blk if (ai < bi) -1 else if (ai > bi) 1 else 0;
            },
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

    if (u.window("Kanban board (sort flags demo)", .{
        .initial_pos = .{ 20, 20 },
        .initial_size = .{ 860, 560 },
    })) |w| {
        defer w.close();

        u.text("Title: no_sort (click does nothing).  " ++
            "Priority: default_sort=desc, no_sort_ascending.  " ++
            "Age: default_sort=desc.  Status: cycles normally.", .{});
        u.separator();

        if (u.beginTable("kanban", 4, .{ .borders = true })) {
            u.tableSetupColumn("Title", .{
                .sizing = .stretch,
                .no_sort = true,
            });
            u.tableSetupColumn("Priority", .{
                .sizing = .fixed,
                .width = 100,
                .default_sort = .descending,
                .no_sort_ascending = true,
            });
            u.tableSetupColumn("Age (d)", .{
                .sizing = .fixed,
                .width = 90,
                .default_sort = .descending,
            });
            u.tableSetupColumn("Status", .{
                .sizing = .fixed,
                .width = 110,
            });

            u.tableHeadersRow();

            if (u.tableGetSortSpecs()) |specs| {
                std.mem.sort(Card, &s.cards, specs, sortCards);
            }

            for (s.cards) |c| {
                u.tableNextRow();

                _ = u.tableNextColumn();
                u.text("{s}", .{c.title});

                _ = u.tableNextColumn();
                u.text("P{d}", .{c.priority});

                _ = u.tableNextColumn();
                u.text("{d}", .{c.age_days});

                _ = u.tableNextColumn();
                // Coloured status text gives the kanban-lane
                // visual without needing per-lane columns.
                u.textColored(c.status.color(), "{s}", .{c.status.label()});
            }
            u.endTable();
        }
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - Kanban (sort flags)",
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
