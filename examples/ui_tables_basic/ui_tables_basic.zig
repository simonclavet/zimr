//! ui_tables_basic — port of the GL `ui_tables_basic` onto the WebGPU UI
//! host. A 4-column sortable scoreboard (click a header to sort, shift-click to
//! add a tie-breaker). Harness swap only; the table widget body is unchanged
//! (same real ui.zig table API: beginTable/tableSetupColumn/tableGetSortSpecs/…).
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const ui = z.ui_real;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const Row = struct {
    name: []const u8,
    score: i32,
    rank: i32,
    active: bool,
};

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,
    borders: bool = true,
    score_col_width: f32 = 100,
    rows: [8]Row = .{
        .{ .name = "Alice", .score = 9120, .rank = 1, .active = true },
        .{ .name = "Bob", .score = 8430, .rank = 2, .active = true },
        .{ .name = "Charlie", .score = 7755, .rank = 3, .active = false },
        .{ .name = "Diana", .score = 7042, .rank = 4, .active = true },
        .{ .name = "Eve", .score = 6388, .rank = 5, .active = false },
        .{ .name = "Frank", .score = 5901, .rank = 6, .active = true },
        .{ .name = "Grace", .score = 4225, .rank = 7, .active = true },
        .{ .name = "Henry", .score = 3140, .rank = 8, .active = false },
    },
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 26);
    s.* = .{ .ui_host = z.UiHost.init(gpa, font), .font = font };
}

/// Compare two rows using the table's current sort spec; first column that
/// yields a definite ordering wins, ties fall through to the next spec.
fn sortRows(specs: *const ui.TableSortSpecs, a: Row, b: Row) bool {
    for (specs.items()) |spec| {
        const ord: i32 = switch (spec.column_index) {
            0 => switch (std.mem.order(u8, a.name, b.name)) {
                .lt => -1,
                .gt => 1,
                .eq => 0,
            },
            1 => if (a.score < b.score) @as(i32, -1) else if (a.score > b.score) @as(i32, 1) else 0,
            2 => if (a.rank < b.rank) @as(i32, -1) else if (a.rank > b.rank) @as(i32, 1) else 0,
            3 => blk: {
                const ai: i32 = @intFromBool(a.active);
                const bi: i32 = @intFromBool(b.active);
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
    z.clearViewport(f, .{ .r = 16, .g = 18, .b = 26, .a = 255 });
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    if (u.window("Tables - layout core + sort", .{
        .initial_pos = .{ 20, 20 },
        .initial_size = .{ 760, 560 },
    })) |w| {
        defer w.close();

        u.text("4-column scoreboard. Click a header to sort; shift-click to add a tie-breaker.", .{});
        u.separator();
        _ = u.checkbox("borders", &s.borders);
        _ = u.slider("score column width", &s.score_col_width, .{ .min = 60, .max = 200, .fmt = "{d:.0}" });
        u.separator();

        if (u.beginTable("scoreboard", 4, .{ .borders = s.borders })) {
            u.tableSetupColumn("Name", .{ .sizing = .stretch });
            u.tableSetupColumn("Score", .{ .sizing = .fixed, .width = s.score_col_width });
            u.tableSetupColumn("Rank", .{ .sizing = .fixed, .width = 60 });
            u.tableSetupColumn("Active", .{ .sizing = .fixed, .width = 70 });
            u.tableHeadersRow();

            if (u.tableGetSortSpecs()) |specs| {
                std.mem.sort(Row, &s.rows, specs, sortRows);
            }

            for (s.rows) |r| {
                u.tableNextRow();
                _ = u.tableNextColumn();
                u.text("{s}", .{r.name});
                _ = u.tableNextColumn();
                u.text("{d}", .{r.score});
                _ = u.tableNextColumn();
                u.text("#{d}", .{r.rank});
                _ = u.tableNextColumn();
                u.text("{s}", .{if (r.active) "yes" else "no"});
            }
            u.endTable();
        }
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - UI tables basic",
            .width = 800,
            .height = 600,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
