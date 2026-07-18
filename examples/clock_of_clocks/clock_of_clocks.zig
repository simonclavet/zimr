//! clock_of_clocks — the time as HHMMSS, where every digit is a 4x6 grid of 24 tiny analog
//! clocks. Each little clock has two hands; neighbouring hands line up to trace the strokes of the
//! digit. When a digit changes the hands sweep to their new pose with a smoothstep. Driven by the
//! real wall clock via z.localTime(). Tap to toggle 12/24-hour mode (raylib uses SPACE).
//! From raylib shapes_clock_of_clocks.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const co = @import("example_common");

const sin = zm.sin;
const cos = zm.cos;
const clamp = zm.clamp;
const float = zm.float;
const rad_per_deg = zm.rad_per_deg;
const Vec2 = zm.Vec2;
const Color = zm.Color;
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
const bufPrint = std.fmt.bufPrint;

// A cell's state is a pair of hand angles (degrees): .x = big hand, .y = little hand.
// Named poses: corners bend two hands into an L; hh/vv are straight lines; zz is "blank".
const tl: Vec2 = .{ 0, 90 };
const tr: Vec2 = .{ 90, 180 };
const br: Vec2 = .{ 180, 270 };
const bl: Vec2 = .{ 0, 270 };
const hh: Vec2 = .{ 0, 180 };
const vv: Vec2 = .{ 90, 270 };
const zz: Vec2 = .{ 135, 135 };

// Each digit 0-9 as 24 cells (6 rows x 4 cols), row-major.
const digit_angles = [10][24]Vec2{
    .{ tl, hh, hh, tr, vv, tl, tr, vv, vv, vv, vv, vv, vv, vv, vv, vv, vv, bl, br, vv, bl, hh, hh, br },
    .{ tl, hh, tr, zz, bl, tr, vv, zz, zz, vv, vv, zz, zz, vv, vv, zz, tl, br, bl, tr, bl, hh, hh, br },
    .{ tl, hh, hh, tr, bl, hh, tr, vv, tl, hh, br, vv, vv, tl, hh, br, vv, bl, hh, tr, bl, hh, hh, br },
    .{ tl, hh, hh, tr, bl, hh, tr, vv, tl, hh, br, vv, bl, hh, tr, vv, tl, hh, br, vv, bl, hh, hh, br },
    .{ tl, tr, tl, tr, vv, vv, vv, vv, vv, bl, br, vv, bl, hh, tr, vv, zz, zz, vv, vv, zz, zz, bl, br },
    .{ tl, hh, hh, tr, vv, tl, hh, br, vv, bl, hh, tr, bl, hh, tr, vv, tl, hh, br, vv, bl, hh, hh, br },
    .{ tl, hh, hh, tr, vv, tl, hh, br, vv, bl, hh, tr, vv, tl, tr, vv, vv, bl, br, vv, bl, hh, hh, br },
    .{ tl, hh, hh, tr, bl, hh, tr, vv, zz, zz, vv, vv, zz, zz, vv, vv, zz, zz, vv, vv, zz, zz, bl, br },
    .{ tl, hh, hh, tr, vv, tl, tr, vv, vv, bl, br, vv, vv, tl, tr, vv, vv, bl, br, vv, bl, hh, hh, br },
    .{ tl, hh, hh, tr, vv, tl, tr, vv, vv, bl, br, vv, bl, hh, tr, vv, tl, hh, br, vv, bl, hh, hh, br },
};

const face_size = 24.0;
const face_spacing = 8.0;
const section_spacing = 16.0;
const move_duration = 0.5;

const hands_col: Color = .{ .r = 242, .g = 236, .b = 178, .a = 255 };
const ring_col: Color = .{ .r = 66, .g = 72, .b = 90, .a = 255 };

const State = struct {
    font: z.Font,
    current: [6][24]Vec2 = @splat(@splat(.{ 0, 0 })),
    src: [6][24]Vec2 = @splat(@splat(.{ 0, 0 })),
    dst: [6][24]Vec2 = @splat(@splat(.{ 0, 0 })),
    prev_second: i32 = -1,
    timer: f32 = 0,
    hour_mode: i64 = 24,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{ .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24) };
}

