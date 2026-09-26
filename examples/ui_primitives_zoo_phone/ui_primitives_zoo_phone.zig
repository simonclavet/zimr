// examples/ui_primitives_zoo_phone.zig - bug-hunter phone example.
//
// Visual smoke test for every canvas drawList primitive in zimr.
// One card per primitive, each rendered with a label saying what
// it SHOULD look like.  If anything renders blank, wrong colour,
// wrong position, or wrong shape, it's immediately obvious by
// eyeball - no snapshot baselines required.
//
// Why: through turns 410-437 zimr accumulated a set of canvas
// primitives (addLine / addArc / addPolyline / etc) whose only
// test coverage was at the COMMAND QUEUE level - "did the
// polyline cmd land with N points?" - not at the RENDERED PIXEL
// level.  Turn 437 found that `drawTriangleStrip` (the path
// every line/arc primitive routes through) had been shipping
// broken in WebGL2 with no texture binding + no UVs for many
// turns.  This example exists so the next such regression is
// visible the moment someone opens the page.
//
// Card layout:
//   [primitive name] [colour swatch]
//   [drawn primitive inside 350x140 canvas]
//
// Tap a primitive name (left side) to highlight which one
// you're looking at - useful when something renders wrong
// and you need to know exactly which API is at fault.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const sinTurns = zm.sinTurns;
const Vec2 = zm.Vec2;
const Color = zm.Color;
const tau = zm.tau;
const pi = zm.pi;
const float = zm.float;
const ui = z.ui_real;

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,

    // Animation phase in turns, 0..1 cycling every 4 seconds, used to drive
    // any primitives that look better moving (mainly the bezier
    // and the arc sweep).  Cycles forever.
    phase_turns: f32 = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, @embedFile("atkinson_mono_ttf"), 22);
    s.* = .{ .ui_host = z.UiHost.init(gpa, font), .font = font };
}

// A single test card.  `draw` is invoked with a rect describing
// the drawable area for the primitive; the card's outer chrome
// (label + frame) is drawn for the caller.
const Card = struct {
    label: []const u8,
    draw: *const fn (dl: ui.DrawListHandle, area: z.Rectangle, phase_turns: f32) void,
};

const card_height: f32 = 170;

fn drawCard(
    u: ui.Ui,
    card: Card,
    phase_turns: f32,
) void {
    u.text("{s}", .{card.label});
    const canvas_dim: Vec2 = .{ 380, card_height };
    if (u.beginCanvas(card.label, canvas_dim, .{})) |c| {
        defer u.endCanvas(c);
        // Subtle frame so the canvas extent is visible even when
        // the primitive itself draws nothing.  Uses addRectOutline
        // (the working drawRect path) so we never lose the frame.
        c.drawList().addRectOutline(c.rect, Color.fromWire(0xFF303540));
        // Slightly inset the drawing area so primitives near the
        // edge aren't clipped by the frame.
        const area: z.Rectangle = .{
            .x = c.rect.x + 8,
            .y = c.rect.y + 8,
            .width = c.rect.width - 16,
            .height = c.rect.height - 16,
        };
        card.draw(c.drawList(), area, phase_turns);
    }
    u.spacing();
}

// ----------------------------------------------------------------
// Individual primitive demos.  Each draws one thing inside
// `area` with a known expected shape.

const accent: Color = Color.fromWire(0xFF70C870); // green
const accent2: Color = Color.fromWire(0xFFFFB060); // amber
const accent3: Color = Color.fromWire(0xFFE07070); // red
const white: Color = Color.fromWire(0xFFFFFFFF);

fn drawRectFilledCard(
    dl: ui.DrawListHandle,
    area: z.Rectangle,
    phase_turns: f32,
) void {
    _ = phase_turns;
    // EXPECT: solid green rectangle in the middle.
    const r: z.Rectangle = .{
        .x = area.x + 60,
        .y = area.y + 20,
        .width = 80,
        .height = 60,
    };
    dl.addRectFilled(r, accent);
    // EXPECT: amber 80x60 rect to the right, with hairline outline.
    const r2: z.Rectangle = .{
        .x = area.x + 200,
        .y = area.y + 20,
        .width = 80,
        .height = 60,
    };
    dl.addRectFilled(r2, accent2);
    dl.addRectOutline(r2, white);
}

