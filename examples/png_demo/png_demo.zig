//! png_demo — port of the GL `png_demo`: decode an embedded PNG at
//! runtime, upload it to a GPU texture, and draw it four times (2×2 grid, 4×
//! zoom) with different tints. The GL version routed through the retained
//! `gpu.GpuTexture` system; on wgpu the path is the engine's
//! `loadImageFromMemory` → `loadTextureFromImage` → `drawTexture` (tinted
//! quad). The decoded CPU pixels are freed right after upload (the texture
//! lives on the GPU).
const std = @import("std");
const allocPrint = std.fmt.allocPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;

const float = zm.float;
const common = @import("example_common");
const c = z.colors;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
const smiley_png = @embedFile("smiley.png");

const State = struct {
    font: z.Font,
    tex: z.WgpuTexture,
    scratch: std.heap.ArenaAllocator,
    frame_count: usize = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.tex.deinit();
    s.scratch.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24);
    // Decode → upload → free the CPU pixels (RGBA8, w*h*4); the texture is GPU-resident.
    const img: z.Image = try z.loadImageFromMemory(gpa, smiley_png);
    const tex: z.WgpuTexture = z.loadTextureFromImage(f.gl, img);
    if (img.data) |d| {
        const px_len: usize = @as(usize, @intCast(img.width)) * @as(usize, @intCast(img.height)) * 4;
        gpa.free(@as([*]u8, @ptrCast(d))[0..px_len]);
    }
    s.* = .{ .font = font, .tex = tex, .scratch = std.heap.ArenaAllocator.init(gpa) };
}

fn update(f: *z.Frame, state: *State) void {
    _ = state.scratch.reset(.retain_capacity);
    state.frame_count += 1;
    z.clearViewport(f, common.palette.bg);

    const tw: f32 = float(state.tex.width) * 4.0;
    const th: f32 = float(state.tex.height) * 4.0;
    const padding: f32 = 32;
    const total_w: f32 = tw * 2 + padding;
    const total_h: f32 = th * 2 + padding;
    const start_x: f32 = (f.window.widthf() - total_w) * 0.5;
    const start_y: f32 = (f.window.heightf() - total_h) * 0.5;

    const tints: [4]Color = .{ c.white, c.sky_300, c.amber_400, c.pink_400 };
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const col: f32 = float(i % 2);
        const row: f32 = float(i / 2);
        const x: f32 = start_x + col * (tw + padding);
        const y: f32 = start_y + row * (th + padding);
        f.gl.texture(.{ .x = x, .y = y, .width = tw, .height = th }, state.tex, .{ .tint = tints[i] });
    }

    const hud: []const u8 = allocPrint(
        state.scratch.allocator(),
        "embedded PNG: {d}x{d} - decoded at runtime, drawn tinted 2x2",
        .{ state.tex.width, state.tex.height },
    ) catch "png demo";
    common.caption(f.gl, state.font, hud);
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - png demo",
            .width = 800,
            .height = 600,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
