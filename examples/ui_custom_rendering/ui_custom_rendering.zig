// examples/ui_custom_rendering.zig - DrawList primitives showcase.
// Mirrors imgui's "Custom Rendering" demo section.  The window has
// a fixed-size canvas region; we record arbitrary primitives into
// the window's draw list and they get rendered with the rest of the
// UI in proper clip-rect order.
// The point of this demo: show every Phase 0a DrawList primitive in
// one place, driven by live sliders.  Useful both as a primitive
// gallery and as the answer to "how do I draw arbitrary stuff
// inside a window?".

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const radFromDeg = zm.radFromDeg;
const Vec2 = zm.Vec2;
const Color = zm.Color;
const ui = z.ui_real;

const screen_w: i32 = 900;
const screen_h: i32 = 600;

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,

    // Tunables, exposed as sliders.
    line_thickness: f32 = 2.0,
    polyline_thickness: f32 = 2.0,
    triangle_thickness: f32 = 2.0,
    circle_radius: f32 = 28.0,
    circle_thickness: f32 = 2.0,
    circle_segments: i32 = 0, // 0 = auto
    ngon_sides: i32 = 6,
    ngon_radius: f32 = 28.0,
    ngon_rotation_deg: f32 = 0.0,
    ngon_thickness: f32 = 2.0,
    ellipse_radius_h: f32 = 38.0,
    ellipse_radius_v: f32 = 22.0,
    bezier_thickness: f32 = 2.5,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, @embedFile("atkinson_mono_ttf"), 22);
    s.* = .{ .ui_host = z.UiHost.init(gpa, font), .font = font };
}

fn pack(c: Color) u32 {
    // Same packing as UI's internal `packColor` - RGBA little-endian.
    return (@as(u32, c.a) << 24) | (@as(u32, c.b) << 16) | (@as(u32, c.g) << 8) | @as(u32, c.r);
}

/// Small caption beneath each primitive cell.
fn labelCell(
    dl: *ui.DrawList,
    gpa: Allocator,
    s: []const u8,
    pos: Vec2,
) void {
    dl.addText(gpa, null, s, pos, 11, 0, 0, pack(.{ .r = 200, .g = 200, .b = 200, .a = 255 }));
}

