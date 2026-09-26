//! math_sine_cosine - unit-circle visualisation of sine & cosine, ported to WebGPU.
//! A point sweeps the unit circle (auto-advancing angle); the right triangle's legs ARE
//! cos (horizontal, blue) and sin (vertical, red). A sector arc marks the swept angle,
//! dashed lines mark the axes, and two wave traces below plot sin/cos over 0-360 deg with a
//! moving marker. Exercises the new drawSplineLinear / drawLineDashed /
//! drawCircleSectorLines primitives. Self-running, viewport-relative under `.responsive`.
const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const radFromDeg = zm.radFromDeg;
const Vec2 = zm.Vec2;
const Color = zm.Color;
const float = zm.float;
const tau = zm.tau;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
const c = Color;
const wave_points: usize = 64;

const State = struct {
    font: z.Font,
    angle_deg: f32 = 0,
    frame_count: usize = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{ .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24) };
}

fn update(f: *z.Frame, s: *State) void {
    s.frame_count += 1;
    s.angle_deg = @mod(s.angle_deg + 0.8, 360.0);
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    const m: f32 = @min(w, h);

    const cx: f32 = w * 0.42;
    const cy: f32 = h * 0.40;
    const r: f32 = m * 0.26;
    const ar: f32 = radFromDeg(s.angle_deg);
    const px: f32 = cx + r * @cos(ar);
    const py: f32 = cy - r * @sin(ar); // y-up

    const gray: Color = c.init(120, 126, 140, 200);
    const red: Color = c.init(235, 90, 90, 255);
    const blue: Color = c.init(90, 150, 235, 255);

    z.clearViewport(f, c.init(10, 12, 18, 255));

    // Dashed axes through the circle centre.
    f.gl.lineDashed(.{ cx - r - 20, cy }, .{ cx + r + 20, cy }, 1.0, 6, 5, .{ .color = gray });
    f.gl.lineDashed(.{ cx, cy - r - 20 }, .{ cx, cy + r + 20 }, 1.0, 6, 5, .{ .color = gray });

    // Unit circle + swept-angle sector (negative end-angle so it sweeps y-up).
    f.gl.circle(.{ cx, cy }, r, .{ .color = c.init(150, 156, 170, 255), .outline = 1 });
    f.gl.circleSectorLines(
        .{ cx, cy },
        r * 0.38,
        0,
        radFromDeg(-s.angle_deg),
        40,
        .{ .color = c.init(235, 200, 90, 255) },
    );

    // cos leg (horizontal), sin leg (vertical), radius, and the point.
    f.gl.line(.{ cx, cy }, .{ px, cy }, .{ .color = blue, .thickness = 3.0 });
    f.gl.line(.{ px, cy }, .{ px, py }, .{ .color = red, .thickness = 3.0 });
    f.gl.line(.{ cx, cy }, .{ px, py }, .{ .color = c.init(220, 224, 232, 255), .thickness = 2.0 });
    f.gl.circle(.{ px, py }, 6.0, .{ .color = c.init(245, 248, 252, 255), .segments = 16 });

    // Wave traces below: sin (red) and cos (blue) over 0..360, computed for this size.
    const wx: f32 = w * 0.06;
    const ww: f32 = w * 0.42;
    const wy: f32 = h * 0.82;
    const wh: f32 = m * 0.16;
    var sine_pts: [wave_points]Vec2 = undefined;
    var cos_pts: [wave_points]Vec2 = undefined;
    for (0..wave_points) |i| {
        const t: f32 = float(i) / float(wave_points - 1);
        const a: f32 = t * tau;
        sine_pts[i] = .{ wx + t * ww, wy - @sin(a) * wh };
        cos_pts[i] = .{ wx + t * ww, wy - @cos(a) * wh };
    }
    f.gl.lineDashed(.{ wx, wy }, .{ wx + ww, wy }, 1.0, 5, 4, .{ .color = gray });
    f.gl.splineLinear(&sine_pts, 2.0, .{ .color = red });
    f.gl.splineLinear(&cos_pts, 2.0, .{ .color = blue });
    const tt: f32 = s.angle_deg / 360.0;
    const msx: f32 = wx + tt * ww;
    f.gl.circle(.{ msx, wy - @sin(ar) * wh }, 4.0, .{ .color = red, .segments = 16 });
    f.gl.circle(.{ msx, wy - @cos(ar) * wh }, 4.0, .{ .color = blue, .segments = 16 });

    // Labels.
    f.gl.text(.{ px + 6, (cy + py) * 0.5 - 8 }, "sin", .{ .size = 16, .color = red, .font = &s.font });
    f.gl.text(.{ (cx + px) * 0.5 - 10, cy + 6 }, "cos", .{ .size = 16, .color = blue, .font = &s.font });
    var buf: [40]u8 = undefined;
    const lbl: []const u8 = bufPrint(&buf, "angle: {d:.0} deg", .{s.angle_deg}) catch "?";
    f.gl.text(.{ 12, 12 }, lbl, .{ .size = 16, .color = c.init(210, 214, 224, 230), .font = &s.font });
    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - sine & cosine",
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
