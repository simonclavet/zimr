//! lines_drawing - a persistent paint canvas. Drag to paint with a hue that cycles by
//! stroke speed; strokes accumulate into an offscreen render texture that is composited to
//! the screen each frame. Exercises the RTT accumulate path (beginTextureMode with no clear
//! = load) and pointer input. Desktop extras: right-drag erases, middle-click clears, wheel
//! sets thickness. From raylib shapes_lines_drawing; touch-paints on mobile.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const clamp = zm.clamp;
const distance = zm.distance;
const common = @import("example_common");

const Vec2 = zm.Vec2;
const Color = zm.Color;
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
const white: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };

const State = struct {
    font: z.Font,
    canvas: z.RenderTexture = .{},
    prev: Vec2 = .{ 0, 0 },
    thickness: f32 = 10.0,
    hue: f32 = 0.0,
    frame_count: usize = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.canvas.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{ .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24) };
}

fn update(f: *z.Frame, s: *State) void {
    s.frame_count += 1;
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    if (s.canvas.color == .invalid) {
        s.canvas = z.loadRenderTexture(f.gl, @trunc(w), @trunc(h));
    }
    const mouse: Vec2 = z.getMousePosition(f.input);

    // OFFSCREEN FIRST (tile-based-GPU safe; app owns begin/endDrawing).
    // Clear the canvas on the first frame, and on middle-click.
    if (s.frame_count == 1 or z.isMouseButtonPressed(f.input, .middle)) {
        z.beginTextureMode(f.gl, s.canvas, common.palette.bg);
        z.endTextureMode(f.gl);
    }

    const left_down: bool = z.isMouseButtonDown(f.input, .left);
    const right_down: bool = z.isMouseButtonDown(f.input, .right);
    const have_prev: bool = !(s.prev[0] == 0 and s.prev[1] == 0);

    if ((left_down or right_down) and have_prev) {
        var col: Color = common.palette.bg; // right-drag erases (paints the background)
        if (left_down) {
            s.hue = @mod(s.hue + distance(s.prev, mouse) / 3.0, 360.0);
            col = z.colorFromHSV(s.hue, 0.85, 1.0);
        }
        const r: f32 = s.thickness * 0.5;
        z.beginTextureMode(f.gl, s.canvas, null); // load = accumulate
        f.gl.circle(s.prev, r, .{ .color = col, .segments = 16 });
        f.gl.circle(mouse, r, .{ .color = col, .segments = 16 });
        f.gl.line(s.prev, mouse, .{ .color = col, .thickness = s.thickness });
        z.endTextureMode(f.gl);
    }

    s.thickness = clamp(s.thickness + z.getMouseWheelMove(f.input), 1.0, 200.0);
    s.prev = mouse;

    // SCREEN PASS: open once, clear, then composite.
    z.beginDrawing(f.gl);
    z.clearViewport(f, common.palette.bg);

    // Composite the canvas to the screen (RTs render upright - no flip).
    f.gl.texture(.{ .x = 0, .y = 0, .width = w, .height = h }, s.canvas.asTexture(), .{ .tint = white });

    if (!left_down) {
        f.gl.circle(mouse, s.thickness * 0.5, .{ .color = .{ .r = 160, .g = 160, .b = 170, .a = 140 }, .outline = 1 });
    }
    common.caption(f.gl, s.font, "lines drawing: drag to paint (hue cycles with speed)");
    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - lines drawing",
            .width = 800,
            .height = 450,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
    // Offscreen render-textures drawn before the screen opens (tile-based-GPU
    // safe); owns its own begin/endDrawing.
    .manages_own_frame = true,
};