/// Pull the active window's draw list and record one of every
/// primitive at a known canvas position.  The layout is a single
/// row of fixed-size cells, each a 90x90 patch.  Cells advance
/// horizontally; if we run out of width we wrap to the next row.
fn drawPrimitivesCanvas(u: ui.Ui, s: *const State) void {
    const dl: *ui.DrawList = u.getDrawList() orelse return;
    const gpa: Allocator = u.drawListAllocator();

    // Reserve a 600x200 vertical strip in the window's content area.
    // `dummy` advances the layout cursor; we read the screen pos
    // before that so we know where to draw.
    const origin: Vec2 = u.getCursorScreenPos();
    u.dummy(.{ 600, 220 });

    // ColorU32 helpers - pre-pack a few we'll reuse.
    const red: u32 = pack(.{ .r = 239, .g = 68, .b = 68, .a = 255 });
    const sky: u32 = pack(.{ .r = 56, .g = 189, .b = 248, .a = 255 });
    const amber: u32 = pack(.{ .r = 245, .g = 158, .b = 11, .a = 255 });
    const lime: u32 = pack(.{ .r = 132, .g = 204, .b = 22, .a = 255 });
    const violet: u32 = pack(.{ .r = 168, .g = 85, .b = 247, .a = 255 });
    const cyan: u32 = pack(.{ .r = 34, .g = 211, .b = 238, .a = 255 });
    const pink: u32 = pack(.{ .r = 236, .g = 72, .b = 153, .a = 255 });
    const white: u32 = pack(.{ .r = 240, .g = 240, .b = 240, .a = 255 });

    // Cell layout.
    const cell_w: f32 = 95;
    const cell_h: f32 = 100;
    const margin: f32 = 5;
    const cols: usize = 6;

    var i: usize = 0;
    const cell = struct {
        const CellPos = struct { x: f32, y: f32, cx: f32, cy: f32 };

        fn at(
            o: Vec2,
            w: f32,
            h: f32,
            idx: usize,
            c: usize,
        ) CellPos {
            const col_i: f32 = float(idx % c);
            const row_i: f32 = float(idx / c);
            const x: f32 = o[0] + col_i * w;
            const y: f32 = o[1] + row_i * h;
            return .{ .x = x, .y = y, .cx = x + w * 0.5, .cy = y + h * 0.5 };
        }
    };

    // 1. line
    {
        const p: cell.CellPos = cell.at(origin, cell_w, cell_h, i, cols);
        dl.addLine(
            gpa,
            .{ p.x + margin, p.y + margin },
            .{ p.x + cell_w - margin, p.y + cell_h - margin },
            red,
            s.line_thickness,
        );
        labelCell(dl, gpa, "line", .{ p.x, p.y + cell_h - 14 });
        i += 1;
    }

    // 2. polyline (open)
    {
        const p: cell.CellPos = cell.at(origin, cell_w, cell_h, i, cols);
        var pts: [5]Vec2 = .{
            .{ p.x + 10, p.y + cell_h - 15 },
            .{ p.x + 25, p.y + 30 },
            .{ p.x + 45, p.y + 55 },
            .{ p.x + 65, p.y + 20 },
            .{ p.x + cell_w - 10, p.y + cell_h - 15 },
        };
        dl.addPolyline(gpa, pts[0..], sky, s.polyline_thickness, false);
        labelCell(dl, gpa, "polyline", .{ p.x, p.y + cell_h - 14 });
        i += 1;
    }

    // 3. triangle outline
    {
        const p: cell.CellPos = cell.at(origin, cell_w, cell_h, i, cols);
        dl.addTriangle(
            gpa,
            .{ p.cx, p.y + 15 },
            .{ p.x + 15, p.y + cell_h - 20 },
            .{ p.x + cell_w - 15, p.y + cell_h - 20 },
            amber,
            s.triangle_thickness,
        );
        labelCell(dl, gpa, "triangle", .{ p.x, p.y + cell_h - 14 });
        i += 1;
    }

    // 4. triangle_filled
    {
        const p: cell.CellPos = cell.at(origin, cell_w, cell_h, i, cols);
        dl.addTriangleFilled(
            gpa,
            .{ p.cx, p.y + 15 },
            .{ p.x + 15, p.y + cell_h - 20 },
            .{ p.x + cell_w - 15, p.y + cell_h - 20 },
            lime,
        );
        labelCell(dl, gpa, "tri filled", .{ p.x, p.y + cell_h - 14 });
        i += 1;
    }

    // 5. quad_filled
    {
        const p: cell.CellPos = cell.at(origin, cell_w, cell_h, i, cols);
        dl.addQuadFilled(
            gpa,
            .{ p.cx, p.y + 12 },
            .{ p.x + cell_w - 15, p.cy },
            .{ p.cx, p.y + cell_h - 20 },
            .{ p.x + 15, p.cy },
            violet,
        );
        labelCell(dl, gpa, "quad", .{ p.x, p.y + cell_h - 14 });
        i += 1;
    }

    // 6. circle (outline)
    {
        const p: cell.CellPos = cell.at(origin, cell_w, cell_h, i, cols);
        const segs: u32 = @intCast(s.circle_segments);
        dl.addCircle(
            gpa,
            .{ p.cx, p.cy - 5 },
            s.circle_radius,
            cyan,
            s.circle_thickness,
            segs,
        );
        labelCell(dl, gpa, "circle", .{ p.x, p.y + cell_h - 14 });
        i += 1;
    }

    // 7. circle_filled
    {
        const p: cell.CellPos = cell.at(origin, cell_w, cell_h, i, cols);
        const segs: u32 = @intCast(s.circle_segments);
        dl.addCircleFilled(
            gpa,
            .{ p.cx, p.cy - 5 },
            s.circle_radius,
            pink,
            segs,
        );
        labelCell(dl, gpa, "circ filled", .{ p.x, p.y + cell_h - 14 });
        i += 1;
    }

    // 8. ngon (outline)
    {
        const p: cell.CellPos = cell.at(origin, cell_w, cell_h, i, cols);
        dl.addNgon(
            gpa,
            .{ p.cx, p.cy - 5 },
            s.ngon_radius,
            @intCast(s.ngon_sides),
            radFromDeg(s.ngon_rotation_deg),
            white,
            s.ngon_thickness,
        );
        labelCell(dl, gpa, "ngon", .{ p.x, p.y + cell_h - 14 });
        i += 1;
    }

    // 9. ngon_filled
    {
        const p: cell.CellPos = cell.at(origin, cell_w, cell_h, i, cols);
        dl.addNgonFilled(
            gpa,
            .{ p.cx, p.cy - 5 },
            s.ngon_radius,
            @intCast(s.ngon_sides),
            radFromDeg(s.ngon_rotation_deg),
            amber,
        );
        labelCell(dl, gpa, "ngon fill", .{ p.x, p.y + cell_h - 14 });
        i += 1;
    }

    // 10. bezier_cubic
    {
        const p: cell.CellPos = cell.at(origin, cell_w, cell_h, i, cols);
        dl.addBezierCubic(
            gpa,
            .{ p.x + 10, p.y + cell_h - 20 },
            .{ p.x + 25, p.y + 10 },
            .{ p.x + cell_w - 25, p.y + cell_h - 10 },
            .{ p.x + cell_w - 10, p.y + 15 },
            sky,
            s.bezier_thickness,
        );
        labelCell(dl, gpa, "bezier", .{ p.x, p.y + cell_h - 14 });
        i += 1;
    }

    // 11. ellipse (outline)
    {
        const p: cell.CellPos = cell.at(origin, cell_w, cell_h, i, cols);
        dl.addEllipse(
            gpa,
            .{ p.cx, p.cy - 5 },
            s.ellipse_radius_h,
            s.ellipse_radius_v,
            cyan,
            1,
        );
        labelCell(dl, gpa, "ellipse", .{ p.x, p.y + cell_h - 14 });
        i += 1;
    }

    // 12. ellipse_filled
    {
        const p: cell.CellPos = cell.at(origin, cell_w, cell_h, i, cols);
        dl.addEllipseFilled(
            gpa,
            .{ p.cx, p.cy - 5 },
            s.ellipse_radius_h,
            s.ellipse_radius_v,
            violet,
        );
        labelCell(dl, gpa, "ell filled", .{ p.x, p.y + cell_h - 14 });
        i += 1;
    }

    // 13. rect_filled_multi_color (gradient)
    {
        const p: cell.CellPos = cell.at(origin, cell_w, cell_h, i, cols);
        dl.addRectFilledMultiColor(
            gpa,
            .{ .x = p.x + 10, .y = p.y + 10, .width = cell_w - 20, .height = cell_h - 30 },
            red,
            amber,
            lime,
            sky,
        );
        labelCell(dl, gpa, "gradient", .{ p.x, p.y + cell_h - 14 });
        i += 1;
    }

    // 14. polyline (closed) - bonus, shows `closed = true` path
    {
        const p: cell.CellPos = cell.at(origin, cell_w, cell_h, i, cols);
        var pts: [5]Vec2 = .{
            .{ p.cx, p.y + 14 },
            .{ p.x + cell_w - 15, p.cy - 5 },
            .{ p.x + cell_w - 25, p.y + cell_h - 25 },
            .{ p.x + 25, p.y + cell_h - 25 },
            .{ p.x + 15, p.cy - 5 },
        };
        dl.addPolyline(gpa, pts[0..], lime, s.polyline_thickness, true);
        labelCell(dl, gpa, "polyline ⟲", .{ p.x, p.y + cell_h - 14 });
        i += 1;
    }
}

