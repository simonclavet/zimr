//! srcrec_dstrec — the source-rectangle / destination-rectangle mapping. A 6-frame sprite sheet is
//! generated procedurally into an Image and uploaded once; drawTextureRec then maps ONE frame's
//! source sub-rect (normalised UVs frame/6 .. (frame+1)/6) onto a destination rectangle on screen,
//! scaling it to fit. The sheet is shown small up top with the active frame boxed. Tap to cycle the
//! source frame; drag the big sprite to move the destination. It rotates about its centre via the
//! new WgpuTexture drawTextureRotated. From raylib textures_srcrec_dstrec.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const co = @import("example_common");

const sin = zm.sin;
const cos = zm.cos;
const tau = zm.tau;
const distance = zm.distance;
const float = zm.float;
const radFromDeg = zm.radFromDeg;
const Vec2 = zm.Vec2;
const Color = zm.Color;
const roboto_mono_ttf = @embedFile("roboto_mono_ttf");
const bufPrint = std.fmt.bufPrint;

const frames: usize = 6;
const frame_w: usize = 96;
const frame_h: usize = 112;
const sheet_w: usize = frame_w * frames;
const sheet_h: usize = frame_h;

const white: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };

const State = struct {
    font: z.Font,
    img: z.Image,
    tex: z.WgpuTexture,
    selected: usize = 0,
    dst_center: Vec2 = .{ 400, 260 },
    t: f32 = 0,
    press: Vec2 = .{ 0, 0 },
    dragged: bool = false,
    placed: bool = false,
    gpa: Allocator,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    z.unloadImage(gpa, s.img);
    s.tex.deinit();
}

// ---- CPU rasterisers writing straight into the RGBA8 Image buffer ----
fn pset(px: [*]Color, x: i32, y: i32, c: Color) void {
    if (x < 0 or y < 0) {
        return;
    }
    const xu: usize = @intCast(x);
    const yu: usize = @intCast(y);
    if (xu >= sheet_w or yu >= sheet_h) {
        return;
    }
    px[yu * sheet_w + xu] = c;
}

fn fillRect(
    px: [*]Color,
    x0: i32,
    y0: i32,
    w: i32,
    h: i32,
    c: Color,
) void {
    var yy: i32 = 0;
    while (yy < h) : (yy += 1) {
        var xx: i32 = 0;
        while (xx < w) : (xx += 1) {
            pset(px, x0 + xx, y0 + yy, c);
        }
    }
}

fn fillCircle(
    px: [*]Color,
    cx: i32,
    cy: i32,
    r: i32,
    c: Color,
) void {
    var dy: i32 = -r;
    while (dy <= r) : (dy += 1) {
        var dx: i32 = -r;
        while (dx <= r) : (dx += 1) {
            if (dx * dx + dy * dy <= r * r) {
                pset(px, cx + dx, cy + dy, c);
            }
        }
    }
}

fn buildSheet(px: [*]Color) void {
    var fi: usize = 0;
    while (fi < frames) : (fi += 1) {
        const x0: i32 = @intCast(fi * frame_w);
        const cx: i32 = x0 + @as(i32, @intCast(frame_w / 2));
        const cy: i32 = @intCast(frame_h / 2);
        // a hue tile per frame so frames read distinctly in the sheet
        fillRect(px, x0, 0, @intCast(frame_w), @intCast(frame_h), z.colorFromHSV(float(fi) * 60.0, 0.45, 0.80));
        // a 6-dot spinner track; the active dot (== fi) is bright + large
        var j: usize = 0;
        while (j < frames) : (j += 1) {
            const ang: f32 = float(j) / float(frames) * tau;
            const offx: i32 = @round(cos(ang) * 30.0);
            const offy: i32 = @round(sin(ang) * 30.0);
            const ox: i32 = cx + offx;
            const oy: i32 = cy - offy;
            if (j == fi) {
                fillCircle(px, ox, oy, 11, white);
            } else {
                fillCircle(px, ox, oy, 5, .{ .r = 255, .g = 255, .b = 255, .a = 90 });
            }
        }
        fillCircle(px, cx, cy, 9, .{ .r = 30, .g = 30, .b = 40, .a = 255 });
    }
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const img: z.Image = try z.genImageColor(
        gpa,
        @intCast(sheet_w),
        @intCast(sheet_h),
        .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    );
    const px: [*]Color = @ptrCast(@alignCast(img.data.?));
    buildSheet(px);
    const tex: z.WgpuTexture = z.loadTextureFromImage(f.gl, img);
    s.* = .{
        .font = try z.loadFont(f, gpa, roboto_mono_ttf, 24),
        .img = img,
        .tex = tex,
        .gpa = gpa,
    };
}

