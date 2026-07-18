// examples/shapes_top_down_lights.zig - 2D top-down lighting with hard shadows.
// Ports raylib's `shapes_top_down_lights` (its 4/4-complexity shapes sample).
//
// The technique, and why it needs a render texture per light:
//   1. For each light, render a LIGHT MASK offscreen: a radial gradient (bright
//      at the light, black at its outer radius) minus the SHADOW VOLUMES cast by
//      every box between the light and the world.
//   2. Additively ACCUMULATE those masks into one lightmap. Additive is what
//      makes two lights brighten each other instead of overwriting — and it's why
//      each light needs its own mask pass: a shadow belongs to ONE light, so it
//      must be cut before that light joins the sum.
//   3. Draw the scene, then MULTIPLY it by the lightmap. Lit -> unchanged;
//      shadowed (lightmap black) -> black.
//
// A shadow volume is just the box edge, extended away from the light. Only edges
// FACING AWAY from the light cast one: for an axis-aligned box that reduces to
// four cheap comparisons (e.g. the top edge casts only when the light is below
// it), which is the whole trick that keeps this O(boxes) instead of a raycast.
//
// Engine surface exercised: `beginTextureMode(gl, rt, null)` — the null clear is
// a LOAD, which is what lets the accumulator survive across per-light passes —
// plus `beginBlendMode(.additive/.multiply)`, `gl.circleGradient`, and
// `gl.triangleFan`.
//
// Leak-clean (`.memory = .managed`): both render textures are freed in `deinit`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const z = @import("zimr");
const zm = @import("zm");

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const Color = zm.Color;
const c = Color;
const Vec2 = zm.Vec2;
const float = zm.float;
const normalize = zm.normalize;
const bufPrint = std.fmt.bufPrint;

const max_boxes: usize = 6;
const max_lights: usize = 3;
/// 4 edges per box, and a box can only ever have 2 facing away — but bound for
/// the worst case so the buffer can never overflow.
const max_shadows: usize = max_boxes * 4;

const Light = struct {
    pos: Vec2,
    radius: f32,
    color: Color,
    on: bool = true,
};

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,
    mask: z.RenderTexture, // scratch: ONE light's contribution
    accum: z.RenderTexture, // the summed lightmap
    rt_w: i32,
    rt_h: i32,
    boxes: [max_boxes]z.Rectangle = undefined,
    box_count: usize = 0,
    lights: [max_lights]Light = undefined,
    light_count: usize = 0,
    show_volumes: bool = false,
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const ui_font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24);
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 16);

    // Masks are full-canvas. Sized from the live window: the lightmap is
    // composited 1:1 over the screen, so any mismatch would misalign it.
    const w: i32 = @trunc(f.window.widthf());
    const h: i32 = @trunc(f.window.heightf());

    s.* = .{
        .ui_host = z.UiHost.init(gpa, ui_font),
        .font = font,
        .mask = z.loadRenderTexture(f.gl, w, h),
        .accum = z.loadRenderTexture(f.gl, w, h),
        .rt_w = w,
        .rt_h = h,
    };

    const fw: f32 = f.window.widthf();
    const fh: f32 = f.window.heightf();
    s.boxes[0] = .{ .x = fw * 0.12, .y = fh * 0.42, .width = 70, .height = 70 };
    s.boxes[1] = .{ .x = fw * 0.58, .y = fh * 0.38, .width = 90, .height = 50 };
    s.boxes[2] = .{ .x = fw * 0.30, .y = fh * 0.68, .width = 60, .height = 90 };
    s.boxes[3] = .{ .x = fw * 0.70, .y = fh * 0.74, .width = 80, .height = 60 };
    s.box_count = 4;

    // Light 0 follows the finger; the others are fixed so their shadows can be
    // compared against the moving one.
    const warm: Color = .{ .r = 255, .g = 236, .b = 190, .a = 255 };
    const cool: Color = .{ .r = 120, .g = 190, .b = 255, .a = 255 };
    const rose: Color = .{ .r = 255, .g = 130, .b = 150, .a = 255 };
    s.lights[0] = .{ .pos = .{ fw * 0.5, fh * 0.30 }, .radius = 320, .color = warm };
    s.lights[1] = .{ .pos = .{ fw * 0.15, fh * 0.90 }, .radius = 240, .color = cool };
    s.lights[2] = .{ .pos = .{ fw * 0.88, fh * 0.60 }, .radius = 220, .color = rose };
    s.light_count = 3;
}

