// examples/smooth_pixelperfect.zig - pixel-art rendered at a virtual resolution
// and scaled up, with SMOOTH sub-pixel scrolling.
// Ports raylib's core `smooth_pixelperfect`: the world is drawn into a low-res
// render texture (320x180) so it stays crisp when scaled 2.5x to the 800x450
// window; the camera position is split into an INTEGER part (offsets the scene
// inside the RT, keeping every edge on a virtual pixel = pixel-perfect) and a
// FRACTIONAL part (shifts the whole scaled RT by sub-pixel screen amounts =
// smooth). raylib does the split with two Camera2Ds; here it's done directly.
//
// What this exercises (RTT engine coverage):
//   - `z.loadRenderTexture` + `z.beginTextureMode`/`endTextureMode`, drawing 2D
//     SHAPES into an offscreen target, then compositing `rt.asTexture()` to the
//     screen with a sub-pixel dest offset.
//
// Leak-clean (`.memory = .managed`): the RT is freed in `deinit`; the font atlas
// is engine-owned (freed by resetRegistry).

const std = @import("std");
const Allocator = std.mem.Allocator;

const z = @import("zimr");
const zm = @import("zm");

const roboto_mono_ttf = @embedFile("roboto_mono_ttf");

const Color = zm.Color;
const c = Color;
const float = zm.float;

const screen_w: i32 = 800;
const screen_h: i32 = 450;
const virt_w: i32 = 320;
const virt_h: i32 = 180;
const scale: f32 = 2.5; // 320*2.5 = 800, 180*2.5 = 450
// The RT is 1px larger than the virtual view on each side so the sub-pixel dest
// shift never reveals an uncovered edge.
const rt_w: i32 = virt_w + 2;
const rt_h: i32 = virt_h + 2;

const State = struct {
    rt: z.RenderTexture,
    font: z.Font,
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    // nearest_filter = true: point sampling keeps the low-res target CRISP when
    // scaled up (the whole point of pixel-perfect).
    const rt: z.RenderTexture = z.loadRenderTextureEx(f.gl, rt_w, rt_h, true);
    const font: z.Font = try z.loadFont(f, gpa, roboto_mono_ttf, 20);
    s.* = .{ .rt = rt, .font = font };
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.rt.deinit();
}

/// A chunky pixel-art scene in the RT's own (virtual) coordinate space, offset
/// by `off` (the integer camera part + 1px RT padding). World spans wider than
/// the view so the panning camera has something to reveal.
fn drawScene(gl: *z.WgpuGl, off_x: f32, off_y: f32) void {
    // Sky is the RT clear. Rolling ground (a wide band + a lighter top edge).
    const grass: Color = .{ .r = 70, .g = 140, .b = 70, .a = 255 };
    const grass_top: Color = .{ .r = 110, .g = 190, .b = 110, .a = 255 };
    gl.rect(.{ .x = -400 + off_x, .y = 130 + off_y, .width = 1200, .height = 100 }, .{ .color = grass });
    gl.rect(.{ .x = -400 + off_x, .y = 130 + off_y, .width = 1200, .height = 6 }, .{ .color = grass_top });

    // A row of blocks (buildings) at fixed world x's, distinct colors.
    const cols: [5]Color = .{
        .{ .r = 200, .g = 80, .b = 80, .a = 255 },
        .{ .r = 80, .g = 110, .b = 210, .a = 255 },
        .{ .r = 210, .g = 170, .b = 60, .a = 255 },
        .{ .r = 150, .g = 90, .b = 200, .a = 255 },
        .{ .r = 60, .g = 180, .b = 180, .a = 255 },
    };
    const window_col: Color = .{ .r = 250, .g = 250, .b = 210, .a = 255 };
    var i: usize = 0;
    while (i < cols.len) : (i += 1) {
        const bx: f32 = -140 + float(i) * 90;
        const bh: f32 = 40 + float(i % 3) * 26;
        gl.rect(.{ .x = bx + off_x, .y = 130 - bh + off_y, .width = 46, .height = bh }, .{ .color = cols[i] });
        // a bright window pixel so scaling shows crisp edges
        gl.rect(.{ .x = bx + 8 + off_x, .y = 130 - bh + 8 + off_y, .width = 8, .height = 8 }, .{ .color = window_col });
    }

    // Sun near the sky.
    gl.circle(.{ 40 + off_x, 34 + off_y }, 14, .{ .color = .{ .r = 250, .g = 220, .b = 90, .a = 255 } });
}

fn update(f: *z.Frame, s: *State) void {
    const t: f32 = f.time.time;
    // Camera pans in a slow circle (virtual pixels).
    const cam_x: f32 = @sin(t * 0.5) * 90.0;
    const cam_y: f32 = @cos(t * 0.35) * 20.0;
    const cam_floor_x: f32 = @floor(cam_x);
    const cam_floor_y: f32 = @floor(cam_y);
    const frac_x: f32 = cam_x - cam_floor_x;
    const frac_y: f32 = cam_y - cam_floor_y;

    // --- render the world into the low-res RT, offset by the INTEGER camera ---
    // (+1 = the RT's padding pixel). Everything lands on a virtual-pixel grid.
    z.beginTextureMode(f.gl, s.rt, .{ .r = 120, .g = 180, .b = 235, .a = 255 });
    drawScene(f.gl, -cam_floor_x + 1.0, -cam_floor_y + 1.0);
    z.endTextureMode(f.gl);

    // --- composite: draw the whole RT scaled up, shifted by the FRACTIONAL ---
    // camera (in screen px). Nearest sampling keeps each virtual pixel a crisp
    // scale x scale block while the sub-pixel dest shift makes motion smooth.
    z.clearViewport(f, c.black);
    const dest: z.Rectangle = .{
        .x = -(frac_x + 1.0) * scale,
        .y = -(frac_y + 1.0) * scale,
        .width = float(rt_w) * scale,
        .height = float(rt_h) * scale,
    };
    f.gl.texture(dest, s.rt.asTexture(), .{});

    f.gl.text(
        .{ 16, 16 },
        "320x180 render texture scaled 2.5x - crisp pixels, smooth sub-pixel scroll",
        .{ .size = 18, .color = c.raywhite, .font = &s.font },
    );

    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - core - smooth pixel-perfect",
            .width = screen_w,
            .height = screen_h,
            .scale_mode = .fit,
            .clear = .{ .r = 0, .g = 0, .b = 0, .a = 1.0 },
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
    .memory = .managed,
};
