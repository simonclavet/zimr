//! kaleidoscope - symmetric trail art ported to WebGPU. A brush follows an
//! auto-driven Lissajous path; every frame the new segment is mirrored across N
//! rotational axes (plus an X-axis reflection) about the screen centre, so the stroke
//! wraps a full 360 deg into a kaleidoscope. A short ring buffer of recent brush points
//! gives a flowing, fading rainbow trail. The GL original was mouse-painted; this runs
//! itself so it's alive in a screenshot. Exercises `beginMode2D` (the 2D camera) to
//! centre the pattern, and is viewport-relative under `.responsive`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Vec2 = zm.Vec2;
const Camera2D = zm.Camera2D;
const Color = zm.Color;
const float = zm.float;
const pi = zm.pi;
const rotate2 = zm.rotate2;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
const c = Color;

const trail_len: usize = 150;
const symmetry: usize = 6;

const State = struct {
    font: z.Font,
    trail: [trail_len]Vec2 = @splat(Vec2{ 0, 0 }),
    count: usize = 0,
    head: usize = 0,
    frame_count: usize = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24);
    s.* = .{ .font = font };
}

fn update(f: *z.Frame, s: *State) void {
    s.frame_count += 1;
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    const m: f32 = @min(w, h);
    const t: f32 = f.time.time;

    // Auto-driven brush in centre-relative coords (a Lissajous figure).
    const radius: f32 = m * 0.30;
    const brush: Vec2 = .{ radius * @cos(t * 0.7), radius * @sin(t * 1.1) };
    s.trail[s.head] = brush;
    s.head = (s.head + 1) % trail_len;
    if (s.count < trail_len) {
        s.count += 1;
    }

    const thick: f32 = m * 0.006 + 1.0;
    const angle_step: f32 = (2.0 * pi) / float(symmetry);

    z.clearViewport(f, c.init(8, 8, 14, 255));

    const cam: Camera2D = .{
        .target = .{ 0, 0 },
        .offset = .{ w * 0.5, h * 0.5 },
        .rotation = 0,
        .zoom = 1,
    };
    z.beginMode2D(f.gl, cam);
    if (s.count > 1) {
        const start: usize = (s.head + trail_len - s.count) % trail_len;
        var k: usize = 0;
        while (k + 1 < s.count) : (k += 1) {
            const p0: Vec2 = s.trail[(start + k) % trail_len];
            const p1: Vec2 = s.trail[(start + k + 1) % trail_len];
            const num: f32 = float(k + 1);
            const den: f32 = float(s.count);
            const alpha: f32 = num / den;
            const hue: f32 = @mod(t * 40.0 + num * 1.2, 360.0);
            const col: Color = z.colorFromHSV(hue, 0.7, 0.95);
            var a_idx: usize = 0;
            while (a_idx < symmetry) : (a_idx += 1) {
                const ang: f32 = angle_step * float(a_idx);
                const r0: Vec2 = rotate2(p0, ang);
                const r1: Vec2 = rotate2(p1, ang);
                f.gl.line(r0, r1, .{ .color = col.fade(alpha), .thickness = thick });
                const m0: Vec2 = .{ r0[0], -r0[1] };
                const m1: Vec2 = .{ r1[0], -r1[1] };
                f.gl.line(m0, m1, .{ .color = col.fade(alpha), .thickness = thick });
            }
        }
    }
    z.endMode2D(f.gl);

    f.gl.text(
        .{ 12, 12 },
        "kaleidoscope: auto-driven symmetric trail",
        .{ .size = 16, .color = c.init(210, 214, 224, 220), .font = &s.font },
    );
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - kaleidoscope",
            .width = 800,
            .height = 450,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
    .memory = .managed,
};
