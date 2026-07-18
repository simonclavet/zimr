// examples/ui_full_showcase.zig
// The zimr UI capstone.  Single-file, ~2000-LOC interactive
// reference for every widget, layout primitive, and pattern
// introduced across Phases 0-3 of the ui-completion arc.  Six
// tabs:
//   1. Widgets   - button, checkbox, slider/drag/input over
//                  scalars + arrays, combo, radio, selectable,
//                  collapsingHeader, treeNode, color edit/picker,
//                  tooltips
//   2. Tables    - layout (fixed/stretch), headers + multi-key
//                  sort, scroll + sticky header, alternating row
//                  tints, per-row tint override
//   3. Plots     - plotLines, plotHistogram, hover-readout, the
//                  beginTooltip block API
//   4. Drawing   - every DrawList primitive (line, rect, circle,
//                  triangle, polyline, ellipse, bezier) - live
//                  parameter-tweakable, with rendering modes
//   5. Drag-drop - pick-and-place between lanes; source + target
//                  sides wired end-to-end
//   6. Polish    - pushStyle/popStyle, cursor helpers, label/
//                  text variants, indent
// What this file is for: copy-paste reference.  Read the panel
// matching your task, lift the pattern, adapt to your app.  Each
// panel is self-contained - state lives on its own substruct so
// you can isolate a section without untangling cross-references.

const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const float = zm.float;
const Vec2 = zm.Vec2;
const sin = zm.sin;
const ui = z.ui_real;

const screen_w: i32 = 1280;
const screen_h: i32 = 800;

// ============================================================================
// Per-panel state structs.  Each one is independent so a single
// panel's source can be extracted and reused without dragging the
// others along.
// ============================================================================

const WidgetsState = struct {
    counter: i32 = 0,
    show_advanced: bool = false,
    volume: f32 = 0.5,
    speed: f32 = 5.0,
    grid_size: i32 = 16,
    quality: i32 = 2,
    difficulty: i32 = 1,
    render_mode: i32 = 2,
    color3: [3]f32 = .{ 0.85, 0.25, 0.35 },
    color4: [4]f32 = .{ 0.20, 0.55, 0.95, 1.0 },
    color_pick_layout: i32 = 0, // 0=bar, 1=wheel
    color_pick_rgba: [4]f32 = .{ 0.4, 0.85, 0.3, 1.0 },
    selected_index: i32 = 0,
    name_buf: [64]u8 = std.mem.zeroes([64]u8),
    name_len: usize = 0,
    note_buf: [128]u8 = std.mem.zeroes([128]u8),
    note_len: usize = 0,
    pos_xy: [2]f32 = .{ 0.5, 0.5 },
    velocity_xyz: [3]f32 = .{ 1, 2, 3 },
    show_grouping: bool = true,
    tree_a_open: bool = false,
};

const BuildStatus = enum {
    queued,
    running,
    passed,
    failed,
    fn label(self: BuildStatus) []const u8 {
        return switch (self) {
            .queued => "queued",
            .running => "running",
            .passed => "passed",
            .failed => "failed",
        };
    }
    fn sortRank(self: BuildStatus) i32 {
        return switch (self) {
            .running => 0,
            .queued => 1,
            .failed => 2,
            .passed => 3,
        };
    }
};

const Build = struct {
    id: u32,
    name_buf: [24]u8,
    name_len: usize,
    status: BuildStatus,
    duration_s: i32,

    fn name(self: *const Build) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};
const TablesState = struct {
    builds: [80]Build = undefined,
    initialized: bool = false,
    show_striped: bool = true,
    show_highlight: bool = true,
    show_borders: bool = true,
    table_height: f32 = 340,
};

const PlotsState = struct {
    fps_hist: [120]f32 = std.mem.zeroes([120]f32),
    fps_idx: usize = 0,
    sine_phase: f32 = 0,
    sine_hist: [120]f32 = std.mem.zeroes([120]f32),
    sine_idx: usize = 0,
    histogram_bins: [12]f32 = .{ 4, 7, 12, 18, 24, 31, 28, 21, 15, 9, 5, 2 },
};

const DrawingState = struct {
    line_thickness: f32 = 2,
    circle_segments: i32 = 0, // 0 = auto
    bezier_segments: i32 = 0,
};

