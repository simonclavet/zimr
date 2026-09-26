//! ring_drawing - a parametric ring (annulus). The swept angle sweeps open and closed
//! like a loading dial, the inner/outer radii breathe, and the demo cycles three render
//! modes: filled ring, ring outline, and circle-sector outline. Tap to advance the mode
//! (it also auto-advances). A panel reads back the live angle span and radii. Ported from
//! raylib examples/shapes/shapes_ring_drawing.c, whose raygui sliders drove the same
//! parameters; here they animate so the sample is self-driving on a phone.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const radFromDeg = zm.radFromDeg;
const common = @import("example_common");

const Vec2 = zm.Vec2;
const Color = zm.Color;
const bufPrint = std.fmt.bufPrint;
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const mode_count: usize = 3;
const mode_names = [mode_count][]const u8{ "filled ring", "ring outline", "sector outline" };

const State = struct {
    font: z.Font,
    time: f32 = 0,
    mode: usize = 0,
    auto_timer: f32 = 0,
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

    // Tap advances the render mode; it also auto-advances so an idle demo cycles.
    if (z.isMouseButtonPressed(f.input, .left)) {
        s.mode = (s.mode + 1) % mode_count;
    }
    s.auto_timer += dt;
    if (s.auto_timer >= 4.0) {
        s.auto_timer = 0;
        s.mode = (s.mode + 1) % mode_count;
    }

    const center: Vec2 = common.center(w, h);
    const base: f32 = @min(w, h);
    const outer: f32 = base * (0.34 + 0.03 * @sin(s.time * 0.9));
    const inner: f32 = base * (0.15 + 0.03 * @sin(s.time * 1.3 + 1.0));

    // Sweep the end angle open and closed (a loading-dial feel); the start rotates slowly.
    const start_angle: f32 = @mod(s.time * 24.0, 360.0);
    const span: f32 = 180.0 + 175.0 * @sin(s.time * 0.5);
    const end_angle: f32 = start_angle + span;
    const segments: i32 = @trunc(@max(16.0, @abs(span) / 4.0));

    const fill: Color = .{ .r = 190, .g = 33, .b = 55, .a = 110 }; // raylib MAROON, faded
    const line: Color = .{ .r = 230, .g = 235, .b = 245, .a = 220 };

    const sa: f32 = radFromDeg(start_angle);
    const ea: f32 = radFromDeg(end_angle);
    switch (s.mode) {
        0 => f.gl.ring(center, inner, outer, sa, ea, segments, .{ .color = fill }),
        1 => f.gl.ringLines(center, inner, outer, sa, ea, segments, .{ .color = line }),
        else => f.gl.circleSectorLines(center, outer, sa, ea, segments, .{ .color = line }),
    }

    // Read-out panel (mode + live parameters).
    const panel: Color = .{ .r = 20, .g = 24, .b = 34, .a = 200 };
    const border: Color = .{ .r = 90, .g = 200, .b = 230, .a = 180 };
    f.gl.rect(.{ .x = 10, .y = 40, .width = 268, .height = 96 }, .{ .color = panel });
    f.gl.rect(.{ .x = 10, .y = 40, .width = 268, .height = 96 }, .{ .color = border, .outline = 1.0 });

    var buf: [64]u8 = undefined;
    const mode_line: []const u8 = bufPrint(&buf, "mode: {s}", .{mode_names[s.mode]}) catch "mode: ?";
    f.gl.text(.{ 22, 52 }, mode_line, .{ .size = 14, .color = common.palette.accent, .font = &s.font });

    var buf2: [80]u8 = undefined;
    const ang_line: []const u8 = bufPrint(
        &buf2,
        "span: {d:.0} deg  segs: {d}",
        .{ span, segments },
    ) catch "span: --";
    f.gl.text(.{ 22, 74 }, ang_line, .{ .size = 13, .color = common.palette.ink, .font = &s.font });

    var buf3: [80]u8 = undefined;
    const rad_line: []const u8 = bufPrint(
        &buf3,
        "inner: {d:.0}  outer: {d:.0}",
        .{ inner, outer },
    ) catch "inner: --";
    f.gl.text(.{ 22, 94 }, rad_line, .{ .size = 13, .color = common.palette.ink, .font = &s.font });
    f.gl.text(.{ 22, 114 }, "tap: cycle mode", .{ .size = 13, .color = common.palette.ink_dim, .font = &s.font });

    common.caption(f.gl, s.font, "ring drawing");
    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - ring drawing",
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