fn lerpf(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn update(f: *z.Frame, s: *State) void {
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    const dt_frame: f32 = f.time.delta_time;
    z.clearViewport(f, co.palette.bg);

    // tap toggles 12/24-hour mode
    if (z.isMouseButtonReleased(f.input, .left)) {
        s.hour_mode = 36 - s.hour_mode;
    }

    // real local time -> six digits HHMMSS (hours taken mod the active mode)
    const now: z.DateTime = z.localTime();
    const hours: i64 = @mod(@as(i64, now.hour), s.hour_mode);
    const digits = [6]usize{
        @intCast(@divFloor(hours, 10)),      @intCast(@mod(hours, 10)),
        @intCast(@divFloor(now.minute, 10)), @intCast(@mod(now.minute, 10)),
        @intCast(@divFloor(now.second, 10)), @intCast(@mod(now.second, 10)),
    };

    // when the second ticks, retarget every hand and restart the sweep
    if (now.second != s.prev_second) {
        s.prev_second = now.second;
        for (0..6) |d| {
            const blank_lead: bool = (d == 0 and s.hour_mode == 12 and digits[0] == 0);
            for (0..24) |c| {
                s.src[d][c] = s.current[d][c];
                const target: Vec2 = if (blank_lead) zz else digit_angles[digits[d]][c];
                // unwrap so the hands always rotate forward to the new pose
                if (s.src[d][c][0] > target[0]) {
                    s.src[d][c][0] -= 360.0;
                }
                if (s.src[d][c][1] > target[1]) {
                    s.src[d][c][1] -= 360.0;
                }
                s.dst[d][c] = target;
            }
        }
        s.timer = -dt_frame;
    }

    if (s.timer < move_duration) {
        s.timer = clamp(s.timer + dt_frame, 0.0, move_duration);
        var t: f32 = s.timer / move_duration;
        t = t * t * (3.0 - 2.0 * t); // smoothstep
        for (0..6) |d| {
            for (0..24) |c| {
                s.current[d][c] = .{
                    lerpf(s.src[d][c][0], s.dst[d][c][0], t),
                    lerpf(s.src[d][c][1], s.dst[d][c][1], t),
                };
            }
        }
    }

    drawClocks(f, s, w, h);

    var buf: [48]u8 = undefined;
    const line: []const u8 = bufPrint(&buf, "{d}-hour mode - tap to switch", .{s.hour_mode}) catch "";
    co.caption(f.gl, s.font, line);
    z.endDrawing(f.gl);
}

fn drawHand(
    gl: *z.WgpuGl,
    center: Vec2,
    deg: f32,
    len: f32,
    thick: f32,
) void {
    const r: f32 = deg * rad_per_deg;
    const tip: Vec2 = .{ center[0] + cos(r) * len, center[1] + sin(r) * len };
    gl.line(center, tip, .{ .color = hands_col, .thickness = thick });
}

fn drawClocks(f: *z.Frame, s: *State, w: f32, h: f32) void {
    // native content box is ~[4..796] x [95..305]; fit + centre it
    const content_w: f32 = 800.0;
    const content_h: f32 = 210.0;
    const k: f32 = clamp(@min(w * 0.94 / content_w, h * 0.6 / content_h), 0.05, 2.0);
    const offx: f32 = w * 0.5 - 400.0 * k;
    const offy: f32 = h * 0.5 - 200.0 * k;

    const face: f32 = face_size * k;
    const thick: f32 = @max(face * 0.16, 1.5);

    var x_off: f32 = 4.0;
    for (0..6) |digit| {
        for (0..6) |row| {
            for (0..4) |col| {
                const nx: f32 = x_off + float(col) * (face_size + face_spacing) + face_size * 0.5;
                const ny: f32 = 100.0 + float(row) * (face_size + face_spacing) + face_size * 0.5;
                const center: Vec2 = .{ offx + nx * k, offy + ny * k };
                f.gl.circle(center, face * 0.5, .{ .color = ring_col, .outline = 1 });
                const cell: Vec2 = s.current[digit][row * 4 + col];
                drawHand(f.gl, center, cell[0], face * 0.5 + 4.0 * k, thick);
                drawHand(f.gl, center, cell[1], face * 0.5 + 2.0 * k, thick);
            }
        }
        x_off += (face_size + face_spacing) * 4.0;
        if (digit % 2 == 1) {
            const cx: f32 = offx + (x_off + 4.0) * k;
            f.gl.circle(.{ cx, offy + 160.0 * k }, 7.0 * k, .{ .color = hands_col, .segments = 16 });
            f.gl.circle(.{ cx, offy + 225.0 * k }, 7.0 * k, .{ .color = hands_col, .segments = 16 });
            x_off += section_spacing;
        }
    }
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - clock of clocks",
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
