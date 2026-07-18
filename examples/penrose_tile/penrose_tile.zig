//! penrose_tile — a Penrose tiling grown from an L-system (Lindenmayer system) and drawn with
//! a turtle: the production string is expanded generation by generation from W/X/Y/Z rules, then
//! interpreted as turtle commands (F draws, +/- turn by 36 degrees, [ ] push/pop state). The tiling
//! reveals itself progressively, then tap to step to the next generation (raylib uses UP/DOWN).
//! From raylib shapes_penrose_tile.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const co = @import("example_common");

const sin = zm.sin;
const cos = zm.cos;
const float = zm.float;
const rad_per_deg = zm.rad_per_deg;
const Vec2 = zm.Vec2;
const Color = zm.Color;
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
const bufPrint = std.fmt.bufPrint;

const str_max = 16384;
const max_generations = 4;
const theta = 36.0;
const axiom = "[X]++[X]++[X]++[X]++[X]";
const rule_w = "YF++ZF4-XF[-YF4-WF]++";
const rule_x = "+YF--ZF[3-WF--XF]+";
const rule_y = "-WF++XF[+++YF++ZF]-";
const rule_z = "--YF++++WF[+ZF++++XF]--XF";

const line_col: Color = .{ .r = 120, .g = 205, .b = 235, .a = 70 };

const Turtle = struct {
    origin: Vec2,
    angle: f32,
};

const State = struct {
    font: z.Font,
    production: [str_max]u8 = undefined,
    prod_len: usize = 0,
    generations: i32 = 4,
    draw_length: f32 = 0,
    steps: usize = 0,
    press: Vec2 = .{ 0, 0 },
    dragged: bool = false,
};

fn ruleFor(ch: u8) ?[]const u8 {
    return switch (ch) {
        'W' => rule_w,
        'X' => rule_x,
        'Y' => rule_y,
        'Z' => rule_z,
        else => null,
    };
}

/// Expand the production once: each W/X/Y/Z becomes its rule; F is consumed; the
/// rest is copied through. Halves the segment length (deeper = finer).
fn buildStep(s: *State) void {
    var tmp: [str_max]u8 = undefined;
    var n: usize = 0;
    for (s.production[0..s.prod_len]) |ch| {
        if (ruleFor(ch)) |r| {
            const take: usize = @min(r.len, str_max - n);
            @memcpy(tmp[n .. n + take], r[0..take]);
            n += take;
        } else if (ch != 'F') {
            if (n < str_max) {
                tmp[n] = ch;
                n += 1;
            }
        }
    }
    s.draw_length *= 0.5;
    @memcpy(s.production[0..n], tmp[0..n]);
    s.prod_len = n;
}

fn rebuild(s: *State) void {
    @memcpy(s.production[0..axiom.len], axiom);
    s.prod_len = axiom.len;
    s.draw_length = 460.0 * (float(s.generations) / float(max_generations));
    var g: i32 = 0;
    while (g < s.generations) : (g += 1) {
        buildStep(s);
    }
    s.steps = 0;
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{ .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24) };
    rebuild(s);
}

fn drawPenrose(f: *z.Frame, s: *State) void {
    const center: Vec2 = .{ f.window.widthf() * 0.5, f.window.heightf() * 0.5 };
    var turtle: Turtle = .{ .origin = .{ 0, 0 }, .angle = -90.0 };
    var stack: [50]Turtle = undefined;
    var top: i32 = -1;
    var repeats: usize = 1;

    // progressive reveal: enough per frame to finish in ~3s regardless of length
    const reveal: usize = @max(12, s.prod_len / 180);
    s.steps = @min(s.steps + reveal, s.prod_len);

    for (s.production[0..s.steps]) |ch| {
        switch (ch) {
            'F' => {
                var j: usize = 0;
                while (j < repeats) : (j += 1) {
                    const start: Vec2 = turtle.origin;
                    const rad: f32 = turtle.angle * rad_per_deg;
                    turtle.origin = .{
                        turtle.origin[0] + s.draw_length * cos(rad),
                        turtle.origin[1] + s.draw_length * sin(rad),
                    };
                    const a: Vec2 = .{ start[0] + center[0], start[1] + center[1] };
                    const b: Vec2 = .{ turtle.origin[0] + center[0], turtle.origin[1] + center[1] };
                    f.gl.line(a, b, .{ .color = line_col, .thickness = 2.0 });
                }
                repeats = 1;
            },
            '+' => {
                turtle.angle += theta * float(repeats);
                repeats = 1;
            },
            '-' => {
                turtle.angle -= theta * float(repeats);
                repeats = 1;
            },
            '[' => {
                if (top < 49) {
                    top += 1;
                    stack[@intCast(top)] = turtle;
                }
            },
            ']' => {
                if (top >= 0) {
                    turtle = stack[@intCast(top)];
                    top -= 1;
                }
            },
            '0'...'9' => repeats = ch - '0',
            else => {},
        }
    }
}

fn update(f: *z.Frame, s: *State) void {
    z.clearViewport(f, co.palette.bg);

    // tap cycles generations 1..max (each rebuild re-animates the reveal)
    const down: bool = z.isMouseButtonDown(f.input, .left);
    const mouse: Vec2 = z.getMousePosition(f.input);
    if (z.isMouseButtonPressed(f.input, .left)) {
        s.press = mouse;
        s.dragged = false;
    }
    if (down and zm.distance(mouse, s.press) > 8.0) {
        s.dragged = true;
    }
    if (z.isMouseButtonReleased(f.input, .left) and !s.dragged) {
        s.generations += 1;
        if (s.generations > max_generations) {
            s.generations = 1;
        }
        rebuild(s);
    }

    drawPenrose(f, s);

    var buf: [48]u8 = undefined;
    const line: []const u8 = bufPrint(
        &buf,
        "penrose l-system - generation {d} (tap to advance)",
        .{s.generations},
    ) catch "";
    co.caption(f.gl, s.font, line);
    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - penrose tile",
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
