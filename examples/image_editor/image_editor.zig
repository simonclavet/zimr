//! image_editor — port of the GL `image_editor`: a tour of the CPU image
//! API now living in src/image.zig. A 32×32 PNG is decoded once
//! (`loadImageFromMemory`), then `imageCopy`'d four ways and edited —
//! `imageBlurGaussian`, `imageColorInvert`, `imageRotateCW` — each uploaded to
//! its own GPU texture (`loadTextureFromImage`). A fifth "live" panel keeps a
//! CPU buffer around, rewrites its pixels every frame (a brightness wave over a
//! diagonal gradient), and pushes them with `updateTexture` (in-place, no new
//! texture). Panels are drawn via the rl-immediate textured-quad path.
const std = @import("std");
const zm = @import("zm");
const float = zm.float;
const Allocator = std.mem.Allocator;
const z = @import("zimr");

const common = @import("example_common");
const c = z.colors;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
const smiley_png = @embedFile("smiley.png");

const panel_size: f32 = 128;
const panel_pad: f32 = 16;

const State = struct {
    font: z.Font,
    scratch: std.heap.ArenaAllocator,
    gpa: Allocator,
    tex_original: z.WgpuTexture,
    tex_blurred: z.WgpuTexture,
    tex_inverted: z.WgpuTexture,
    tex_rotated: z.WgpuTexture,
    live_tex: z.WgpuTexture,
    /// Kept on CPU so its bytes can be rewritten + re-uploaded each frame.
    live_image: z.Image,
    frame_count: usize = 0,
};

/// imageCopy the source, run `edit` on the copy, upload it, free the copy.
fn variant(
    f: *z.Frame,
    gpa: Allocator,
    source: z.Image,
    edit: *const fn (gpa: Allocator, img: *z.Image) anyerror!void,
) !z.WgpuTexture {
    var img: z.Image = try z.imageCopy(gpa, source);
    defer z.unloadImage(gpa, img);
    try edit(gpa, &img);
    return z.loadTextureFromImage(f.gl, img);
}

fn editBlur(gpa: Allocator, img: *z.Image) anyerror!void {
    try z.imageBlurGaussian(gpa, img, 4);
}
fn editInvert(gpa: Allocator, img: *z.Image) anyerror!void {
    _ = gpa;
    z.imageColorInvert(img);
}
fn editRotate(gpa: Allocator, img: *z.Image) anyerror!void {
    try z.imageRotateCW(gpa, img);
}
fn editNone(gpa: Allocator, img: *z.Image) anyerror!void {
    _ = gpa;
    _ = img;
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24);
    const source: z.Image = try z.loadImageFromMemory(gpa, smiley_png);
    defer z.unloadImage(gpa, source);

    s.* = .{
        .font = font,
        .scratch = std.heap.ArenaAllocator.init(gpa),
        .gpa = gpa,
        .tex_original = try variant(f, gpa, source, editNone),
        .tex_blurred = try variant(f, gpa, source, editBlur),
        .tex_inverted = try variant(f, gpa, source, editInvert),
        .tex_rotated = try variant(f, gpa, source, editRotate),
        // Live: keep its own CPU copy alive for per-frame re-upload.
        .live_image = try z.imageCopy(gpa, source),
        .live_tex = try variant(f, gpa, source, editNone),
    };
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.tex_original.deinit();
    s.tex_blurred.deinit();
    s.tex_inverted.deinit();
    s.tex_rotated.deinit();
    s.live_tex.deinit();
    z.unloadImage(gpa, s.live_image);
    s.scratch.deinit();
}

/// Draw `tex` as a `size×size` quad at (x,y) via rl-immediate, + a caption.
fn drawPanel(
    f: *z.Frame,
    font: z.Font,
    tex: z.WgpuTexture,
    x: f32,
    y: f32,
    size: f32,
    label: []const u8,
) void {
    f.gl.rect(.{ .x = x - 4, .y = y - 4, .width = size + 8, .height = size + 26 }, .{ .color = c.slate_800 });
    z.rlSetTexture(f.gl, tex);
    z.rlBegin(f.gl, .triangles);
    z.rlColor4ub(f.gl, 255, 255, 255, 255);
    z.rlTexCoord2f(f.gl, 0, 0);
    z.rlVertex2f(f.gl, x, y);
    z.rlTexCoord2f(f.gl, 1, 0);
    z.rlVertex2f(f.gl, x + size, y);
    z.rlTexCoord2f(f.gl, 1, 1);
    z.rlVertex2f(f.gl, x + size, y + size);
    z.rlTexCoord2f(f.gl, 0, 0);
    z.rlVertex2f(f.gl, x, y);
    z.rlTexCoord2f(f.gl, 1, 1);
    z.rlVertex2f(f.gl, x + size, y + size);
    z.rlTexCoord2f(f.gl, 0, 1);
    z.rlVertex2f(f.gl, x, y + size);
    z.rlEnd(f.gl);
    z.rlSetTexture(f.gl, .{});
    f.gl.text(.{ x, y + size + 6 }, label, .{ .size = 13, .color = c.sky_200, .font = &font });
}

fn update(f: *z.Frame, state: *State) void {
    _ = state.scratch.reset(.retain_capacity);
    state.frame_count += 1;
    const t: f32 = f.time.time;

    // Live panel: rewrite the CPU pixels (brightness wave over a diagonal
    // gradient) and re-upload in place with updateTexture — no new texture.
    if (state.live_image.data) |data| {
        const wave: f32 = 0.7 + 0.3 * @sin(t * 2.0);
        const w: usize = @intCast(state.live_image.width);
        const total: usize = w * @as(usize, @intCast(state.live_image.height));
        const pixels: [*]u8 = @ptrCast(data);
        var i: usize = 0;
        while (i < total) : (i += 1) {
            const x: f32 = float(i % w);
            const y: f32 = float(i / w);
            const r: f32 = (x / float(state.live_image.width)) * 255.0 * wave;
            const g: f32 = (y / float(state.live_image.height)) * 255.0 * wave;
            pixels[i * 4 + 0] = @trunc(@max(0.0, @min(255.0, r)));
            pixels[i * 4 + 1] = @trunc(@max(0.0, @min(255.0, g)));
            pixels[i * 4 + 2] = @trunc(@max(0.0, @min(255.0, 128.0 * wave)));
            pixels[i * 4 + 3] = 255;
        }
        z.updateTexture(f.gl, state.live_tex, state.live_image);
    }

    z.clearViewport(f, common.palette.bg);
    common.caption(f.gl, state.font, "image* CPU edits (blur/invert/rotate) + a live updateTexture pulse");

    // 2x2 grid of static variants.
    const x0: f32 = 32;
    const y0: f32 = 48;
    const step: f32 = panel_size + panel_pad + 14;
    drawPanel(f, state.font, state.tex_original, x0, y0, panel_size, "original");
    drawPanel(f, state.font, state.tex_blurred, x0 + panel_size + panel_pad, y0, panel_size, "blurred");
    drawPanel(f, state.font, state.tex_inverted, x0, y0 + step, panel_size, "inverted");
    drawPanel(f, state.font, state.tex_rotated, x0 + panel_size + panel_pad, y0 + step, panel_size, "rotated 90");

    // Live panel, larger, on the right.
    drawPanel(f, state.font, state.live_tex, 480, 70, 240, "live (updateTexture)");
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - image editor",
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