fn drawLineCard(
    dl: ui.DrawListHandle,
    area: z.Rectangle,
    phase_turns: f32,
) void {
    _ = phase_turns;
    // EXPECT: three lines at different thicknesses across the card.
    const y0: f32 = area.y + 30;
    const y1: f32 = area.y + 70;
    const y2: f32 = area.y + 110;
    const x0: f32 = area.x + 10;
    const x1: f32 = area.x + area.width - 10;
    dl.addLine(.{ x0, y0 }, .{ x1, y0 }, accent, 1);
    dl.addLine(.{ x0, y1 }, .{ x1, y1 }, accent2, 4);
    dl.addLine(.{ x0, y2 }, .{ x1, y2 }, accent3, 10);
}

fn drawDiagonalLinesCard(
    dl: ui.DrawListHandle,
    area: z.Rectangle,
    phase_turns: f32,
) void {
    _ = phase_turns;
    // EXPECT: an X drawn from corner to corner.
    dl.addLine(
        .{ area.x, area.y },
        .{ area.x + area.width, area.y + area.height },
        accent,
        3,
    );
    dl.addLine(
        .{ area.x + area.width, area.y },
        .{ area.x, area.y + area.height },
        accent2,
        3,
    );
}

fn drawArcCard(
    dl: ui.DrawListHandle,
    area: z.Rectangle,
    phase_turns: f32,
) void {
    // EXPECT: a quarter-arc, a semicircle, and a sweeping arc that
    // grows with phase_turns.  Top->bottom three rows.
    const cy: f32 = area.y + area.height * 0.5;
    const r: f32 = 45;

    // Quarter arc, top-right quadrant.
    dl.addArc(
        .{ area.x + 60, cy },
        r,
        -pi * 0.5,
        0,
        accent,
        3,
    );
    // Semi-circle, upper half.
    dl.addArc(
        .{ area.x + 180, cy },
        r,
        pi,
        tau,
        accent2,
        4,
    );
    // Animated full sweep - grows from 0 to 2 pi as phase_turns cycles.
    const a1: f32 = -pi * 0.5 + tau * phase_turns;
    dl.addArc(
        .{ area.x + 300, cy },
        r,
        -pi * 0.5,
        a1,
        accent3,
        5,
    );
}

fn drawArcFilledCard(
    dl: ui.DrawListHandle,
    area: z.Rectangle,
    phase_turns: f32,
) void {
    // EXPECT: a pie slice, a half-disk, and a full disk.
    const cy: f32 = area.y + area.height * 0.5;
    const r: f32 = 45;

    // Quarter pie slice (top-right quadrant).
    dl.addArcFilled(
        .{ area.x + 60, cy },
        r,
        -pi * 0.5,
        0,
        accent,
    );
    // Half disk (upper half).
    dl.addArcFilled(
        .{ area.x + 180, cy },
        r,
        pi,
        tau,
        accent2,
    );
    // Full disk via 2 pi sweep (animated start angle for visual cue).
    dl.addArcFilled(
        .{ area.x + 300, cy },
        r,
        phase_turns * tau,
        phase_turns * tau + tau,
        accent3,
    );
}

fn drawCircleCard(
    dl: ui.DrawListHandle,
    area: z.Rectangle,
    phase_turns: f32,
) void {
    _ = phase_turns;
    // EXPECT: three concentric circles, thin / medium / thick outline.
    const cx: f32 = area.x + area.width * 0.5;
    const cy: f32 = area.y + area.height * 0.5;
    dl.addCircle(.{ cx, cy }, 60, accent, 1);
    dl.addCircle(.{ cx, cy }, 40, accent2, 3);
    dl.addCircle(.{ cx, cy }, 20, accent3, 6);
}

fn drawCircleFilledCard(
    dl: ui.DrawListHandle,
    area: z.Rectangle,
    phase_turns: f32,
) void {
    _ = phase_turns;
    // EXPECT: three filled discs, decreasing size, overlapping.
    const cx: f32 = area.x + area.width * 0.5;
    const cy: f32 = area.y + area.height * 0.5;
    dl.addCircleFilled(.{ cx - 20, cy }, 50, accent);
    dl.addCircleFilled(.{ cx + 20, cy }, 40, accent2);
    dl.addCircleFilled(.{ cx, cy + 10 }, 28, accent3);
}

