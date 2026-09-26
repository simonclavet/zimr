//! pie_chart - a live pie chart of N slices whose values breathe, so the
//! wedges continuously re-proportion. Each slice is an HSV-spread colour; the
//! slice under the pointer pops outward and is read out by name; a percentage
//! label rides each wedge at its mid-angle. Tap toggles a donut hole. Ported
//! from raylib examples/shapes/shapes_pie_chart.c (raygui spinner/checkboxes/
//! value editors, here animated and pointer-driven for phone).
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const common = @import("example_common");

const Vec2 = zm.Vec2;
const Color = zm.Color;
const atan2Rad = zm.atan2Rad;
const radFromDeg = zm.radFromDeg;
const degFromRad = zm.degFromRad;
const bufPrint = std.fmt.bufPrint;
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const n_slices: usize = 7;
const base_values = [n_slices]f32{ 300, 100, 450, 350, 600, 380, 750 };

const State = struct {
    font: z.Font,
    time: f32 = 0,
    donut: bool = false,
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

    z.clearViewport(f, common.palette.bg);
    common.backdrop(f.gl, w, h);

    if (z.isMouseButtonPressed(f.input, .left)) {
        s.donut = !s.donut;
    }

    const center: Vec2 = .{ w * 0.5, h * 0.5 };
    const radius: f32 = @min(w, h) * 0.36;

    // Per-slice animated values -> sweeps. Computed once so the draw pass and the
    // hover test agree on the moving slice boundaries.
    var values: [n_slices]f32 = undefined;
    var total: f32 = 0;
    var i: usize = 0;
    while (i < n_slices) : (i += 1) {
        const fi: f32 = float(i);
        values[i] = base_values[i] * (0.55 + 0.45 * @sin(s.time * 0.6 + fi * 1.3));
        total += values[i];
    }

    // Which slice is the pointer over? atan2 -> degrees in [0,360), then walk the
    // sweeps. -1 when outside the disc.
    const pointer: Vec2 = z.getMousePosition(f.input);
    const dx: f32 = pointer[0] - center[0];
    const dy: f32 = pointer[1] - center[1];
    const dist: f32 = @sqrt(dx * dx + dy * dy);
    var hovered: i32 = -1;
    if (dist <= radius and total > 0) {
        var ang: f32 = degFromRad(atan2Rad(dy, dx));
        if (ang < 0) {
            ang += 360.0;
        }
        var acc: f32 = 0;
        var j: usize = 0;
        while (j < n_slices) : (j += 1) {
            const sweep: f32 = values[j] / total * 360.0;
            if (ang >= acc and ang < acc + sweep) {
                hovered = @intCast(j);
                break;
            }
            acc += sweep;
        }
    }

    // Draw the wedges.
    var start_angle: f32 = 0;
    i = 0;
    while (i < n_slices) : (i += 1) {
        const fi: f32 = float(i);
        const sweep: f32 = if (total > 0) values[i] / total * 360.0 else 0;
        const mid: f32 = start_angle + sweep * 0.5;
        const hue: f32 = fi / float(n_slices) * 360.0;
        const color: Color = z.colorFromHSV(hue, 0.75, 0.9);
        const popped: bool = hovered == @as(i32, @intCast(i));
        const r: f32 = if (popped) radius + 18.0 else radius;
        f.gl.circleSector(center, r, radFromDeg(start_angle), radFromDeg(start_angle + sweep), 64, .{ .color = color });

        // Percentage label at the wedge mid-angle.
        if (values[i] > 0 and sweep > 12.0) {
            var lbuf: [16]u8 = undefined;
            const pct: f32 = values[i] / total * 100.0;
            const label: []const u8 = bufPrint(&lbuf, "{d:.0}%", .{pct}) catch "";
            const ts: Vec2 = z.measureText(s.font, label, 16);
            const lr: f32 = radius * 0.68;
            const lx: f32 = center[0] + @cos(radFromDeg(mid)) * lr - ts[0] * 0.5;
            const ly: f32 = center[1] + @sin(radFromDeg(mid)) * lr - ts[1] * 0.5;
            f.gl.text(.{ lx, ly }, label, .{ .size = 16, .color = common.palette.ink, .font = &s.font });
        }
        start_angle += sweep;
    }

    // Donut hole (raylib punches a background circle over the centre).
    if (s.donut) {
        f.gl.circle(center, radius * 0.42, .{ .color = common.palette.bg, .segments = 16 });
    }

    // Read-out panel.
    const panel: Color = .{ .r = 20, .g = 24, .b = 34, .a = 200 };
    const border: Color = .{ .r = 90, .g = 200, .b = 230, .a = 180 };
    f.gl.rect(.{ .x = 10, .y = 40, .width = 250, .height = 96 }, .{ .color = panel });
    f.gl.rect(.{ .x = 10, .y = 40, .width = 250, .height = 96 }, .{ .color = border, .outline = 1.0 });

    var buf: [48]u8 = undefined;
    const slc: []const u8 = bufPrint(&buf, "slices: {d}   total: {d:.0}", .{ n_slices, total }) catch "slices: ?";
    f.gl.text(.{ 22, 52 }, slc, .{ .size = 13, .color = common.palette.ink, .font = &s.font });

    var buf2: [48]u8 = undefined;
    const hov: []const u8 = if (hovered >= 0)
        (bufPrint(&buf2, "hover: slice {d:0>2}", .{hovered + 1}) catch "hover: --")
    else
        "hover: --";
    f.gl.text(.{ 22, 74 }, hov, .{ .size = 13, .color = common.palette.accent2, .font = &s.font });
    f.gl.text(
        .{ 22, 96 },
        if (s.donut) "tap: pie" else "tap: donut",
        .{ .size = 13, .color = common.palette.ink_dim, .font = &s.font },
    );

    common.caption(f.gl, s.font, "pie chart");
    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - pie chart",
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
