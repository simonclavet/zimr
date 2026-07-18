//! rounded_rectangle — a rounded rectangle whose roundness, size, outline thickness and
//! corner-segment count all animate, cycling three render modes: filled rounded rect, rounded
//! outline, and a plain rectangle for contrast. Tap advances the mode (auto-advances too); a
//! panel reads back roundness / segments / MANUAL-AUTO. Ported from raylib
//! examples/shapes/shapes_rounded_rectangle_drawing.c, whose raygui sliders drove the same
//! parameters — animated here so the sample drives itself on a phone.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const co = @import("example_common");

const Color = zm.Color;
const bufPrint = std.fmt.bufPrint;
const roboto_mono_ttf = @embedFile("roboto_mono_ttf");

const mode_count: usize = 3;
const mode_names = [mode_count][]const u8{ "filled rounded", "rounded outline", "plain rect" };

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
    s.* = .{ .font = try z.loadFont(f, gpa, roboto_mono_ttf, 24) };
}

fn update(f: *z.Frame, s: *State) void {
    const dt: f32 = f.time.delta_time;
    s.time += dt;
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();

    z.clearViewport(f, co.palette.bg);
    co.backdrop(f.gl, w, h);

    if (z.isMouseButtonPressed(f.input, .left)) {
        s.mode = (s.mode + 1) % mode_count;
    }
    s.auto_timer += dt;
    if (s.auto_timer >= 4.0) {
        s.auto_timer = 0;
        s.mode = (s.mode + 1) % mode_count;
    }

    // Rectangle centred in the viewport, breathing in size.
    const base: f32 = @min(w, h);
    const rw: f32 = base * (0.5 + 0.08 * @sin(s.time * 0.7));
    const rh: f32 = base * (0.32 + 0.06 * @sin(s.time * 0.9 + 1.0));
    const rx: f32 = (w - rw) * 0.5;
    const ry: f32 = (h - rh) * 0.5;

    // Roundness sweeps 0→1 (sharp corners → full pill); segments and thickness animate too.
    const roundness: f32 = 0.5 + 0.5 * @sin(s.time * 0.5);
    const segments: i32 = @trunc(4.0 + 12.0 * (0.5 + 0.5 * @sin(s.time * 0.8)));
    const thick: f32 = 2.0 + 6.0 * (0.5 + 0.5 * @sin(s.time * 1.1));

    const fill: Color = .{ .r = 190, .g = 33, .b = 55, .a = 90 }; // MAROON, faded
    const line: Color = .{ .r = 235, .g = 100, .b = 120, .a = 235 };
    const gold: Color = .{ .r = 255, .g = 203, .b = 0, .a = 150 };

    switch (s.mode) {
        0 => f.gl.rectRoundedXYWH(rx, ry, rw, rh, roundness, @intCast(segments), .{ .color = fill }),
        1 => f.gl.rectRoundedLinesXYWH(rx, ry, rw, rh, roundness, segments, thick, .{ .color = line }),
        else => f.gl.rect(.{ .x = rx, .y = ry, .width = rw, .height = rh }, .{ .color = gold }),
    }

    // Read-out panel.
    const panel: Color = .{ .r = 20, .g = 24, .b = 34, .a = 200 };
    const border: Color = .{ .r = 90, .g = 200, .b = 230, .a = 180 };
    f.gl.rect(.{ .x = 10, .y = 40, .width = 272, .height = 96 }, .{ .color = panel });
    f.gl.rect(.{ .x = 10, .y = 40, .width = 272, .height = 96 }, .{ .color = border, .outline = 1.0 });

    var buf: [64]u8 = undefined;
    const mode_line: []const u8 = bufPrint(&buf, "mode: {s}", .{mode_names[s.mode]}) catch "mode: ?";
    f.gl.text(.{ 22, 52 }, mode_line, .{ .size = 14, .color = co.palette.accent, .font = &s.font });

    var buf2: [80]u8 = undefined;
    const manual: bool = segments >= 4;
    const par_line: []const u8 = bufPrint(
        &buf2,
        "roundness: {d:.2}  segs: {d} ({s})",
        .{ roundness, segments, if (manual) "MANUAL" else "AUTO" },
    ) catch "roundness: --";
    f.gl.text(.{ 22, 74 }, par_line, .{ .size = 13, .color = co.palette.ink, .font = &s.font });

    var buf3: [48]u8 = undefined;
    const thick_line: []const u8 = bufPrint(&buf3, "thickness: {d:.1}", .{thick}) catch "thickness: --";
    f.gl.text(.{ 22, 96 }, thick_line, .{ .size = 13, .color = co.palette.ink, .font = &s.font });
    f.gl.text(.{ 22, 116 }, "tap: cycle mode", .{ .size = 13, .color = co.palette.ink_dim, .font = &s.font });

    co.caption(f.gl, s.font, "rounded rectangle");
    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - rounded rectangle",
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
