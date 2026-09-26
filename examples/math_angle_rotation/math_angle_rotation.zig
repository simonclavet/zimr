//! math_angle_rotation - four fixed reference lines (0/30/60/90 degrees) from the
//! centre with radial labels, plus one line that sweeps a full turn every six seconds with
//! its colour cycling by angle. Demonstrates the parametric (cos, sin) circle-point pattern.
//! Ported from raylib shapes_math_angle_rotation, themed with the shared scaffold.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const radFromDeg = zm.radFromDeg;
const common = @import("example_common");

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const fixed = [_]struct { angle: f32, label: []const u8 }{
    .{ .angle = 0, .label = "0deg" },
    .{ .angle = 30, .label = "30deg" },
    .{ .angle = 60, .label = "60deg" },
    .{ .angle = 90, .label = "90deg" },
};

const State = struct {
    font: z.Font,
    angle: f32 = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{ .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24) };
}

fn update(f: *z.Frame, s: *State) void {
    const dt: f32 = @floatCast(f.time.delta_time);
    s.angle = @mod(s.angle + 60.0 * dt, 360.0);
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    const cx: f32 = w * 0.5;
    const cy: f32 = h * 0.5;
    const len: f32 = @min(w, h) * 0.32;

    z.clearViewport(f, common.palette.bg);
    common.backdrop(f.gl, w, h);

    for (fixed) |e| {
        const rad: f32 = radFromDeg(e.angle);
        const ex: f32 = cx + @cos(rad) * len;
        const ey: f32 = cy + @sin(rad) * len;
        const col: common.Color = common.palette.ramp(e.angle * 3.0);
        f.gl.line(.{ cx, cy }, .{ ex, ey }, .{ .color = col, .thickness = 5.0 });
        const lx: f32 = cx + @cos(rad) * (len + 22.0);
        const ly: f32 = cy + @sin(rad) * (len + 22.0);
        f.gl.text(.{ lx, ly }, e.label, .{ .size = 16, .color = col, .font = &s.font });
    }

    const arad: f32 = radFromDeg(s.angle);
    const aex: f32 = cx + @cos(arad) * len;
    const aey: f32 = cy + @sin(arad) * len;
    f.gl.line(.{ cx, cy }, .{ aex, aey }, .{ .color = common.palette.ramp(s.angle), .thickness = 5.0 });
    f.gl.circle(.{ cx, cy }, 6.0, .{ .color = common.palette.ink, .segments = 16 });
    f.gl.circle(.{ aex, aey }, 7.0, .{ .color = common.palette.ramp(s.angle), .segments = 16 });

    common.caption(f.gl, s.font, "math angle rotation: fixed refs + a sweeping line");
    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - math angle rotation",
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
