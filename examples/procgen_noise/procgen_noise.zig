//! procgen_noise - port of the GL `procgen_noise`: three procedurally-
//! generated noise textures (white / Perlin / cellular), each made on the CPU
//! with the engine's `genImage*` (now in src/image.zig, GL-free), uploaded to
//! GPU textures, and drawn as panels via the rl-immediate textured-quad path
//! (`rlSetTexture` + `rlBegin(.triangles)` + `rlVertex2f`/`rlTexCoord2f`). A
//! fourth panel scrolls an animated Perlin field: regenerated each frame at a
//! time-varying offset, with its texture recreated each frame (the GL version
//! re-uploaded via updateTexture; until that lands on wgpu, recreate-and-free
//! is the equivalent). Note: the GL original generated this field but never
//! drew it - here we actually show it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;

const common = @import("example_common");
const c = z.colors;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const noise_w: i32 = 256;
const noise_h: i32 = 256;
const panel: f32 = 200;

const State = struct {
    font: z.Font,
    scratch: std.heap.ArenaAllocator,
    gpa: Allocator,
    tex_white: z.WgpuTexture,
    tex_perlin: z.WgpuTexture,
    tex_cellular: z.WgpuTexture,
    tex_anim: z.WgpuTexture,
    frame_count: usize = 0,
};

/// Free a genImage* Image's RGBA8 pixel buffer (allocated as `[]Color`).
fn freeImage(gpa: Allocator, img: z.Image) void {
    if (img.data) |d| {
        const n: usize = @as(usize, @intCast(img.width)) * @as(usize, @intCast(img.height));
        gpa.free(@as([*]Color, @ptrCast(@alignCast(d)))[0..n]);
    }
}

/// Generate an Image, upload it to a GPU texture, then free the CPU pixels.
fn upload(f: *z.Frame, img: z.Image, gpa: Allocator) z.WgpuTexture {
    const tex: z.WgpuTexture = z.loadTextureFromImage(f.gl, img);
    freeImage(gpa, img);
    return tex;
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24);
    var rng_state: z.rng.Seeded = z.rng.Seeded.init(0xCAFE_F00D);

    const white_img: z.Image = try z.genImageWhiteNoise(gpa, rng_state.rng(), noise_w, noise_h, 0.5);
    const perlin_img: z.Image = try z.genImagePerlinNoise(gpa, noise_w, noise_h, 0, 0, 6.0);
    const cellular_img: z.Image = try z.genImageCellular(gpa, noise_w, noise_h, 32);
    const anim_img: z.Image = try z.genImagePerlinNoise(gpa, noise_w, noise_h, 0, 0, 6.0);

    s.* = .{
        .font = font,
        .scratch = std.heap.ArenaAllocator.init(gpa),
        .gpa = gpa,
        .tex_white = upload(f, white_img, gpa),
        .tex_perlin = upload(f, perlin_img, gpa),
        .tex_cellular = upload(f, cellular_img, gpa),
        .tex_anim = upload(f, anim_img, gpa),
    };
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.tex_white.deinit();
    s.tex_perlin.deinit();
    s.tex_cellular.deinit();
    s.tex_anim.deinit();
    s.scratch.deinit();
}

/// Draw `tex` as a `wxh` quad at (x,y) via the rl-immediate textured path,
/// then a caption below it.
fn drawPanel(
    f: *z.Frame,
    font: z.Font,
    tex: z.WgpuTexture,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    label: []const u8,
) void {
    f.gl.rect(.{ .x = x - 4, .y = y - 4, .width = w + 8, .height = h + 28 }, .{ .color = c.slate_800 });
    z.rlSetTexture(f.gl, tex);
    z.rlBegin(f.gl, .triangles);
    z.rlColor4ub(f.gl, 255, 255, 255, 255);
    z.rlTexCoord2f(f.gl, 0, 0);
    z.rlVertex2f(f.gl, x, y);
    z.rlTexCoord2f(f.gl, 1, 0);
    z.rlVertex2f(f.gl, x + w, y);
    z.rlTexCoord2f(f.gl, 1, 1);
    z.rlVertex2f(f.gl, x + w, y + h);
    z.rlTexCoord2f(f.gl, 0, 0);
    z.rlVertex2f(f.gl, x, y);
    z.rlTexCoord2f(f.gl, 1, 1);
    z.rlVertex2f(f.gl, x + w, y + h);
    z.rlTexCoord2f(f.gl, 0, 1);
    z.rlVertex2f(f.gl, x, y + h);
    z.rlEnd(f.gl);
    z.rlSetTexture(f.gl, .{}); // reset to white so later shapes are solid
    f.gl.text(.{ x + 4, y + h + 6 }, label, .{ .size = 14, .color = c.sky_200, .font = &font });
}

fn update(f: *z.Frame, state: *State) void {
    _ = state.scratch.reset(.retain_capacity);
    state.frame_count += 1;
    const t: f32 = f.time.time;

    // Scroll the animated Perlin: regenerate at a time-varying offset and
    // re-upload IN PLACE via updateTexture (no per-frame texture churn).
    const offset: i32 = @trunc(t * 30.0);
    if (z.genImagePerlinNoise(state.gpa, noise_w, noise_h, offset, 0, 6.0)) |anim_img| {
        z.updateTexture(f.gl, state.tex_anim, anim_img);
        freeImage(state.gpa, anim_img);
    } else |_| {}

    z.clearViewport(f, common.palette.bg);

    const row_y: f32 = 48;
    const x0: f32 = 20;
    const gap: f32 = 16;
    drawPanel(f, state.font, state.tex_white, x0, row_y, panel, panel, "white noise");
    drawPanel(f, state.font, state.tex_perlin, x0 + (panel + gap), row_y, panel, panel, "Perlin");
    drawPanel(f, state.font, state.tex_cellular, x0 + 2 * (panel + gap), row_y, panel, panel, "cellular");

    // Animated scrolling Perlin, full-width below the row.
    const anim_w: f32 = f.window.widthf() - 40;
    drawPanel(f, state.font, state.tex_anim, x0, row_y + panel + 24, anim_w, 120, "animated Perlin (scrolling)");

    common.caption(f.gl, state.font, "genImage* on the CPU -> GPU textures; animated panel regenerates each frame");
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - procgen noise",
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