fn deinit(gpa: Allocator, s: *State) void {
    _ = gpa;
    s.mask.deinit();
    s.accum.deinit();
    s.ui_host.deinit();
}

/// Extend an edge away from the light to form the shadow quad. `sp`/`ep` are the
/// edge endpoints; each is pushed outward along its own ray from the light, so
/// the volume diverges exactly like the real penumbra-free shadow would.
fn shadowQuad(light: Vec2, sp: Vec2, ep: Vec2, extend: f32) [4]Vec2 {
    const sv: Vec2 = normalize(sp - light);
    const ev: Vec2 = normalize(ep - light);
    return .{
        sp,
        ep,
        ep + ev * @as(Vec2, @splat(extend)),
        sp + sv * @as(Vec2, @splat(extend)),
    };
}

/// Collect the shadow volumes a box casts from `light`. Only edges facing AWAY
/// from the light cast: for an axis-aligned box that's four comparisons, no
/// normals or dot products needed.
fn boxShadows(
    light: Vec2,
    b: z.Rectangle,
    extend: f32,
    out: *[max_shadows][4]Vec2,
    n: *usize,
) void {
    const x0: f32 = b.x;
    const y0: f32 = b.y;
    const x1: f32 = b.x + b.width;
    const y1: f32 = b.y + b.height;

    // A light INSIDE the box would make every edge face away and flood the
    // screen with shadow — skip it, as raylib does.
    if (light[0] > x0 and light[0] < x1 and light[1] > y0 and light[1] < y1) {
        return;
    }

    if (light[1] > y0 and n.* < max_shadows) { // light below the top edge
        out[n.*] = shadowQuad(light, .{ x0, y0 }, .{ x1, y0 }, extend);
        n.* += 1;
    }
    if (light[1] < y1 and n.* < max_shadows) { // light above the bottom edge
        out[n.*] = shadowQuad(light, .{ x1, y1 }, .{ x0, y1 }, extend);
        n.* += 1;
    }
    if (light[0] > x0 and n.* < max_shadows) { // light right of the left edge
        out[n.*] = shadowQuad(light, .{ x0, y1 }, .{ x0, y0 }, extend);
        n.* += 1;
    }
    if (light[0] < x1 and n.* < max_shadows) { // light left of the right edge
        out[n.*] = shadowQuad(light, .{ x1, y0 }, .{ x1, y1 }, extend);
        n.* += 1;
    }
}