fn drawPolylineCard(
    dl: ui.DrawListHandle,
    area: z.Rectangle,
    phase_turns: f32,
) void {
    _ = phase_turns;
    // EXPECT: a zigzag (open polyline) on the left, a closed
    // polyline (triangle outline) on the right.
    const zigzag = [_]Vec2{
        .{ area.x + 10, area.y + 20 },
        .{ area.x + 40, area.y + 130 },
        .{ area.x + 70, area.y + 20 },
        .{ area.x + 100, area.y + 130 },
        .{ area.x + 130, area.y + 20 },
        .{ area.x + 160, area.y + 130 },
    };
    dl.addPolyline(&zigzag, accent, 3, false);

    const tri = [_]Vec2{
        .{ area.x + 220, area.y + 130 },
        .{ area.x + 280, area.y + 20 },
        .{ area.x + 340, area.y + 130 },
    };
    dl.addPolyline(&tri, accent2, 3, true);
}

fn drawPolygonCard(
    dl: ui.DrawListHandle,
    area: z.Rectangle,
    phase_turns: f32,
) void {
    _ = phase_turns;
    // EXPECT: filled hexagon on the left, filled pentagon on the right.
    const hex: [6]Vec2 = blk: {
        var out: [6]Vec2 = undefined;
        const cx: f32 = area.x + 70;
        const cy: f32 = area.y + area.height * 0.5;
        for (0..6) |i| {
            const a: f32 = float(i) * tau / 6.0;
            out[i] = .{ cx + 50 * @cos(a), cy + 50 * @sin(a) };
        }
        break :blk out;
    };
    dl.addPolygon(&hex, accent);

    const pent: [5]Vec2 = blk: {
        var out: [5]Vec2 = undefined;
        const cx: f32 = area.x + 260;
        const cy: f32 = area.y + area.height * 0.5;
        for (0..5) |i| {
            const a: f32 = float(i) * tau / 5.0 - pi * 0.5;
            out[i] = .{ cx + 50 * @cos(a), cy + 50 * @sin(a) };
        }
        break :blk out;
    };
    dl.addPolygon(&pent, accent2);
}

fn drawTriangleCard(
    dl: ui.DrawListHandle,
    area: z.Rectangle,
    phase_turns: f32,
) void {
    _ = phase_turns;
    // EXPECT: outline triangle (green), filled triangle (amber),
    // and a quad fill (red).
    dl.addTriangle(
        .{ area.x + 20, area.y + 130 },
        .{ area.x + 70, area.y + 20 },
        .{ area.x + 120, area.y + 130 },
        accent,
        2,
    );
    dl.addTriangleFilled(
        .{ area.x + 150, area.y + 130 },
        .{ area.x + 200, area.y + 20 },
        .{ area.x + 250, area.y + 130 },
        accent2,
    );
    dl.addQuadFilled(
        .{ area.x + 270, area.y + 20 },
        .{ area.x + 360, area.y + 30 },
        .{ area.x + 350, area.y + 130 },
        .{ area.x + 280, area.y + 120 },
        accent3,
    );
}

fn drawBezierCard(
    dl: ui.DrawListHandle,
    area: z.Rectangle,
    phase_turns: f32,
) void {
    // EXPECT: a cubic bezier from left to right with control
    // points swinging up/down based on phase_turns.
    const sway: f32 = sinTurns(phase_turns) * 60;
    const p1: Vec2 = .{ area.x + 10, area.y + area.height * 0.5 };
    const p2: Vec2 = .{ area.x + area.width * 0.33, area.y + area.height * 0.5 + sway };
    const p3: Vec2 = .{ area.x + area.width * 0.66, area.y + area.height * 0.5 - sway };
    const p4: Vec2 = .{ area.x + area.width - 10, area.y + area.height * 0.5 };
    dl.addBezierCubic(p1, p2, p3, p4, accent, 3);
    // Tiny dots at the control points so we can see the swing.
    dl.addCircleFilled(p2, 4, accent2);
    dl.addCircleFilled(p3, 4, accent3);
}

fn drawNgonCard(
    dl: ui.DrawListHandle,
    area: z.Rectangle,
    phase_turns: f32,
) void {
    // EXPECT: a stroked octagon, a filled pentagon, and a filled
    // 12-gon - three regular n-gons across the card.  Rotates
    // continuously to make sure rotation works.
    const cy: f32 = area.y + area.height * 0.5;
    const rot: f32 = phase_turns * tau;
    dl.addNgon(.{ area.x + 60, cy }, 50, 8, rot, accent, 3);
    dl.addNgonFilled(.{ area.x + 180, cy }, 50, 5, rot, accent2);
    dl.addNgonFilled(.{ area.x + 300, cy }, 50, 12, rot, accent3);
}

