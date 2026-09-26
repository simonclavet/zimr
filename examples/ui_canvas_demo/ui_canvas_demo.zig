// examples/ui_canvas_demo.zig
//
// Reference implementation of a CANVAS-BASED widget - a minimal
// node editor built on the canvas widget primitives.  Three
// draggable boxes connected by bezier lines, with pan + zoom.
//
// What this exercises:
//   - `u.beginCanvas` / `endCanvas` for the sub-region
//   - `c.drawList()` for arbitrary draws
//   - `c.pushTransform(pan, zoom)` for canvas pan + zoom
//   - `c.localMouse()` returning authoring-space coords
//   - `c.hovered()` for "is the mouse in the canvas right now"
//
// Pan: middle-mouse-drag (or right-click-drag on phone).
// Zoom: mouse wheel up/down on the canvas.
// Drag a node: left-click + drag on a node body.
//
// All node positions, pan/zoom state, and drag-in-progress state
// live in plain struct fields on `State` - Q2's `getState` isn't
// needed here because the example owns its data outright (this
// is a "user app" not a "library extension").
//
// Build standalone:
//   zig build install -Dfocus=ui_canvas_demo
//   python3 scripts/build_standalone.py ui_canvas_demo

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Vec2 = zm.Vec2;
const Color = zm.Color;
const clamp = zm.clamp;
const ui = z.ui_real;

const Node = struct {
    pos: Vec2,
    label: []const u8,
};

const Edge = struct {
    from: usize, // node index
    to: usize,
};

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,

    nodes: [3]Node = .{
        .{ .pos = .{ 80, 80 }, .label = "input" },
        .{ .pos = .{ 280, 200 }, .label = "process" },
        .{ .pos = .{ 80, 300 }, .label = "output" },
    },
    edges: [2]Edge = .{
        .{ .from = 0, .to = 1 },
        .{ .from = 1, .to = 2 },
    },

    // Pan + zoom on the canvas.
    pan: Vec2 = .{ 0, 0 },
    zoom: f32 = 1.0,

    // Which node is the user currently dragging?  null = none.
    dragging: ?usize = null,
    drag_offset: Vec2 = .{ 0, 0 },
};

const node_w: f32 = 100;
const node_h: f32 = 40;

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, @embedFile("atkinson_mono_ttf"), 22);
    s.* = .{ .font = font, .ui_host = z.UiHost.init(gpa, font) };
}

fn pointInNode(world: Vec2, top_left: Vec2) bool {
    return world[0] >= top_left[0] and world[0] < top_left[0] + node_w and
        world[1] >= top_left[1] and world[1] < top_left[1] + node_h;
}

fn nodeCenter(top_left: Vec2) Vec2 {
    return .{ top_left[0] + node_w * 0.5, top_left[1] + node_h * 0.5 };
}