const Lane = enum {
    todo,
    doing,
    done,

    fn label(self: Lane) []const u8 {
        return switch (self) {
            .todo => "TODO",
            .doing => "DOING",
            .done => "DONE",
        };
    }
};
const Chip = struct {
    id: u32,
    title_buf: [24]u8,
    title_len: usize,
    lane: Lane,

    fn title(self: *const Chip) []const u8 {
        return self.title_buf[0..self.title_len];
    }
};
const ChipPayload = struct { chip_id: u32 };

const DragDropState = struct {
    chips: [9]Chip = undefined,
    initialized: bool = false,
};

const PolishState = struct {
    health: i32 = 87,
    score: i32 = 14250,
    level: u32 = 9,
    chunky: bool = true,
    accent_section: bool = true,
    accent_hue: i32 = 0, // 0=amber, 1=emerald, 2=sky, 3=rose
};

const DockingState = struct {
    // The capstone Docking tab is intentionally a "you've seen
    // the concepts, here's where to learn more" overview rather
    // than an embedded interactive dockspace.  Reason: dockSpaces
    // host top-level windows, and that interacts awkwardly with
    // a tab whose content disappears when another tab is active.
    // Standalone demos `ui_dock_basic` and `ui_dock_persistence`
    // are the deep-dive surface for docking.
    show_split_visual: bool = true,
};

// ============================================================================
// Top-level state - owns every panel's state plus the active tab.
// ============================================================================

const Tab = enum { widgets, tables, plots, drawing, drag_drop, docking, polish };

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,

    active_tab: Tab = .widgets,

    widgets: WidgetsState = .{},
    tables: TablesState = .{},
    plots: PlotsState = .{},
    drawing: DrawingState = .{},
    drag_drop: DragDropState = .{},
    docking: DockingState = .{},
    polish: PolishState = .{},
};

// ============================================================================
// Entry point + per-frame dispatch.
// ============================================================================

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, @embedFile("atkinson_mono_ttf"), 22);
    s.* = .{ .font = font, .ui_host = z.UiHost.init(gpa, font) };
    // Seed tables panel with 80 synthetic builds.
    var rng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0xc1c1eaf);
    const r: std.Random = rng.random();
    const branches = [_][]const u8{
        "main",
        "feature/x",
        "bugfix/123",
        "release-1.4",
        "deps-bump",
        "perf-pass",
        "feature/auth",
        "hotfix",
    };
    for (&s.tables.builds, 0..) |*b, i| {
        b.id = @intCast(i + 1);
        const br: []const u8 = branches[i % branches.len];
        const written: []u8 = bufPrint(&b.name_buf, "{s}#{d}", .{ br, b.id }) catch b.name_buf[0..0];
        b.name_len = written.len;
        const roll: u8 = r.intRangeAtMost(u8, 0, 99);
        b.status = if (roll < 55) .passed else if (roll < 75) .failed else if (roll < 90) .running else .queued;
        b.duration_s = if (b.status == .queued) 0 else r.intRangeAtMost(i32, 15, 1800);
    }
    s.tables.initialized = true;

    // Seed drag-drop chips: 9 work items spread across lanes.
    const chip_titles = [_]struct { title: []const u8, lane: Lane }{
        .{ .title = "Write spec", .lane = .todo },
        .{ .title = "Pick framework", .lane = .todo },
        .{ .title = "Draft RFC", .lane = .todo },
        .{ .title = "Prototype API", .lane = .doing },
        .{ .title = "Wire tests", .lane = .doing },
        .{ .title = "Profile hot path", .lane = .doing },
        .{ .title = "Setup CI", .lane = .done },
        .{ .title = "Pick logo color", .lane = .done },
        .{ .title = "File issue", .lane = .done },
    };
    for (&s.drag_drop.chips, chip_titles, 0..) |*c, t, i| {
        c.id = @intCast(i + 1);
        const written: []u8 = bufPrint(&c.title_buf, "{s}", .{t.title}) catch c.title_buf[0..0];
        c.title_len = written.len;
        c.lane = t.lane;
    }
    s.drag_drop.initialized = true;
}