fn drawEllipseCard(
    dl: ui.DrawListHandle,
    area: z.Rectangle,
    phase_turns: f32,
) void {
    _ = phase_turns;
    // EXPECT: wide ellipse outline (green), tall ellipse outline
    // (amber), filled ellipse on the right (red).
    const cy: f32 = area.y + area.height * 0.5;
    dl.addEllipse(.{ area.x + 70, cy }, 60, 30, accent, 3);
    dl.addEllipse(.{ area.x + 200, cy }, 30, 60, accent2, 3);
    dl.addEllipseFilled(.{ area.x + 320, cy }, 50, 35, accent3);
}

fn drawTextCard(
    dl: ui.DrawListHandle,
    area: z.Rectangle,
    phase_turns: f32,
) void {
    _ = phase_turns;
    // EXPECT: small/medium/large text rendered inside the card.
    dl.addText("small text 14", .{ area.x + 10, area.y + 20 }, 14, accent);
    dl.addText("medium text 22", .{ area.x + 10, area.y + 50 }, 22, accent2);
    dl.addText("LARGE 36", .{ area.x + 10, area.y + 90 }, 36, accent3);
}

fn drawTransparencyCard(
    dl: ui.DrawListHandle,
    area: z.Rectangle,
    phase_turns: f32,
) void {
    _ = phase_turns;
    // EXPECT: three overlapping translucent discs.  Where they
    // overlap, the alpha should accumulate visibly.
    const cy: f32 = area.y + area.height * 0.5;
    const half_green: Color = Color.fromWire(0x8070C870);
    const half_amber: Color = Color.fromWire(0x80FFB060);
    const half_red: Color = Color.fromWire(0x80E07070);
    dl.addCircleFilled(.{ area.x + 130, cy }, 50, half_green);
    dl.addCircleFilled(.{ area.x + 180, cy }, 50, half_amber);
    dl.addCircleFilled(.{ area.x + 230, cy }, 50, half_red);
}

const cards = [_]Card{
    .{ .label = "addRectFilled / addRectOutline", .draw = &drawRectFilledCard },
    .{ .label = "addLine (1px, 4px, 10px)", .draw = &drawLineCard },
    .{ .label = "addLine (diagonals)", .draw = &drawDiagonalLinesCard },
    .{ .label = "addArc (stroked)", .draw = &drawArcCard },
    .{ .label = "addArcFilled (pie / disk)", .draw = &drawArcFilledCard },
    .{ .label = "addCircle (stroked)", .draw = &drawCircleCard },
    .{ .label = "addCircleFilled", .draw = &drawCircleFilledCard },
    .{ .label = "addPolyline (open + closed)", .draw = &drawPolylineCard },
    .{ .label = "addPolygon (filled hex + pent)", .draw = &drawPolygonCard },
    .{ .label = "addTriangle / addQuadFilled", .draw = &drawTriangleCard },
    .{ .label = "addBezierCubic", .draw = &drawBezierCard },
    .{ .label = "addNgon (rotating)", .draw = &drawNgonCard },
    .{ .label = "addEllipse / addEllipseFilled", .draw = &drawEllipseCard },
    .{ .label = "addText (small/medium/large)", .draw = &drawTextCard },
    .{ .label = "transparency / alpha blend", .draw = &drawTransparencyCard },
};

fn update(f: *z.Frame, s: *State) void {
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    s.phase_turns += s.ui_host.ctx.input.delta_time * 0.25; // 4-second cycle
    if (s.phase_turns >= 1.0) {
        s.phase_turns -= 1.0;
    }

    const fw: f32 = float(f.window.screen_width);
    const fh: f32 = float(f.window.screen_height);
    u.setNextWindowPos(.{ 0, 0 }, .{});
    u.setNextWindowSize(.{ fw, fh }, .{});
    if (u.window("zoo", .{
        .flags = .{
            .no_title_bar = true,
            .no_resize = true,
            .no_move = true,
            .no_collapse = true,
        },
    })) |w| {
        defer w.close();
        u.text("primitives zoo - {d} cards.  Scroll to see all.", .{cards.len});
        u.text("each card draws ONE primitive.  Blank = broken.", .{});
        u.separator();
        for (cards) |card| {
            drawCard(u, card, s.phase_turns);
        }
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - primitives zoo (phone)",
            .width = 420,
            .height = 800,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
