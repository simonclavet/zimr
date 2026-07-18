//! recursive_hud — render once, composite as a nested tunnel. An animated scene (a
//! framed HUD: border, rotating sweep, orbiting dots) is rendered ONCE into a render
//! texture, then that single texture is drawn back to the screen as a stack of concentric,
//! progressively smaller + dimmer copies — a screen-inside-screen recursion. Pure
//! render-once-reuse: the scene is rasterized one time and composited N times.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const radFromDeg = zm.radFromDeg;
const Color = zm.Color;
const Vec2 = zm.Vec2;
const float = zm.float;

const roboto_mono_ttf = @embedFile("roboto_mono_ttf");
const c = Color;
const rt_w: f32 = 800;
const rt_h: f32 = 450;
const levels: usize = 6;

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
    s.* = .{ .font = try z.loadFont(f, gpa, roboto_mono_ttf, 24) };
}

/// The HUD scene, drawn in render-texture space [0,rt_w] x [0,rt_h].
fn drawScene(gl: anytype, t: f32) void {
    const cx: f32 = rt_w * 0.5;
    const cy: f32 = rt_h * 0.5;
    // border frame (4 thin bars) so each nested copy reads as a screen
    const m: f32 = rt_w * 0.03;
    const bt: f32 = 4.0;
    const frame_col: Color = c.init(70, 200, 230, 255);
    gl.rect(.{ .x = m, .y = m, .width = rt_w - 2.0 * m, .height = bt }, .{ .color = frame_col });
    gl.rect(.{ .x = m, .y = rt_h - m - bt, .width = rt_w - 2.0 * m, .height = bt }, .{ .color = frame_col });
    gl.rect(.{ .x = m, .y = m, .width = bt, .height = rt_h - 2.0 * m }, .{ .color = frame_col });
    gl.rect(.{ .x = rt_w - m - bt, .y = m, .width = bt, .height = rt_h - 2.0 * m }, .{ .color = frame_col });
    // rotating sweep bar
    const bw: f32 = rt_w * 0.4;
    const bar_col: Color = z.colorFromHSV(@mod(t * 50.0, 360.0), 0.7, 1.0);
    gl.rectRotated(
        .{ .x = cx, .y = cy, .width = bw, .height = 8 },
        .{ bw * 0.5, 4 },
        radFromDeg(t * 45.0),
        .{ .color = bar_col },
    );
    // three orbiting dots, 120 degrees apart
    var k: usize = 0;
    while (k < 3) : (k += 1) {
        const fk: f32 = float(k);
        const ang: f32 = t * 1.2 + fk * 2.094;
        const p: Vec2 = .{ cx + @cos(ang) * rt_h * 0.30, cy + @sin(ang) * rt_h * 0.30 };
        const dc: Color = z.colorFromHSV(@mod(fk * 120.0 + t * 30.0, 360.0), 0.8, 1.0);
        gl.circle(p, 10.0, .{ .color = dc, .segments = 16 });
    }
    gl.circle(.{ cx, cy }, 6.0, .{ .color = c.init(255, 255, 255, 255), .segments = 16 });
}

fn update(f: *z.Frame, s: *State) void {
    s.frame_count += 1;
    if (s.rt.color == .invalid) {
        s.rt = z.loadRenderTexture(f.gl, @trunc(rt_w), @trunc(rt_h));
    }
    const t: f32 = f.time.time;
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();

    // OFFSCREEN FIRST (tile-based-GPU safe; app owns begin/endDrawing).
    // Render the HUD scene exactly once into the render texture.
    z.beginTextureMode(f.gl, s.rt, c.init(12, 14, 24, 255));
    drawScene(f.gl, t);
    z.endTextureMode(f.gl);

    // SCREEN PASS: open once, clear, then composite.
    z.beginDrawing(f.gl);
    z.clearViewport(f, c.init(6, 6, 12, 255));

    // Composite it as a centered stack: full size, then ever smaller + dimmer copies.
    var sc: f32 = 1.0;
    var dimf: f32 = 255.0;
    var i: usize = 0;
    while (i < levels) : (i += 1) {
        const dw: f32 = w * sc;
        const dh: f32 = h * sc;
        const dx: f32 = (w - dw) * 0.5;
        const dy: f32 = (h - dh) * 0.5;
        const d: u8 = @trunc(dimf);
        f.gl.texture(
            .{ .x = dx, .y = dy, .width = dw, .height = dh },
            s.rt.asTexture(),
            .{ .tint = c.init(d, d, d, 255) },
        );
        sc *= 0.62;
        dimf *= 0.84;
    }

    f.gl.text(
        .{ 12, 12 },
        "recursive HUD: rendered once, nested 6x",
        .{ .size = 14, .color = c.init(210, 214, 224, 220), .font = &s.font },
    );
    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - recursive HUD",
            .width = 800,
            .height = 450,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
    // Offscreen render-texture drawn before the screen opens (tile-based-GPU
    // safe); owns its own begin/endDrawing.
    .manages_own_frame = true,
};
