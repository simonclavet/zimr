//! trails - render-texture ACCUMULATION. Several emitters trace Lissajous paths;
//! their glowing dots are drawn into a persistent render texture that is NOT cleared each
//! frame (beginTextureMode with clear = null -> load). A faint black rectangle is drawn over
//! the texture each frame to fade old trails, so the result is flowing ribbons of light.
//! Exercises the accumulate/load path of the render-texture API. Viewport-relative.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const Vec2 = zm.Vec2;
const float = zm.float;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
const c = Color;
const rt_w: f32 = 800;
const rt_h: f32 = 450;
const emitter_count: usize = 5;

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

/// One emitter's position at time t, tracing a Lissajous figure scaled to the texture.
fn emitterPos(i: usize, t: f32) Vec2 {
    const fi: f32 = float(i);
    const fx: f32 = 0.7 + fi * 0.17;
    const fy: f32 = 0.9 + fi * 0.13;
    return .{
        rt_w * 0.5 + rt_w * 0.42 * @sin(t * fx + fi * 1.7),
        rt_h * 0.5 + rt_h * 0.42 * @cos(t * fy + fi * 0.6),
    };
}

fn update(f: *z.Frame, s: *State) void {
    s.frame_count += 1;
    if (s.rt.color == .invalid) {
        s.rt = z.loadRenderTexture(f.gl, @trunc(rt_w), @trunc(rt_h));
    }
    const t: f32 = f.time.time;
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();

    // OFFSCREEN FIRST (tile-based-GPU safe; app owns its begin/endDrawing).
    // Accumulate into the texture: frame 1 clears to black, after that we LOAD (clear=null)
    // and fade, so trails persist and decay instead of resetting every frame.
    const clear: ?c = if (s.frame_count == 1) c.init(0, 0, 0, 255) else null;
    z.beginTextureMode(f.gl, s.rt, clear);
    if (s.frame_count > 1) {
        f.gl.rect(.{ .x = 0, .y = 0, .width = rt_w, .height = rt_h }, .{ .color = c.init(0, 0, 0, 16) }); // fade veil
    }
    var i: usize = 0;
    while (i < emitter_count) : (i += 1) {
        const p: Vec2 = emitterPos(i, t);
        const hue: f32 = @mod(float(i) * 67.0 + t * 12.0, 360.0);
        const col: Color = z.colorFromHSV(hue, 0.7, 1.0);
        f.gl.circle(p, 9.0, .{ .color = col.fade(0.25), .segments = 16 }); // glow
        f.gl.circle(p, 4.5, .{ .color = col, .segments = 16 }); // core
        f.gl.circle(p, 1.8, .{ .color = c.init(255, 255, 255, 255), .segments = 16 }); // hot center
    }
    z.endTextureMode(f.gl);

    // SCREEN PASS: open once, clear, then display the accumulated texture.
    z.beginDrawing(f.gl);
    z.clearViewport(f, c.init(6, 6, 10, 255));

    // Display the accumulated texture, stretched to fill the viewport.
    f.gl.texture(
        .{ .x = 0, .y = 0, .width = w, .height = h },
        s.rt.asTexture(),
        .{ .tint = c.init(255, 255, 255, 255) },
    );

    f.gl.text(
        .{ 12, 12 },
        "render texture trails: accumulate + fade",
        .{ .size = 14, .color = c.init(210, 214, 224, 220), .font = &s.font },
    );
    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - render texture trails",
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
