//! vector_angle - the angle between 2D vectors; v2 follows the pointer (mouse/touch),
//! the mode cycles every five seconds. MODE 0: the signed angle at v0 between a fixed
//! reference v0->v1 and v0->v2. MODE 1: the angle of v0->v2 vs the horizontal axis. All the
//! vector math is zimrmath - native `-` for difference, zm.angle2 for the signed between-
//! angle, zm.lineAngle2 for a ray's angle - no hand-rolled helpers. From raylib's vector_angle.
const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const radFromDeg = zm.radFromDeg;
const angle2 = zm.angle2;
const lineAngle2 = zm.lineAngle2;
const degFromRad = zm.degFromRad;
const common = @import("example_common");

const Vec2 = zm.Vec2;
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const State = struct {
    font: z.Font,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{ .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24) };
}

fn update(f: *z.Frame, s: *State) void {
    const t: f32 = f.time.time;
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    const r: f32 = @min(w, h) * 0.34;
    const v0: Vec2 = .{ w * 0.5, h * 0.5 };
    const v2: Vec2 = z.getMousePosition(f.input);
    const mode: u8 = if (@mod(t, 10.0) < 5.0) 0 else 1;

    const v1: Vec2 = if (mode == 0)
        .{ v0[0] + r * 0.7, v0[1] - r * 0.7 }
    else
        .{ v0[0] + r, v0[1] };

    // zm.angle2 is the shortest signed sweep; zm.lineAngle2 is a ray's screen angle.
    const d1: Vec2 = v1 - v0;
    const d2: Vec2 = v2 - v0;
    const angle: f32 = if (mode == 0) degFromRad(angle2(d1, d2)) else degFromRad(lineAngle2(v0, v2));
    const wedge_start: f32 = if (mode == 0) degFromRad(lineAngle2(v0, v1)) else 0.0;
    const wr: f32 = r * 0.32;

    z.clearViewport(f, common.palette.bg);
    common.backdrop(f.gl, w, h);

    const ws_rad: f32 = radFromDeg(wedge_start);
    const we_rad: f32 = radFromDeg(wedge_start + angle);
    f.gl.circleSector(v0, wr, ws_rad, we_rad, 48, .{ .color = common.palette.good.fade(0.5) });
    if (mode == 1) {
        f.gl.line(.{ 0, v0[1] }, .{ w, v0[1] }, .{ .color = common.palette.ink_dim, .thickness = 1.0 });
    } else {
        f.gl.line(v0, v1, .{ .color = common.palette.ink, .thickness = 3.0 });
        f.gl.text(.{ v1[0] + 6, v1[1] - 6 }, "v1", .{ .size = 14, .color = common.palette.ink_dim, .font = &s.font });
    }
    f.gl.line(v0, v2, .{ .color = common.palette.accent2, .thickness = 3.0 });
    f.gl.circle(v0, 5.0, .{ .color = common.palette.ink, .segments = 16 });
    f.gl.text(.{ v2[0] + 6, v2[1] - 6 }, "v2", .{ .size = 14, .color = common.palette.ink_dim, .font = &s.font });

    var buf: [56]u8 = undefined;
    const msg: []const u8 = bufPrint(&buf, "vector angle - MODE {d} - {d:.1} deg", .{ mode, angle }) catch
        "vector angle";
    common.caption(f.gl, s.font, msg);
    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - vector angle",
            .width = 800,
            .height = 450,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