fn update(f: *z.Frame, s: *State) void {
    const fw: f32 = f.window.widthf();
    const fh: f32 = f.window.heightf();
    const full: z.Rectangle = .{ .x = 0, .y = 0, .width = float(s.rt_w), .height = float(s.rt_h) };

    const u: z.ui_real.Ui = s.ui_host.begin(f);

    // Light 0 tracks the finger (but not while it's on the panel).
    if (!u.wantCaptureMouse()) {
        s.lights[0].pos = z.getMousePosition(f.input);
    }

    // ---- 1. clear the accumulator ------------------------------------------
    z.beginTextureMode(f.gl, s.accum, c.black);
    z.endTextureMode(f.gl);

    // ---- 2. one masked pass per light, summed into the accumulator ----------
    var shadows: [max_shadows][4]Vec2 = undefined;
    for (0..s.light_count) |i| {
        const lt: Light = s.lights[i];
        if (!lt.on) {
            continue;
        }

        var n: usize = 0;
        for (0..s.box_count) |bi| {
            boxShadows(lt.pos, s.boxes[bi], lt.radius * 2.0, &shadows, &n);
        }

        z.beginTextureMode(f.gl, s.mask, c.black);
        // Radial falloff: the light's color at the centre, black at the rim.
        f.gl.circleGradient(lt.pos, lt.radius, lt.color, c.black);
        // Cut the shadows out of THIS light before it joins the sum.
        for (0..n) |k| {
            f.gl.triangleFan(&shadows[k], .{ .color = c.black });
        }
        z.endTextureMode(f.gl);

        // null clear = LOAD: keep what previous lights already contributed.
        z.beginTextureMode(f.gl, s.accum, null);
        z.beginBlendMode(f.gl, .additive);
        f.gl.texture(full, s.mask.asTexture(), .{});
        z.endBlendMode(f.gl);
        z.endTextureMode(f.gl);
    }

    // ---- 3. scene, then multiply it by the lightmap -------------------------
    z.clearViewport(f, .{ .r = 30, .g = 32, .b = 40, .a = 255 });

    // Floor grid, so the shadow edges have something to fall across.
    var gx: f32 = 0;
    while (gx < fw) : (gx += 40) {
        f.gl.line(.{ gx, 0 }, .{ gx, fh }, .{ .color = .{ .r = 44, .g = 47, .b = 58, .a = 255 } });
    }
    var gy: f32 = 0;
    while (gy < fh) : (gy += 40) {
        f.gl.line(.{ 0, gy }, .{ fw, gy }, .{ .color = .{ .r = 44, .g = 47, .b = 58, .a = 255 } });
    }
    for (0..s.box_count) |bi| {
        f.gl.rect(s.boxes[bi], .{ .color = .{ .r = 150, .g = 155, .b = 170, .a = 255 } });
        f.gl.rect(s.boxes[bi], .{ .color = .{ .r = 90, .g = 95, .b = 110, .a = 255 }, .outline = 2 });
    }

    z.beginBlendMode(f.gl, .multiply);
    f.gl.texture(full, s.accum.asTexture(), .{});
    z.endBlendMode(f.gl);

    // Optional: the raw shadow geometry for the moving light, drawn UNLIT on top
    // so the volumes that produced the darkness are visible as outlines.
    if (s.show_volumes) {
        var n: usize = 0;
        for (0..s.box_count) |bi| {
            boxShadows(s.lights[0].pos, s.boxes[bi], s.lights[0].radius * 2.0, &shadows, &n);
        }
        for (0..n) |k| {
            const q: [4]Vec2 = shadows[k];
            f.gl.line(q[0], q[3], .{ .color = c.lime, .thickness = 1 });
            f.gl.line(q[1], q[2], .{ .color = c.lime, .thickness = 1 });
        }
    }

    u.setNextWindowPos(.{ 8, 8 }, .{});
    u.setNextWindowSize(.{ fw - 16.0, 210 }, .{});
    if (u.window("Top-down lights", .{})) |w| {
        defer w.close();
        u.text("Drag: move the warm light.", .{});
        u.separator();
        for (0..s.light_count) |i| {
            var buf: [24]u8 = undefined;
            const lbl: []const u8 = bufPrint(&buf, "light {d}", .{i}) catch "light";
            if (u.button(lbl, .{})) {
                s.lights[i].on = !s.lights[i].on;
            }
            if (i + 1 < s.light_count) {
                u.sameLine(.{});
            }
        }
        if (u.button(if (s.show_volumes) "Volumes: ON" else "Volumes: OFF", .{})) {
            s.show_volumes = !s.show_volumes;
        }
        _ = u.slider("radius", &s.lights[0].radius, .{ .min = 120, .max = 500 });
    }

    s.ui_host.render(f);
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - shapes - top-down lights",
            .width = 800,
            .height = 450,
            .scale_mode = .responsive,
            .depth_format = null,
            .clear = .{ .r = 0, .g = 0, .b = 0, .a = 1.0 },
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
    .memory = .managed,
};