fn update(f: *z.Frame, s: *State) void {
    z.clearViewport(f, .{ .r = 18, .g = 22, .b = 32, .a = 255 });

    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    if (u.window("Node graph", .{
        .initial_pos = .{ 10, 10 },
        .initial_size = .{ 620, 460 },
    })) |w| {
        defer w.close();

        u.text("drag nodes with LMB | wheel: zoom | middle-drag: pan", .{});
        u.text("pan = ({d:.0}, {d:.0})  zoom = {d:.2}x", .{ s.pan[0], s.pan[1], s.zoom });
        u.spacing();

        const c: ui.Ui.CanvasCtx = u.beginCanvas("graph", .{ 590, 360 }, .{}) orelse return;
        defer u.endCanvas(c);

        // ---- background ----
        c.drawList().addRectFilled(c.rect, Color.fromWire(0xFF1A2030));
        c.drawList().addRectOutline(c.rect, Color.fromWire(0xFF3F4858));

        // ---- pan + zoom controls (only when canvas is hovered) ----
        const lm_screen: Vec2 = .{
            s.ui_host.ctx.input.mouse_pos[0] - c.rect.x,
            s.ui_host.ctx.input.mouse_pos[1] - c.rect.y,
        };
        if (c.hovered()) {
            // Wheel zoom, keeping mouse-under-cursor at the same
            // authoring-space point.
            const wheel: f32 = s.ui_host.ctx.input.mouse_wheel_y;
            if (wheel != 0) {
                const old_zoom: f32 = s.zoom;
                const factor: f32 = if (wheel > 0) 1.1 else 1.0 / 1.1;
                s.zoom = clamp(old_zoom * factor, 0.25, 4.0);
                // Adjust pan so the world point under the mouse stays put:
                //   world = (screen - pan_old) / zoom_old
                //   want: world = (screen - pan_new) / zoom_new
                //   pan_new = screen - world * zoom_new
                const world_x: f32 = (lm_screen[0] - s.pan[0]) / old_zoom;
                const world_y: f32 = (lm_screen[1] - s.pan[1]) / old_zoom;
                s.pan = .{
                    lm_screen[0] - world_x * s.zoom,
                    lm_screen[1] - world_y * s.zoom,
                };
            }
            // Middle-drag pan: deferred - would track mouse delta
            // each frame while middle button held.  See section 13 backlog.
        }

        // Apply the canvas transform once for the whole frame.
        c.pushTransform(s.pan, .{ s.zoom, s.zoom });
        defer c.popTransform();

        const world_mouse: Vec2 = c.localMouse();

        // ---- drag state machine ----
        const lc: bool = s.ui_host.ctx.input.mouse_left_clicked and c.hovered();
        const lr: bool = s.ui_host.ctx.input.mouse_left_released;
        if (lc and s.dragging == null) {
            // Hit-test nodes back-to-front.
            var i: usize = s.nodes.len;
            while (i > 0) {
                i -= 1;
                const n: *Node = &s.nodes[i];
                if (pointInNode(world_mouse, n.pos)) {
                    s.dragging = i;
                    s.drag_offset = .{ world_mouse[0] - n.pos[0], world_mouse[1] - n.pos[1] };
                    break;
                }
            }
        }
        if (s.dragging) |idx| {
            if (s.ui_host.ctx.input.mouse_left_down) {
                s.nodes[idx].pos = .{
                    world_mouse[0] - s.drag_offset[0],
                    world_mouse[1] - s.drag_offset[1],
                };
            }
            if (lr) {
                s.dragging = null;
            }
        }

        // ---- draw edges (under the nodes) ----
        for (s.edges) |e| {
            const a: Vec2 = nodeCenter(s.nodes[e.from].pos);
            const b: Vec2 = nodeCenter(s.nodes[e.to].pos);
            const a_screen: Vec2 = c.toScreen(a);
            const b_screen: Vec2 = c.toScreen(b);
            // Bezier with horizontal handles for a nice flowing curve.
            const dx: f32 = (b_screen[0] - a_screen[0]) * 0.5;
            c.drawList().addBezierCubic(
                a_screen,
                .{ a_screen[0] + dx, a_screen[1] },
                .{ b_screen[0] - dx, b_screen[1] },
                b_screen,
                Color.fromWire(0xFF6090C0),
                2.0 * s.zoom,
            );
        }

        // ---- draw nodes ----
        for (s.nodes, 0..) |n, i| {
            const tl: Vec2 = c.toScreen(n.pos);
            const w_px: f32 = node_w * s.zoom;
            const h_px: f32 = node_h * s.zoom;
            const r: z.Rectangle = .{ .x = tl[0], .y = tl[1], .width = w_px, .height = h_px };
            const fill: Color = if (s.dragging == i) Color.fromWire(0xFF5070A0) else Color.fromWire(0xFF345078);
            c.drawList().addRectFilled(r, fill);
            c.drawList().addRectOutline(r, Color.fromWire(0xFFA0B8D8));
            // Label inside the box, slightly inset.
            const text_x: f32 = tl[0] + 8 * s.zoom;
            const text_y: f32 = tl[1] + 8 * s.zoom;
            c.drawList().addText(n.label, .{ text_x, text_y }, 14 * s.zoom, Color.fromWire(0xFFFFFFFF));
        }
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - canvas demo",
            .width = 640,
            .height = 480,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
