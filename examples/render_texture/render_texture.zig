//! render_texture — render-to-texture demo for the new offscreen API. An animated
//! scene (spinning rectangles + a pulsing circle) is drawn INTO an offscreen render
//! texture via `beginTextureMode`/`endTextureMode`, then that ONE texture is composited
//! to the screen as a tinted grid with `drawTextureRec` — "render once, reuse many."
//! Exercises loadRenderTexture / texture-mode / asTexture. Viewport-relative.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const radFromDeg = zm.radFromDeg;
const Color = zm.Color;
const float = zm.float;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
const c = Color;
const rt_size: f32 = 256;
const cols: usize = 3;
const rows: usize = 2;

const State = struct {
    font: z.Font,
    rt: z.RenderTexture = .{},
    frame_count: usize = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.rt.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{ .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24) };
}

/// Draw the animated scene into the render texture (rt_size-pixel coordinates).
fn drawScene(
    gl: anytype,
    font: z.Font,
    t: f32,
) void {
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const fi: f32 = float(i);
        const sz: f32 = 130.0 - fi * 24.0;
        const rot: f32 = t * 40.0 + fi * 90.0;
        const col: Color = z.colorFromHSV(@mod(t * 30.0 + fi * 60.0, 360.0), 0.7, 0.95);
        gl.rectRotated(
            .{ .x = rt_size * 0.5, .y = rt_size * 0.5, .width = sz, .height = sz },
            .{ sz * 0.5, sz * 0.5 },
            radFromDeg(rot),
            .{ .color = col.fade(0.7) },
        );
    }
    gl.circle(
        .{ rt_size * 0.5, rt_size * 0.5 },
        26.0 + @sin(t * 2.0) * 12.0,
        .{ .color = c.init(245, 248, 252, 255), .segments = 16 },
    );
    gl.text(.{ 10, 8 }, "rt_size", .{ .size = 22, .color = c.init(200, 210, 230, 230), .font = &font });
}

fn update(f: *z.Frame, s: *State) void {
    s.frame_count += 1;
    if (s.rt.color == .invalid) {
        s.rt = z.loadRenderTexture(f.gl, @trunc(rt_size), @trunc(rt_size));
    }
    const t: f32 = f.time.time;
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();

    // 1. OFFSCREEN FIRST: render the scene into the texture BEFORE the screen
    // pass opens, so the swapchain is never torn down mid-frame (tile-based-GPU
    // safe). This app owns its own begin/endDrawing (see .manages_own_frame).
    z.beginTextureMode(f.gl, s.rt, c.init(20, 28, 48, 255));
    drawScene(f.gl, s.font, t);
    z.endTextureMode(f.gl);

    // 2. SCREEN PASS: open once, clear, composite the texture as a tinted grid.
    z.beginDrawing(f.gl);
    z.clearViewport(f, c.init(8, 9, 14, 255));
    const gap: f32 = 6.0;
    const cell_w: f32 = (w - gap * (cols + 1)) / @as(f32, cols);
    const cell_h: f32 = (h - gap * (rows + 1)) / @as(f32, rows);
    var ry: usize = 0;
    while (ry < rows) : (ry += 1) {
        var cx: usize = 0;
        while (cx < cols) : (cx += 1) {
            const idx: f32 = float(ry * cols + cx);
            const dx: f32 = gap + float(cx) * (cell_w + gap);
            const dy: f32 = gap + float(ry) * (cell_h + gap);
            const tint: Color = z.colorFromHSV(@mod(t * 20.0 + idx * 55.0, 360.0), 0.5, 1.0);
            f.gl.texture(.{ .x = dx, .y = dy, .width = cell_w, .height = cell_h }, s.rt.asTexture(), .{ .tint = tint });
        }
    }

    f.gl.text(
        .{ 10, 10 },
        "render texture: offscreen scene drawn 6x",
        .{ .size = 14, .color = c.init(210, 214, 224, 230), .font = &s.font },
    );
    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - render texture",
            .width = 800,
            .height = 450,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
    // Renders its offscreen texture before opening the screen (tile-based-GPU
    // safe); owns its own begin/endDrawing.
    .manages_own_frame = true,
};