fn update(f: *z.Frame, s: *State) void {
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    if (u.window("DrawList primitives", .{
        .initial_pos = .{ 20, 20 },
        .initial_size = .{ 860, 560 },
    })) |w| {
        defer w.close();

        u.text("Every Phase 0a primitive, drawn inline via getDrawList().", .{});
        u.separator();

        drawPrimitivesCanvas(u, s);

        u.separator();
        u.text("Tuning", .{});
        u.separator();

        _ = u.slider("line thickness", &s.line_thickness, .{ .min = 1, .max = 10, .fmt = "{d:.1}" });
        _ = u.slider("polyline thickness", &s.polyline_thickness, .{ .min = 1, .max = 10, .fmt = "{d:.1}" });
        _ = u.slider("triangle thickness", &s.triangle_thickness, .{ .min = 1, .max = 10, .fmt = "{d:.1}" });
        _ = u.slider("circle radius", &s.circle_radius, .{ .min = 4, .max = 80, .fmt = "{d:.0}" });
        _ = u.slider("circle thickness", &s.circle_thickness, .{ .min = 1, .max = 10, .fmt = "{d:.1}" });
        _ = u.slider("circle segments (0 = auto)", &s.circle_segments, .{ .min = 0, .max = 128, .fmt = "{d}" });
        _ = u.slider("ngon sides", &s.ngon_sides, .{ .min = 3, .max = 12, .fmt = "{d}" });
        _ = u.slider("ngon radius", &s.ngon_radius, .{ .min = 4, .max = 80, .fmt = "{d:.0}" });
        _ = u.slider("ngon rotation", &s.ngon_rotation_deg, .{ .min = 0, .max = 360, .fmt = "{d:.0}" });
        _ = u.slider("ngon thickness", &s.ngon_thickness, .{ .min = 1, .max = 10, .fmt = "{d:.1}" });
        _ = u.slider("ellipse radius H", &s.ellipse_radius_h, .{ .min = 6, .max = 80, .fmt = "{d:.0}" });
        _ = u.slider("ellipse radius V", &s.ellipse_radius_v, .{ .min = 6, .max = 80, .fmt = "{d:.0}" });
        _ = u.slider("bezier thickness", &s.bezier_thickness, .{ .min = 1, .max = 8, .fmt = "{d:.1}" });
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - UI custom rendering",
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
