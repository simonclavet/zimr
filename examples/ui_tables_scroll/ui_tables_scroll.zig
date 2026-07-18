// examples/ui_tables_scroll.zig - Phase 1c scrolling tables demo.
// A 200-row scoreboard fitted inside a fixed-height scrolling
// table.  Header stays sticky at the top; wheel-over-table
// scrolls the data rows.  Sort + headers from Phase 1b all
// still work - try shift-clicking columns to compose a multi-key
// sort on the larger dataset.

const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const ui = z.ui_real;

const screen_w: i32 = 800;
const screen_h: i32 = 620;

const Row = struct {
    name_buf: [16]u8,
    name_len: usize,
    score: i32,
    rank: i32,
    active: bool,

    fn name(self: *const Row) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

const n_rows: usize = 200;

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,

    rows: [n_rows]Row = undefined,
    initialized: bool = false,

    table_height: f32 = 320,
    borders: bool = true,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, @embedFile("atkinson_mono_ttf"), 22);
    s.* = .{ .ui_host = z.UiHost.init(gpa, font), .font = font };
    // Seed 200 rows with synthetic data.  Names are "row<idx>"
    // padded into the inline buffer; scores / ranks have a
    // deterministic pattern so sorting is verifiable.
    var rng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0x5eed);
    const r: std.Random = rng.random();
    for (&s.rows, 0..) |*row, i| {
        const written: []u8 = bufPrint(&row.name_buf, "row{d:0>3}", .{i}) catch row.name_buf[0..0];
        row.name_len = written.len;
        row.score = r.intRangeAtMost(i32, 0, 10000);
        row.rank = @intCast(i + 1);
        row.active = (i % 3) != 0;
    }
    s.initialized = true;
}

fn sortRows(
    specs: *const ui.TableSortSpecs,
    a: Row,
    b: Row,
) bool {
    for (specs.items()) |spec| {
        const ord: i32 = switch (spec.column_index) {
            0 => switch (std.mem.order(u8, a.name(), b.name())) {
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
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    if (u.window("Tables - scrolling + sticky header", .{
        .initial_pos = .{ 20, 20 },
        .initial_size = .{ 760, 580 },
    })) |w| {
        defer w.close();

        u.text("{d} rows fitted inside a fixed-height table.  Wheel to scroll, click headers to sort.", .{n_rows});
        u.separator();

        _ = u.checkbox("borders", &s.borders);
        _ = u.slider("table height", &s.table_height, .{ .min = 120, .max = 480, .fmt = "{d:.0}" });

        u.separator();

        if (u.beginTable("scoreboard", 4, .{
            .borders = s.borders,
            .outer_height = s.table_height,
            .freeze_rows = 1,
        })) {
            u.tableSetupColumn("Name", .{ .sizing = .stretch });
            u.tableSetupColumn("Score", .{ .sizing = .fixed, .width = 100 });
            u.tableSetupColumn("Rank", .{ .sizing = .fixed, .width = 70 });
            u.tableSetupColumn("Active", .{ .sizing = .fixed, .width = 70 });

            u.tableHeadersRow();

            if (u.tableGetSortSpecs()) |specs| {
                std.mem.sort(Row, &s.rows, specs, sortRows);
            }

            for (s.rows) |row| {
                u.tableNextRow();
                _ = u.tableNextColumn();
                u.text("{s}", .{row.name()});
                _ = u.tableNextColumn();
                u.text("{d}", .{row.score});
                _ = u.tableNextColumn();
                u.text("#{d}", .{row.rank});
                _ = u.tableNextColumn();
                u.text("{s}", .{if (row.active) "yes" else "no"});
            }
            u.endTable();
        }

        u.separator();
        u.text("Hover the table and use the mouse wheel to scroll.", .{});
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - UI tables scroll",
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