fn update(f: *z.Frame, s: *State) void {
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    const gl = f.gl;
    s.t += f.time.delta_time;
    z.clearViewport(f, co.palette.bg);

    if (!s.placed) {
        s.dst_center = .{ w * 0.5, h * 0.56 };
        s.placed = true;
    }

    // --- input: drag moves the destination, tap cycles the source frame ---
    const m: Vec2 = z.getMousePosition(f.input);
    if (z.isMouseButtonPressed(f.input, .left)) {
        s.press = m;
        s.dragged = false;
    }
    if (z.isMouseButtonDown(f.input, .left) and distance(m, s.press) > 8.0) {
        s.dragged = true;
        s.dst_center = m;
    }
    if (z.isMouseButtonReleased(f.input, .left) and !s.dragged) {
        s.selected = (s.selected + 1) % frames;
    }

    // --- the big selected frame: source sub-rect -> destination rect, rotated about its centre ---
    const aspect: f32 = float(frame_w) / float(frame_h);
    const dh: f32 = @min(w, h) * 0.5;
    const dw: f32 = dh * aspect;
    const rotation_rad: f32 = radFromDeg(s.t * 40.0); // 40 deg/sec, converted to radians at the UI layer
    const source: z.Rectangle = .{
        .x = float(s.selected * frame_w),
        .y = 0,
        .width = float(frame_w),
        .height = float(frame_h),
    };
    const dest: z.Rectangle = .{
        .x = s.dst_center[0],
        .y = s.dst_center[1],
        .width = dw,
        .height = dh,
    };

    // crosshair through the destination centre (the rotation pivot)
    gl.line(.{ s.dst_center[0], 0 }, .{ s.dst_center[0], h }, .{ .color = co.palette.ink_dim, .thickness = 1.0 });
    gl.line(.{ 0, s.dst_center[1] }, .{ w, s.dst_center[1] }, .{ .color = co.palette.ink_dim, .thickness = 1.0 });

    gl.texture(dest, s.tex, .{
        .source = source,
        .origin = .{ dw * 0.5, dh * 0.5 },
        .rotation_rad = rotation_rad,
        .tint = white,
    });

    drawSheetStrip(f, s, w);

    var buf: [40]u8 = undefined;
    const label: []const u8 = bufPrint(
        &buf,
        "frame {d}/{d} - tap to cycle, drag to move",
        .{ s.selected + 1, frames },
    ) catch "";
    co.caption(gl, s.font, label);
    z.endDrawing(gl);
}

fn drawSheetStrip(f: *z.Frame, s: *State, w: f32) void {
    const gl = f.gl;
    const pad: f32 = 10.0;
    const tw: f32 = @min(w - 2.0 * pad, 360.0);
    const th: f32 = tw * float(sheet_h) / float(sheet_w);
    const tx: f32 = (w - tw) * 0.5;
    const ty: f32 = pad;
    gl.texture(.{ .x = tx, .y = ty, .width = tw, .height = th }, s.tex, .{ .tint = white });
    gl.rect(.{ .x = tx, .y = ty, .width = tw, .height = th }, .{ .color = co.palette.ink_dim, .outline = 1.0 });
    // box the active frame
    const fw: f32 = tw / float(frames);
    gl.rect(
        .{ .x = tx + float(s.selected) * fw, .y = ty, .width = fw, .height = th },
        .{ .color = co.palette.accent, .outline = 1.0 },
    );
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - srcrec dstrec",
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
