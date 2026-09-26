//! following_eyes - two googly eyes whose irises track the pointer, each clamped to stay
//! inside its sclera (atan2 + a radius clamp, straight from the raylib original). On a phone there
//! is no hover, so when nothing is touching the screen the eyes wander on their own along a slow
//! Lissajous path; touch and they snap to your finger. From raylib shapes_following_eyes.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const common = @import("example_common");

const sinRad = zm.sinRad;
const cosRad = zm.cosRad;
const atan2Rad = zm.atan2Rad;
const Vec2 = zm.Vec2;
const Color = zm.Color;
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const sclera_col: Color = .{ .r = 228, .g = 231, .b = 238, .a = 255 };
const iris_left_col: Color = .{ .r = 138, .g = 102, .b = 66, .a = 255 }; // brown
const iris_right_col: Color = .{ .r = 60, .g = 150, .b = 92, .a = 255 }; // green
const pupil_col: Color = .{ .r = 16, .g = 18, .b = 24, .a = 255 };
const glint_col: Color = .{ .r = 255, .g = 255, .b = 255, .a = 235 };

const State = struct {
    font: z.Font,
    t: f32 = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{ .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24) };
}

/// Iris centre for a sclera at `c`: the pointer, clamped to within (sclera - iris) of the centre.
fn irisPos(c: Vec2, max_d: f32, target: Vec2) Vec2 {
    const dx: f32 = target[0] - c[0];
    const dy: f32 = target[1] - c[1];
    if (dx * dx + dy * dy <= max_d * max_d) {
        return target;
    }
    const a: f32 = atan2Rad(dy, dx);
    return .{ c[0] + max_d * cosRad(a), c[1] + max_d * sinRad(a) };
}

fn drawEye(
    f: *z.Frame,
    c: Vec2,
    sr: f32,
    ir: f32,
    iris_col: Color,
    target: Vec2,
) void {
    const iris: Vec2 = irisPos(c, sr - ir, target);
    f.gl.circle(c, sr, .{ .color = sclera_col, .segments = 16 });
    f.gl.circle(iris, ir, .{ .color = iris_col, .segments = 16 });
    f.gl.circle(iris, ir * 0.42, .{ .color = pupil_col, .segments = 16 });
    // a little glint, offset up-left, sells the "alive" look
    const glint: Vec2 = .{ iris[0] - ir * 0.3, iris[1] - ir * 0.3 };
    f.gl.circle(glint, ir * 0.16, .{ .color = glint_col, .segments = 16 });
}

fn update(f: *z.Frame, s: *State) void {
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    z.clearViewport(f, common.palette.bg);
    s.t += 0.016;

    const sr: f32 = @min(w, h) * 0.18;
    const ir: f32 = sr * 0.3;
    const spacing: f32 = sr * 1.35;
    const cx: f32 = w * 0.5;
    const cy: f32 = h * 0.5;
    const left_c: Vec2 = .{ cx - spacing, cy };
    const right_c: Vec2 = .{ cx + spacing, cy };

    // pointer drives the gaze; otherwise the eyes wander a slow Lissajous
    const down: bool = z.isMouseButtonDown(f.input, .left);
    const target: Vec2 = if (down)
        z.getMousePosition(f.input)
    else
        .{ cx + cosRad(s.t * 0.9) * w * 0.36, cy + sinRad(s.t * 1.7) * h * 0.34 };

    drawEye(f, left_c, sr, ir, iris_left_col, target);
    drawEye(f, right_c, sr, ir, iris_right_col, target);

    common.caption(f.gl, s.font, "following eyes: move your finger - the eyes follow (and wander when idle)");
    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - following eyes",
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
