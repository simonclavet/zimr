//! ui_panes - port of the GL `ui_panes`: a three-pane workspace built from
//! the imgui-parity primitives. A horizontal splitter divides a file-tree pane
//! (collapsible `treeNode` folders + leaf files) from a right column, which a
//! vertical splitter divides into an editor pane and an output pane. Drag either
//! splitter bar to resize. Exercises `splitter`, `beginChild`, `treeNode`/`treePop`,
//! `setNextWindowSizeConstraints`, and `getContentRegionAvail` on the wgpu UiHost.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Vec2 = zm.Vec2;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const editor_text = [_][]const u8{
    "// examples/ui_panes.zig",
    "//",
    "// Three-pane workspace on the wgpu UiHost.",
    "",
    "const std = @import(\"std\");",
    "const z = @import(\"zimr\");",
    "",
    "const State = struct {",
    "    ui_host: z.UiHost,",
    "    left_w: f32 = 120,",
    "    top_h: f32 = 280,",
    "};",
    "",
    "pub const app: z.AppSpec(State) = .{ ... };",
};

const output_text = [_][]const u8{
    "[build] zig build wgpu-ui-panes",
    "[ok] resolved deps",
    "[ok] compiled ui_panes.wasm",
    "[run] starting frame loop",
    "[info] window 'Workspace' created",
    "[info] beginChild('tree') ok",
    "[info] splitter 'h_split' axis=.x",
    "[info] beginChild('right') ok",
    "[info]   beginChild('editor') ok",
    "[info]   splitter 'v_split' axis=.y",
    "[info]   beginChild('output') ok",
    "[ok] frame submitted",
};

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,
    left_w: f32 = 120,
    top_h: f32 = 280,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 28);
    var host: z.UiHost = z.UiHost.init(gpa, font);
    host.ctx.style.font_size = 16;
    host.ctx.style.frame_padding = .{ 10, 8 };
    host.ctx.style.item_spacing = .{ 8, 6 };
    s.* = .{ .ui_host = host, .font = font };
}

fn update(f: *z.Frame, s: *State) void {
    z.clearViewport(f, .{ .r = 15, .g = 23, .b = 42, .a = 255 });
    const u: z.ui_real.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    u.setNextWindowSizeConstraints(.{ 320, 480 }, null);
    if (u.window("Workspace", .{ .initial_pos = .{ 8, 8 }, .initial_size = .{ 380, 840 } })) |w| {
        defer w.close();

        u.text("zimr - panes", .{});
        u.textDisabled("Drag the splitter bars to resize the panes.", .{});

        const SPLIT_BAR_W: f32 = 4;
        const sp_x: f32 = s.ui_host.ctx.style.item_spacing[0];
        const sp_y: f32 = s.ui_host.ctx.style.item_spacing[1];

        const avail: Vec2 = u.getContentRegionAvail();
        const total_w: f32 = avail[0];
        const total_h: f32 = avail[1];
        const usable_w: f32 = total_w - SPLIT_BAR_W - 2 * sp_x;

        const min_left: f32 = 20;
        const min_right: f32 = 20;
        const max_left: f32 = usable_w - min_right;
        if (s.left_w < min_left) {
            s.left_w = min_left;
        }
        if (s.left_w > max_left) {
            s.left_w = max_left;
        }

        // ---- Left pane: file tree.
        if (u.beginChild("tree", .{ s.left_w, total_h }, .{})) {
            defer u.endChild();
            u.textDisabled("Tree", .{});
            if (u.treeNode("zimr", .{ .default_open = true })) {
                defer u.treePop();
                if (u.treeNode("src", .{ .default_open = true })) {
                    defer u.treePop();
                    _ = u.treeNode("ui.zig", .{ .leaf = true });
                    _ = u.treeNode("zimr.zig", .{ .leaf = true });
                    _ = u.treeNode("pbr3d.zig", .{ .leaf = true });
                }
                if (u.treeNode("examples", .{})) {
                    defer u.treePop();
                    _ = u.treeNode("ui_panes.zig", .{ .leaf = true });
                    _ = u.treeNode("damaged_helmet.zig", .{ .leaf = true });
                    _ = u.treeNode("music_streaming.zig", .{ .leaf = true });
                }
                _ = u.treeNode("build.zig", .{ .leaf = true });
                _ = u.treeNode("README.md", .{ .leaf = true });
            }
        }

        u.sameLine(.{});
        _ = u.splitter("h_split", &s.left_w, .x, .{
            .bar_width = SPLIT_BAR_W,
            .hit_extend = 16,
            .min1 = min_left,
            .min2 = min_right,
            .total_along_axis = usable_w + SPLIT_BAR_W,
        });
        u.sameLine(.{});

        // ---- Right column: editor + output, vertically split.
        if (u.beginChild("right", .{ 0, total_h }, .{})) {
            defer u.endChild();
            const r_avail: Vec2 = u.getContentRegionAvail();
            const r_h: f32 = r_avail[1];
            const usable_h: f32 = r_h - SPLIT_BAR_W - 2 * sp_y;
            const min_top: f32 = 20;
            const min_bot: f32 = 20;
            const max_top: f32 = usable_h - min_bot;
            if (s.top_h < min_top) {
                s.top_h = min_top;
            }
            if (s.top_h > max_top) {
                s.top_h = max_top;
            }

            if (u.beginChild("editor", .{ 0, s.top_h }, .{})) {
                defer u.endChild();
                u.textDisabled("Editor", .{});
                for (editor_text) |line| {
                    u.text("{s}", .{line});
                }
            }

            _ = u.splitter("v_split", &s.top_h, .y, .{
                .bar_width = SPLIT_BAR_W,
                .hit_extend = 16,
                .min1 = min_top,
                .min2 = min_bot,
                .total_along_axis = usable_h + SPLIT_BAR_W,
            });

            if (u.beginChild("output", .{ 0, 0 }, .{})) {
                defer u.endChild();
                u.textDisabled("Output", .{});
                for (output_text) |line| {
                    u.text("{s}", .{line});
                }
            }
        }
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - panes",
            .width = 400,
            .height = 880,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