fn panelWidgets(u: ui.Ui, s: *WidgetsState) void {
    u.text("Buttons + counters + tooltips", .{});
    if (u.button("Click me", .{})) {
        s.counter += 1;
    }
    if (u.isItemHovered(.{})) {
        u.setTooltip("Increments the counter below.", .{});
    }
    u.sameLine(.{});
    if (u.button("Reset", .{})) {
        s.counter = 0;
    }
    u.sameLine(.{});
    u.text("Counter: {d}", .{s.counter});

    u.separator();

    // ---- Checkboxes + scalar sliders ----
    u.text("Checkboxes + scalar sliders/drag/input", .{});
    _ = u.checkbox("Show advanced", &s.show_advanced);
    _ = u.slider("Volume (slider)", &s.volume, .{ .max = 1, .fmt = "{d:.2}" });
    _ = u.drag("Speed (drag, unbounded)", &s.speed, .{ .speed = 0.1, .fmt = "{d:.1}" });
    _ = u.drag("Grid size (int drag)", &s.grid_size, .{ .speed = 1, .min = 1, .max = 256, .fmt = "{d}" });

    u.separator();

    // ---- Multi-component sliders ----
    u.text("Multi-component sliders over *[N]T", .{});
    _ = u.slider("Pos (xy)", &s.pos_xy, .{ .min = 0, .max = 1, .fmt = "{d:.2}" });
    _ = u.drag("Velocity (xyz)", &s.velocity_xyz, .{ .speed = 0.05, .fmt = "{d:.2}" });

    u.separator();

    // ---- Radio + combo + selectable ----
    u.text("Radio buttons (one-of-N) + combo + selectable", .{});
    _ = u.radioButton("Easy", &s.difficulty, 0);
    u.sameLine(.{});
    _ = u.radioButton("Medium", &s.difficulty, 1);
    u.sameLine(.{});
    _ = u.radioButton("Hard", &s.difficulty, 2);

    const render_modes = [_][]const u8{ "Wireframe", "Flat", "Smooth", "PBR" };
    _ = u.combo("Render mode", &s.render_mode, &render_modes, .{});
    u.text("Quality:", .{});
    const quality_labels = [_][]const u8{ "Lowest", "Low", "Medium", "High", "Ultra" };
    for (quality_labels, 0..) |label, i| {
        const sel = (s.quality == @as(i32, @intCast(i)));
        if (u.selectable(label, sel, .{})) {
            s.quality = @intCast(i);
        }
    }

    u.separator();

    // ---- Text input ----
    u.text("Text input (single-line + multi-char buffer)", .{});
    _ = u.inputText("Name", &s.name_buf, &s.name_len, .{});
    _ = u.inputText("Note", &s.note_buf, &s.note_len, .{});

    u.separator();

    // ---- Color editors
    u.text("Color editors - inline (colorEdit) + block (colorPicker)", .{});
    _ = u.colorEdit("RGB inline", &s.color3, .{});
    _ = u.colorEdit("RGBA inline", &s.color4, .{});

    if (u.collapsingHeader("Color picker (bar + wheel)", &s.show_advanced)) {
        const layouts = [_][]const u8{ "bar", "wheel" };
        _ = u.combo("Layout", &s.color_pick_layout, &layouts, .{});
        const layout: ui.ColorPickerLayout = if (s.color_pick_layout == 0) .bar else .wheel;
        _ = u.colorPicker("Pick", &s.color_pick_rgba, .{ .layout = layout, .alpha = true });
    }

    u.separator();

    // ---- Hierarchy
    u.text("Hierarchy - collapsingHeader + treeNode + bullet", .{});
    _ = u.checkbox("Show grouping section", &s.show_grouping);
    if (s.show_grouping) {
        if (u.collapsingHeader("Inventory", &s.tree_a_open)) {
            u.indent();
            defer u.unindent();
            u.bulletText("Sword (+5)", .{});
            u.bulletText("Health potion x3", .{});
            u.bulletText("Map fragment", .{});
            if (u.treeNode("Quest items", .{})) {
                defer u.treePop();
                u.bulletText("Ancient key", .{});
                u.bulletText("Sealed letter", .{});
            }
        }
    }
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
            2 => a.status.sortRank() - b.status.sortRank(),
            3 => a.duration_s - b.duration_s,
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

fn panelTables(u: ui.Ui, s: *TablesState) void {
    u.text("Tables: layout + headers + multi-key sort + scroll + sticky header + row tints", .{});
    u.textDisabled("Click a header to sort.  Shift-click to add a tie-breaker.  Wheel-over to scroll.", .{});

    _ = u.checkbox("striped", &s.show_striped);
    u.sameLine(.{});
    _ = u.checkbox("highlight failures", &s.show_highlight);
    u.sameLine(.{});
    _ = u.checkbox("borders", &s.show_borders);
    _ = u.slider("table height", &s.table_height, .{ .min = 200, .max = 500, .fmt = "{d:.0}" });

    if (u.beginTable("capstone-builds", 4, .{
        .borders = s.show_borders,
        .outer_height = s.table_height,
        .freeze_rows = 1,
        .row_bg = s.show_striped,
    })) {
        u.tableSetupColumn("Build", .{ .sizing = .fixed, .width = 70 });
        u.tableSetupColumn("Name", .{ .sizing = .stretch });
        u.tableSetupColumn("Status", .{ .sizing = .fixed, .width = 100 });
        u.tableSetupColumn("Duration", .{ .sizing = .fixed, .width = 100 });

        u.tableHeadersRow();
        if (u.tableGetSortSpecs()) |specs| {
            std.mem.sort(Build, &s.builds, specs, sortBuilds);
        }

        for (s.builds) |b| {
            u.tableNextRow();
            if (s.show_highlight) {
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
            u.text("{s}", .{b.status.label()});
            _ = u.tableNextColumn();
            if (b.duration_s == 0) {
                u.text("--", .{});
            } else {
                const m: i32 = @divTrunc(b.duration_s, 60);
                const sec: i32 = @mod(b.duration_s, 60);
                u.text("{d}m{d:0>2}s", .{ m, sec });
            }
        }
        u.endTable();
    }
}

fn panelPlots(
    u: ui.Ui,
    s: *PlotsState,
    dt: f32,
) void {
    // Update the live FPS + sine ring buffers.
    const fps: f32 = if (dt > 0) 1.0 / dt else 60.0;
    s.fps_hist[s.fps_idx] = fps;
    s.fps_idx = (s.fps_idx + 1) % s.fps_hist.len;

    s.sine_phase += dt * 1.5;
    s.sine_hist[s.sine_idx] = sin(s.sine_phase) * 0.5 + 0.5;
    s.sine_idx = (s.sine_idx + 1) % s.sine_hist.len;

    u.text("Sparkline plots - plotLines + plotHistogram", .{});
    u.textDisabled("Hover any plot for the per-sample readout.", .{});
    u.separator();

    var overlay_buf: [32]u8 = undefined;
    const fps_overlay: []u8 = bufPrint(&overlay_buf, "FPS {d:.1}", .{fps}) catch overlay_buf[0..0];
    u.plotLines("Live FPS (last 120 frames)", &s.fps_hist, .{
        .overlay = fps_overlay,
        .min = 0,
        .max = 120,
        .height = 80,
    });

    u.plotLines("Sine wave (animated)", &s.sine_hist, .{
        .min = 0,
        .max = 1,
        .height = 60,
    });

    u.plotHistogram("Static histogram (12 bins)", &s.histogram_bins, .{
        .height = 80,
    });

    u.separator();

    // ---- beginTooltip block ----
    u.text("beginTooltip block API:", .{});
    if (u.button("Hover for a multi-widget tooltip", .{})) {}
    if (u.isItemHovered(.{})) {
        u.beginTooltip();
        defer u.endTooltip();
        u.text("This tooltip uses the BLOCK API.", .{});
        u.text("(setTooltip is single-line; beginTooltip lets you", .{});
        u.text("stack arbitrary widgets - text, swatches, sparklines.)", .{});
        u.separator();
        u.textColored(.{ .r = 251, .g = 191, .b = 36, .a = 255 }, "Live FPS history:", .{});
        u.plotLines("##tt-fps", &s.fps_hist, .{ .height = 40, .width = 200 });
    }
}

fn pack(c: Color) u32 {
    return @as(u32, c.r) | (@as(u32, c.g) << 8) | (@as(u32, c.b) << 16) | (@as(u32, c.a) << 24);
}

fn panelDrawing(u: ui.Ui, s: *DrawingState) void {
    u.text("DrawList primitives - every shape op, live tweakable.", .{});
    u.textDisabled("Tweak thickness + segment counts; shapes update live.", .{});

    _ = u.slider("line thickness", &s.line_thickness, .{ .min = 1, .max = 8, .fmt = "{d:.1}" });
    _ = u.drag("circle segments (0=auto)", &s.circle_segments, .{ .speed = 1, .min = 0, .max = 64, .fmt = "{d}" });
    _ = u.drag("bezier segments (0=auto)", &s.bezier_segments, .{ .speed = 1, .min = 0, .max = 64, .fmt = "{d}" });

    u.separator();

    const dl: *ui.DrawList = u.getDrawList() orelse return;
    const alloc: Allocator = u.drawListAllocator();
    const origin: Vec2 = u.getCursorScreenPos();

    // Reserve canvas space.  4-column grid, 2 rows.
    const cell_w: f32 = 130;
    const cell_h: f32 = 110;
    const cols: usize = 4;
    const rows: usize = 2;
    const canvas_w: f32 = cell_w * float(cols);
    const canvas_h: f32 = cell_h * float(rows);
    u.dummy(.{ canvas_w, canvas_h });

    // Palette.
    const red: u32 = pack(.{ .r = 239, .g = 68, .b = 68, .a = 255 });
    const sky: u32 = pack(.{ .r = 56, .g = 189, .b = 248, .a = 255 });
    const amber: u32 = pack(.{ .r = 245, .g = 158, .b = 11, .a = 255 });
    const lime: u32 = pack(.{ .r = 132, .g = 204, .b = 22, .a = 255 });
    const violet: u32 = pack(.{ .r = 168, .g = 85, .b = 247, .a = 255 });
    const cyan: u32 = pack(.{ .r = 34, .g = 211, .b = 238, .a = 255 });
    const pink: u32 = pack(.{ .r = 236, .g = 72, .b = 153, .a = 255 });
    const white: u32 = pack(.{ .r = 240, .g = 240, .b = 240, .a = 255 });

    const margin: f32 = 10;
    var idx: usize = 0;

    // Helper for cell-relative coords.
    const cellAt = struct {
        fn at(o: Vec2, cw: f32, ch: f32, i: usize, ncols: usize) Vec2 {
            const c: f32 = float(i % ncols);
            const r: f32 = float(i / ncols);
            return .{ o[0] + c * cw, o[1] + r * ch };
        }
    }.at;

    // 1. Line
    {
        const p: Vec2 = cellAt(origin, cell_w, cell_h, idx, cols);
        dl.addLine(
            alloc,
            .{ p[0] + margin, p[1] + margin },
            .{ p[0] + cell_w - margin, p[1] + cell_h - margin },
            red,
            s.line_thickness,
        );
        idx += 1;
    }
    // 2. Rect outline
    {
        const p: Vec2 = cellAt(origin, cell_w, cell_h, idx, cols);
        dl.addRectOutline(
            alloc,
            .{ .x = p[0] + margin, .y = p[1] + margin, .width = cell_w - 2 * margin, .height = cell_h - 2 * margin },
            sky,
        );
        idx += 1;
    }
    // 3. Rect filled
    {
        const p: Vec2 = cellAt(origin, cell_w, cell_h, idx, cols);
        dl.addRectFilled(
            alloc,
            .{ .x = p[0] + margin, .y = p[1] + margin, .width = cell_w - 2 * margin, .height = cell_h - 2 * margin },
            amber,
        );
        idx += 1;
    }
    // 4. Circle (outline)
    {
        const p: Vec2 = cellAt(origin, cell_w, cell_h, idx, cols);
        const segs: u32 = @intCast(s.circle_segments);
        dl.addCircle(
            alloc,
            .{ p[0] + cell_w * 0.5, p[1] + cell_h * 0.5 },
            (cell_h - 2 * margin) * 0.5,
            lime,
            s.line_thickness,
            segs,
        );
        idx += 1;
    }
    // 5. Circle filled
    {
        const p: Vec2 = cellAt(origin, cell_w, cell_h, idx, cols);
        const segs: u32 = @intCast(s.circle_segments);
        dl.addCircleFilled(
            alloc,
            .{ p[0] + cell_w * 0.5, p[1] + cell_h * 0.5 },
            (cell_h - 2 * margin) * 0.5,
            violet,
            segs,
        );
        idx += 1;
    }
    // 6. Triangle filled
    {
        const p: Vec2 = cellAt(origin, cell_w, cell_h, idx, cols);
        const cx: f32 = p[0] + cell_w * 0.5;
        const cy: f32 = p[1] + cell_h * 0.5;
        const r: f32 = (cell_h - 2 * margin) * 0.5;
        dl.addTriangleFilled(
            alloc,
            .{ cx, cy - r },
            .{ cx + r * 0.866, cy + r * 0.5 },
            .{ cx - r * 0.866, cy + r * 0.5 },
            cyan,
        );
        idx += 1;
    }
    // 7. Polyline (zig-zag)
    {
        const p: Vec2 = cellAt(origin, cell_w, cell_h, idx, cols);
        const pts = [_]Vec2{
            .{ p[0] + margin, p[1] + cell_h - margin },
            .{ p[0] + cell_w * 0.3, p[1] + margin },
            .{ p[0] + cell_w * 0.5, p[1] + cell_h - margin },
            .{ p[0] + cell_w * 0.7, p[1] + margin },
            .{ p[0] + cell_w - margin, p[1] + cell_h - margin },
        };
        dl.addPolyline(alloc, &pts, pink, s.line_thickness, false);
        idx += 1;
    }
    // 8. Ellipse filled
    {
        const p: Vec2 = cellAt(origin, cell_w, cell_h, idx, cols);
        dl.addEllipseFilled(
            alloc,
            .{ p[0] + cell_w * 0.5, p[1] + cell_h * 0.5 },
            (cell_w - 2 * margin) * 0.5,
            (cell_h - 2 * margin) * 0.35,
            white,
        );
        idx += 1;
    }
}

fn panelDragDrop(u: ui.Ui, s: *DragDropState) void {
    u.text("Drag-drop pick-and-place - 3 lanes, 9 chips.  Drag any chip between lanes.", .{});
    u.textDisabled("Visual: dragged chip floats with the cursor; hovered lane gets a highlight ring.", .{});
    u.separator();

    // Process any pending move resolved this frame.  We collect the
    // (chip_id → new_lane) intent across all targets, then apply.
    var moved_chip_id: ?u32 = null;
    var moved_to_lane: Lane = .todo;

    // Lane layout: three columns side-by-side.
    const lanes = [_]Lane{ .todo, .doing, .done };
    const start_x: f32 = u.getCursorPos()[0];
    const lane_w: f32 = 200;
    const lane_gap: f32 = 16;
    const start_y: f32 = u.getCursorPos()[1];

    for (lanes, 0..) |lane, li| {
        // Each lane is a column.  Position the cursor explicitly so
        // the three sit side-by-side regardless of intervening
        // newlines from chips submitted above.
        u.setCursorPos(.{ start_x + float(li) * (lane_w + lane_gap), start_y });

        // Lane header.
        u.text("{s}", .{lane.label()});
        // Chips for this lane.
        var count: u32 = 0;
        for (s.chips) |c| {
            if (c.lane != lane) {
                continue;
            }
            count += 1;
            // Each chip is a draggable button.
            const payload: ChipPayload = .{ .chip_id = c.id };
            _ = u.button(c.title(), .{});
            if (u.beginDragDropSource(.{})) {
                u.setDragDropPayload(ChipPayload, &payload);
                u.text("→ {s}", .{c.title()});
                u.endDragDropSource();
            }
        }

        // Lane drop target - a "dummy" widget at the bottom of the
        // lane acting as the drop zone.
        u.text("({d} item{s})", .{ count, if (count == 1) "" else "s" });
        u.dummy(.{ lane_w - 4, 24 });
        if (u.beginDragDropTarget(.{})) {
            if (u.acceptDragDropPayload(ChipPayload, .{})) |payload| {
                moved_chip_id = payload.chip_id;
                moved_to_lane = lane;
            }
            u.endDragDropTarget();
        }
    }

    // Apply the move (after all panels processed to avoid mid-iteration mutation).
    if (moved_chip_id) |cid| {
        for (&s.chips) |*c| {
            if (c.id == cid) {
                c.lane = moved_to_lane;
                break;
            }
        }
    }

    // Reset cursor below the widest lane.
    u.setCursorPos(.{ start_x, start_y + 280 });
    u.separator();
    u.textDisabled("Drop targets accept the typed payload only on the mouse-release frame.", .{});
    u.textDisabled("Type tag: @typeName(ChipPayload).  Other types would be rejected at the target.", .{});
}

fn panelDocking(u: ui.Ui, s: *DockingState) void {
    u.text("Docking - split a region into resizable leaf nodes.", .{});
    u.separator();

    u.text("Concepts shipped (turns 319-334):", .{});
    u.bulletText("dockSpace(id, size) creates a host region.", .{});
    u.bulletText("dockBuilderSplitNode(parent, dir, ratio) carves leaves.", .{});
    u.bulletText("dockBuilderDockWindow(title, leaf_id) anchors a window.", .{});
    u.bulletText("dockBuilderSetCentralNode marks the always-filling leaf.", .{});
    u.bulletText("dockBuilderSetSizeRef pins one side at a fixed px size.", .{});
    u.bulletText("Drag a title bar onto a dockspace - 5-zone overlay lights up.", .{});
    u.bulletText("Drag a title bar AWAY from a dock leaf - smooth tear-out.", .{});

    u.separator();
    u.text("Persistence (turn 334):", .{});
    u.bulletText("Set ctx.persistence_key once - layout serializes to .zon.", .{});
    u.bulletText("localStorage round-trip every 60 frames in endFrame.", .{});
    u.bulletText("F5 refresh: pending_dock_tree grafts back into beginFrame.", .{});

    u.separator();
    _ = u.checkbox("Show split visual sketch", &s.show_split_visual);
    if (s.show_split_visual) {
        u.text("Default 3-pane layout:", .{});
        u.textDisabled("  +----------+--------------+----------+", .{});
        u.textDisabled("  |  Tools   |   Viewport   |  Notes   |", .{});
        u.textDisabled("  |          |  (central)   |          |", .{});
        u.textDisabled("  +----------+--------------+----------+", .{});
    }

    u.separator();
    u.text("Standalone demos:", .{});
    u.bulletText("ui_dock_basic - mechanics + flags + size_ref + reset.", .{});
    u.bulletText("ui_dock_persistence - F5-survives layout + clear button.", .{});
}

fn panelPolish(u: ui.Ui, s: *PolishState) void {
    u.text("Polish helpers - pushStyle, cursor placement, label/text variants.", .{});

    // ---- labelText readouts ----
    u.separator();
    u.text("labelText - value-first / label-after on the same row:", .{});
    u.labelText("Health", "{d}%", .{s.health});
    u.labelText("Score", "{d}", .{s.score});
    u.labelText("Level", "{d}", .{s.level});

    // ---- textDisabled hints ----
    u.separator();
    u.text("textDisabled - dimmed for hints, captions:", .{});
    u.textDisabled("(tab to next field, enter to commit)", .{});

    // ---- pushStyle chunky button ----
    u.separator();
    u.text("pushStyle('frame_padding', ...) - chunky toggle:", .{});
    _ = u.checkbox("chunky", &s.chunky);
    if (s.chunky) {
        u.pushStyle("frame_padding", Vec2{ 14, 10 });
    } else {
        u.pushStyle("frame_padding", Vec2{ 4, 3 });
    }
    if (u.button("Save", .{})) {}
    u.sameLine(.{});
    if (u.button("Load", .{})) {}
    u.sameLine(.{});
    if (u.button("Reset", .{})) {}
    u.popStyle();

    // ---- pushStyle accent text ----
    u.separator();
    u.text("pushStyle('text', ...) - accent-colored section:", .{});
    _ = u.checkbox("accent section", &s.accent_section);
    const hue_labels = [_][]const u8{ "amber", "emerald", "sky", "rose" };
    _ = u.combo("hue", &s.accent_hue, &hue_labels, .{});
    if (s.accent_section) {
        const hue_color: Color = switch (s.accent_hue) {
            0 => .{ .r = 251, .g = 191, .b = 36, .a = 255 }, // amber-400
            1 => .{ .r = 16, .g = 185, .b = 129, .a = 255 }, // emerald-500
            2 => .{ .r = 56, .g = 189, .b = 248, .a = 255 }, // sky-400
            else => .{ .r = 244, .g = 63, .b = 94, .a = 255 }, // rose-500
        };
        u.pushStyle("text", hue_color);
        u.text("Accent text - this line and the next.", .{});
        u.text("Use pushStyle around any section that should pop.", .{});
        u.popStyle();
    } else {
        u.text("(accent off - default text color)", .{});
        u.text("Same content, neutral color.", .{});
    }

    // ---- setCursorPos corner badge ----
    u.separator();
    u.text("setCursorPos - pixel-precise corner badge:", .{});
    const saved: Vec2 = u.getCursorPos();
    // Compute the badge position relative to the saved cursor so the
    // badge lands consistently regardless of where the panel started.
    u.setCursorPos(.{ saved[0] + 980, saved[1] - 8 });
    u.pushStyle("text", Color{ .r = 16, .g = 185, .b = 129, .a = 255 });
    u.text("v2.7-alpha", .{});
    u.popStyle();
    u.setCursorPos(saved); // restore for normal flow
    u.textDisabled("(the badge above is positioned via setCursorPos)", .{});

    // ---- indent nesting ----
    u.separator();
    u.text("indent / unindent - manual nesting outside of trees:", .{});
    u.indent();
    u.text("L1: one indent in", .{});
    u.indent();
    u.text("L2: two indents in", .{});
    u.indent();
    u.text("L3: three indents in", .{});
    u.unindent();
    u.unindent();
    u.unindent();
    u.text("Back at the root.", .{});
}

fn update(f: *z.Frame, s: *State) void {
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    if (u.window("zimr UI - full capstone", .{
        .initial_pos = .{ 20, 20 },
        .initial_size = .{ 1240, 760 },
    })) |w| {
        defer w.close();

        // Header strip.
        u.text("The complete zimr UI surface - every widget, every pattern, in one tab-navigable doc.", .{});
        u.textDisabled("Click a tab to switch panels.  Each panel is self-contained.", .{});
        u.separator();

        if (u.beginTabBar("capstone-tabs", .{})) {
            defer u.endTabBar();

            if (u.beginTabItem("Widgets", null, .{})) {
                defer u.endTabItem();
                panelWidgets(u, &s.widgets);
                s.active_tab = .widgets;
            }
            if (u.beginTabItem("Tables", null, .{})) {
                defer u.endTabItem();
                panelTables(u, &s.tables);
                s.active_tab = .tables;
            }
            if (u.beginTabItem("Plots", null, .{})) {
                defer u.endTabItem();
                panelPlots(u, &s.plots, f.time.delta_time);
                s.active_tab = .plots;
            }
            if (u.beginTabItem("Drawing", null, .{})) {
                defer u.endTabItem();
                panelDrawing(u, &s.drawing);
                s.active_tab = .drawing;
            }
            if (u.beginTabItem("Drag-drop", null, .{})) {
                defer u.endTabItem();
                panelDragDrop(u, &s.drag_drop);
                s.active_tab = .drag_drop;
            }
            if (u.beginTabItem("Docking", null, .{})) {
                defer u.endTabItem();
                panelDocking(u, &s.docking);
                s.active_tab = .docking;
            }
            if (u.beginTabItem("Polish", null, .{})) {
                defer u.endTabItem();
                panelPolish(u, &s.polish);
                s.active_tab = .polish;
            }
        }
    }
}

// ============================================================================
// Panel 1: Widgets - every interactive primitive in one tour.
// ============================================================================

// ============================================================================
// Panel 2: Tables - every Phase 1 feature exercised.
// ============================================================================

// ============================================================================
// Panel 3: Plots - plotLines, plotHistogram, beginTooltip block.
// ============================================================================

// ============================================================================
// Panel 4: Drawing - every DrawList primitive in a single-row grid.
// ============================================================================

// ============================================================================
// Panel 5: Drag-drop - 3-lane kanban-style pick-and-place.
// ============================================================================

// ============================================================================
// Panel 6: Docking - overview + pointers to standalone demos.
// ============================================================================
// The dockspace itself is a top-level surface and doesn't compose
// cleanly into a tab whose content vanishes when another tab is
// active.  This panel describes the docking model and points at
// `ui_dock_basic` (mechanics) and `ui_dock_persistence` (.zon +
// localStorage round-trip) for the interactive surface.

// ============================================================================
// Panel 7: Polish - pushStyle, cursor placement, label/text variants.
// ============================================================================

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - UI full showcase",
            .width = screen_w,
            .height = screen_h,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
    .memory = .managed,
};
