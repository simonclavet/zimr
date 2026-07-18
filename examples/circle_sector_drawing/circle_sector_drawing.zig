//! circle_sector_drawing — a filled circular sector (pie slice) with its outline. The
//! swept angle rotates and breathes, the radius pulses, and — the point of the sample — the
//! segment count oscillates from chunky (you can see the polygonal facets) to smooth. Tap to
//! reveal the segment vertices as dots so the tessellation is literal. A panel echoes the
//! live parameters and the MANUAL/AUTO segment mode. Ported from raylib
//! examples/shapes/shapes_circle_sector_drawing.c (raygui sliders, here animated for phone).
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const co = @import("example_common");

const Vec2 = zm.Vec2;
const Color = zm.Color;
const bufPrint = std.fmt.bufPrint;
const radFromDeg = zm.radFromDeg;
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const State = struct {
    font: z.Font,
    time: f32 = 0,
    show_verts: bool = false,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{ .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24) };
}

fn update(f: *z.Frame, s: *State) void {
    const dt: f32 = f.time.delta_time;
    s.time += dt;
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();

    z.clearViewport(f, co.palette.bg);
    co.backdrop(f.gl, w, h);

    if (z.isMouseButtonPressed(f.input, .left)) {
        s.show_verts = !s.show_verts;
    }

    const center: Vec2 = co.center(w, h);
    const radius: f32 = @min(w, h) * (0.34 + 0.03 * @sin(s.time * 0.8));
    const start_angle: f32 = @mod(s.time * 18.0, 360.0);
    const span: f32 = 150.0 + 120.0 * @sin(s.time * 0.5);
    const end_angle: f32 = start_angle + span;

    // The lesson of this sample: segment count. Oscillate it from 3 (clearly faceted) to 24
    // (smooth) so the polygonal approximation of the arc is visible.
    const seg_f: f32 = 3.0 + 21.0 * (0.5 + 0.5 * @sin(s.time * 0.6));
    const segments: i32 = @trunc(seg_f);

    const fill: Color = .{ .r = 190, .g = 33, .b = 55, .a = 80 }; // MAROON, faded
    const line: Color = .{ .r = 230, .g = 90, .b = 110, .a = 230 };
    f.gl.circleSector(center, radius, radFromDeg(start_angle), radFromDeg(end_angle), segments, .{ .color = fill });
    f.gl.circleSectorLines(
        center,
        radius,
        radFromDeg(start_angle),
        radFromDeg(end_angle),
        segments,
        .{ .color = line },
    );

    // Optional: a dot at each segment boundary on the arc, so segments are countable.
    if (s.show_verts) {
        const a0: f32 = radFromDeg(start_angle);
        const a1: f32 = radFromDeg(end_angle);
        const dot_col: Color = .{ .r = 255, .g = 230, .b = 120, .a = 255 };
        var i: i32 = 0;
        while (i <= segments) : (i += 1) {
            const fr: f32 = float(i) / float(@max(segments, 1));
            const a: f32 = a0 + (a1 - a0) * fr;
            const pt: Vec2 = .{ center[0] + radius * @cos(a), center[1] + radius * @sin(a) };
            f.gl.circle(pt, 4.0, .{ .color = dot_col, .segments = 16 });
        }
    }

    // Mode read-out (raylib's MANUAL when segments meet the auto minimum, else AUTO).
    const min_segments: f32 = @ceil(span / 90.0);
    const manual: bool = float(segments) >= min_segments;

    const panel: Color = .{ .r = 20, .g = 24, .b = 34, .a = 200 };
    const border: Color = .{ .r = 90, .g = 200, .b = 230, .a = 180 };
    f.gl.rect(.{ .x = 10, .y = 40, .width = 270, .height = 96 }, .{ .color = panel });
    f.gl.rect(.{ .x = 10, .y = 40, .width = 270, .height = 96 }, .{ .color = border, .outline = 1.0 });

    var buf: [80]u8 = undefined;
    const seg_line: []const u8 = bufPrint(
        &buf,
        "segments: {d}  ({s})",
        .{ segments, if (manual) "MANUAL" else "AUTO" },
    ) catch "segments: ?";
    f.gl.text(
        .{ 22, 52 },
        seg_line,
        .{ .size = 14, .color = if (manual) co.palette.accent2 else co.palette.ink_dim, .font = &s.font },
    );

    var buf2: [80]u8 = undefined;
    const ang_line: []const u8 = bufPrint(
        &buf2,
        "span: {d:.0} deg  radius: {d:.0}",
        .{ span, radius },
    ) catch "span: --";
    f.gl.text(.{ 22, 74 }, ang_line, .{ .size = 13, .color = co.palette.ink, .font = &s.font });
    const hint: []const u8 = if (s.show_verts) "tap: hide vertices" else "tap: show vertices";
    f.gl.text(.{ 22, 96 }, hint, .{ .size = 13, .color = co.palette.ink_dim, .font = &s.font });

    co.caption(f.gl, s.font, "circle sector drawing");
    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - circle sector drawing",
            .width = 800,
            .height = 450,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
