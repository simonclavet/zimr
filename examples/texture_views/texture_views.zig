//! texture_views - one texture, seen through different views: each level of a mip chain, the chain as a whole, and
//! each layer of a texture array.
//!
//! A texture is more than one image. It holds a *mip chain*: level 0 at full size, and below it levels each half the
//! size of the one above, down to a single texel - 256, 128, 64 ... 1 here, nine levels in all. It can also hold
//! *layers*: several images of the same size side by side in one texture, an array. Each image in the texture - one
//! level of one layer - is a *subresource*.
//!
//! A *view* says which subresources a use of the texture sees. Rendering needs exactly one: a render pass draws into
//! one level of one layer, so painting the chain takes one view per level, and painting the array one view per
//! layer. Sampling may see many: a view of the whole chain lets the GPU choose, pixel by pixel, which level to read.
//!
//! The GPU's choice follows the *footprint* of a screen pixel on the texture. When a 256-texel-wide image covers 64
//! pixels on screen, each pixel spans four texels; reading level 0 there would take one texel in four and lose the
//! rest, which is what makes distant textures shimmer. The level whose texels are pixel-sized - here level 2, 64
//! texels across - already holds the average of each 4x4 block, so the GPU reads it instead: level = log2(texels per
//! pixel), measured from how fast the texture coordinates change from one pixel to the next. A sampler with
//! nearest-mip filtering takes the closest level outright; one with linear mip filtering blends the two around it.
//!
//! This example paints each level of a chain in its own colour, through a view of that level, with the ordinary 2D
//! renderer - a view wrapped as a render texture is a render target like any other. It then shows the chain three
//! ways: each level through a view of that level alone; the whole chain drawn at several sizes through a
//! nearest-mip sampler, where each quad's colour names the level the GPU chose; and a four-layer array, each layer
//! drawn into every frame through its own view and shown through that same view.

const std = @import("std");
const Allocator = std.mem.Allocator;
const bufPrint = std.fmt.bufPrint;
const z = @import("zimr");
const common = @import("example_common");
const zm = @import("zm");
const float = zm.float;
const Color = zm.Color;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

/// The chain's level 0 is this many texels on a side; each level below it is half the one above.
const chain_size: u32 = 256;
/// Levels down to a single texel: 256 = 2^8, so levels 0 through 8.
const level_count: usize = 9;
/// The array's layers, each this many texels on a side, with a single level.
const layer_count: usize = 4;
const layer_size: u32 = 128;

/// One colour per level, so a level shows which it is wherever it is sampled.
const level_colors = [level_count]Color{
    .{ .r = 230, .g = 57, .b = 70, .a = 255 },
    .{ .r = 244, .g = 140, .b = 6, .a = 255 },
    .{ .r = 255, .g = 214, .b = 10, .a = 255 },
    .{ .r = 82, .g = 183, .b = 136, .a = 255 },
    .{ .r = 42, .g = 157, .b = 143, .a = 255 },
    .{ .r = 69, .g = 123, .b = 220, .a = 255 },
    .{ .r = 110, .g = 90, .b = 220, .a = 255 },
    .{ .r = 170, .g = 78, .b = 221, .a = 255 },
    .{ .r = 240, .g = 128, .b = 200, .a = 255 },
};

/// One colour per layer of the array.
const layer_colors = [layer_count]Color{
    .{ .r = 96, .g = 165, .b = 250, .a = 255 },
    .{ .r = 74, .g = 222, .b = 128, .a = 255 },
    .{ .r = 250, .g = 204, .b = 21, .a = 255 },
    .{ .r = 248, .g = 113, .b = 113, .a = 255 },
};

const text_color: Color = .{ .r = 226, .g = 232, .b = 240, .a = 255 };
const dim_color: Color = .{ .r = 148, .g = 163, .b = 184, .a = 255 };

const State = struct {
    font: z.Font,
    /// The mip chain, its views - one per level, and one of the whole chain - and whether its levels are painted.
    chain: z.wgpu.TextureHandle,
    level_views: [level_count]z.wgpu.TextureViewHandle,
    chain_view: z.wgpu.TextureViewHandle,
    is_chain_painted: bool = false,
    /// The array, and one 2D view per layer.
    array: z.wgpu.TextureHandle,
    layer_views: [layer_count]z.wgpu.TextureViewHandle,
    /// Nearest everywhere, between levels too: a magnified level shows its texels as squares, and a minified chain
    /// shows exactly one level's colour.
    sampler: z.wgpu.SamplerHandle,
};

/// The size of level `level` of the chain: level 0's size halved `level` times.
fn levelSize(level: usize) u32 {
    return chain_size >> @intCast(level);
}

/// A view as a render target: what `beginTextureMode` draws into. The target owns nothing - the texture and the
/// view stay the example's - so it is never deinitialised.
fn targetOf(
    texture: z.wgpu.TextureHandle,
    view: z.wgpu.TextureViewHandle,
    size: u32,
) z.RenderTexture {
    return .{ .color = texture, .color_view = view, .width = size, .height = size };
}

/// A view as something to draw: the texture seen through `view`, read with the example's sampler.
fn drawableOf(
    texture: z.wgpu.TextureHandle,
    view: z.wgpu.TextureViewHandle,
    sampler: z.wgpu.SamplerHandle,
    size: u32,
) z.WgpuTexture {
    return .{ .handle = texture, .view = view, .sampler = sampler, .width = size, .height = size };
}

/// A colour at `fraction` of its brightness.
fn shade(color: Color, fraction: f32) Color {
    return .{
        .r = @trunc(float(color.r) * fraction),
        .g = @trunc(float(color.g) * fraction),
        .b = @trunc(float(color.b) * fraction),
        .a = color.a,
    };
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const chain: z.wgpu.TextureHandle = z.wgpu.createTexture(f.gpu.device, .{
        .width = chain_size,
        .height = chain_size,
        .format = .rgba8_unorm,
        .usage = .{ .texture_binding = true, .render_attachment = true },
        .mip_level_count = level_count,
        .label = "mip chain",
    });
    var level_views: [level_count]z.wgpu.TextureViewHandle = undefined;
    for (&level_views, 0..) |*view, level| {
        view.* = z.wgpu.createTextureViewMip(chain, @intCast(level), 1);
    }
    const array: z.wgpu.TextureHandle = z.wgpu.createTexture(f.gpu.device, .{
        .width = layer_size,
        .height = layer_size,
        .format = .rgba8_unorm,
        .usage = .{ .texture_binding = true, .render_attachment = true },
        .array_layers = layer_count,
        .label = "texture array",
    });
    var layer_views: [layer_count]z.wgpu.TextureViewHandle = undefined;
    for (&layer_views, 0..) |*view, layer| {
        view.* = z.wgpu.createTextureViewLayer(array, @intCast(layer));
    }
    const sampler: z.wgpu.SamplerHandle = z.wgpu.createSampler(f.gpu.device, .{
        .mag_filter_linear = false,
        .min_filter_linear = false,
        .mipmap_filter_linear = false,
    });
    s.* = .{
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 20),
        .chain = chain,
        .level_views = level_views,
        .chain_view = z.wgpu.createTextureView(chain),
        .array = array,
        .layer_views = layer_views,
        .sampler = sampler,
    };
}

fn deinit(gpa: Allocator, s: *State) void {
    for (s.level_views) |view| {
        z.wgpu.destroyTextureView(view);
    }
    z.wgpu.destroyTextureView(s.chain_view);
    z.wgpu.destroyTexture(s.chain);
    for (s.layer_views) |view| {
        z.wgpu.destroyTextureView(view);
    }
    z.wgpu.destroyTexture(s.array);
    z.wgpu.destroySampler(s.sampler);
    z.unloadFont(gpa, s.font);
}

/// Paints every level of the chain, each through a view of that level: a checkerboard of eight squares a side in the
/// level's colour - or one square per texel, once a level is smaller than eight - and the level's number where it
/// fits. The levels never change, so they are painted once.
fn paintChain(f: *z.Frame, s: *State) void {
    for (s.level_views, 0..) |view, level| {
        const size: u32 = levelSize(level);
        const color: Color = level_colors[level];
        z.beginTextureMode(f.gl, targetOf(s.chain, view, size), shade(color, 0.55));
        const squares: u32 = @min(size, 8);
        const square: f32 = float(size) / float(squares);
        for (0..squares) |row| {
            for (0..squares) |column| {
                if ((row + column) % 2 != 0) {
                    continue;
                }
                const square_rect: z.Rectangle = .{
                    .x = float(column) * square,
                    .y = float(row) * square,
                    .width = square,
                    .height = square,
                };
                f.gl.rect(square_rect, .{ .color = color });
            }
        }
        if (size >= 32) {
            var label_buffer: [8]u8 = undefined;
            const label: []const u8 = bufPrint(&label_buffer, "{d}", .{level}) catch "?";
            const label_size: f32 = float(size) * 0.4;
            const label_position: [2]f32 = .{ float(size) * 0.32, float(size) * 0.28 };
            f.gl.text(label_position, label, .{ .size = label_size, .color = text_color, .font = &s.font });
        }
        z.endTextureMode(f.gl);
    }
    s.is_chain_painted = true;
}

/// Paints every layer of the array, each through its own view, every frame: a bar in the layer's colour sweeping
/// across it, each layer at its own speed - drawn into the array as the frame runs.
fn paintLayers(f: *z.Frame, s: *State) void {
    for (s.layer_views, 0..) |view, layer| {
        const color: Color = layer_colors[layer];
        z.beginTextureMode(f.gl, targetOf(s.array, view, layer_size), shade(color, 0.25));
        const speed: f32 = 0.35 + 0.2 * float(layer);
        const phase: f32 = f.time.time * speed - @floor(f.time.time * speed);
        const bar_width: f32 = float(layer_size) * 0.25;
        const bar_x: f32 = phase * (float(layer_size) + bar_width) - bar_width;
        f.gl.rect(.{ .x = bar_x, .y = 0, .width = bar_width, .height = float(layer_size) }, .{ .color = color });
        var label_buffer: [16]u8 = undefined;
        const label: []const u8 = bufPrint(&label_buffer, "layer {d}", .{layer}) catch "layer";
        f.gl.text(.{ 10, 10 }, label, .{ .size = 22, .color = text_color, .font = &s.font });
        z.endTextureMode(f.gl);
    }
}

/// Each level through a view of that level alone, all at one size on screen: the small levels magnified, their
/// texels squares.
fn drawLevels(f: *z.Frame, s: *State, top: f32, width: f32) f32 {
    const margin: f32 = 16;
    const gap: f32 = 6;
    const cell: f32 = @min(64, (width - 2 * margin - gap * float(level_count - 1)) / float(level_count));
    f.gl.text(.{ margin, top }, "each level, through a view of that level", .{
        .size = 16,
        .color = dim_color,
        .font = &s.font,
    });
    const row_top: f32 = top + 24;
    for (s.level_views, 0..) |view, level| {
        const x: f32 = margin + float(level) * (cell + gap);
        const level_texture: z.WgpuTexture = drawableOf(s.chain, view, s.sampler, levelSize(level));
        f.gl.texture(.{ .x = x, .y = row_top, .width = cell, .height = cell }, level_texture, .{});
    }
    return row_top + cell + 20;
}

/// The whole chain, at several sizes on screen: each quad reads the level whose texels match its pixels, so its
/// colour is the colour of the level chosen. The last quad breathes between the largest size and the smallest,
/// changing level as it goes.
fn drawChain(f: *z.Frame, s: *State, top: f32, width: f32) f32 {
    const margin: f32 = 16;
    const gap: f32 = 10;
    f.gl.text(.{ margin, top }, "the whole chain at several sizes: the GPU picks the level", .{
        .size = 16,
        .color = dim_color,
        .font = &s.font,
    });
    const sizes = [_]f32{ 128, 64, 32, 16, 8 };
    var total: f32 = 0;
    for (sizes) |size| {
        total += size + gap;
    }
    const fit: f32 = @min(1, (width - 2 * margin - 128 - gap) / total);
    const row_top: f32 = top + 24;
    const chain_texture: z.WgpuTexture = drawableOf(s.chain, s.chain_view, s.sampler, chain_size);
    var x: f32 = margin;
    for (sizes) |size| {
        const shown: f32 = size * fit;
        f.gl.texture(.{ .x = x, .y = row_top, .width = shown, .height = shown }, chain_texture, .{});
        x += shown + gap;
    }
    const breath: f32 = 0.5 + 0.5 * @sin(f.time.time * 0.8);
    const breathing_size: f32 = 8 + breath * 120;
    f.gl.texture(.{ .x = x, .y = row_top, .width = breathing_size, .height = breathing_size }, chain_texture, .{});
    return row_top + 128 + 20;
}

/// Each layer of the array through its own view - the view it was just drawn into.
fn drawLayers(f: *z.Frame, s: *State, top: f32, width: f32) void {
    const margin: f32 = 16;
    const gap: f32 = 10;
    const cell: f32 = @min(128, (width - 2 * margin - gap * float(layer_count - 1)) / float(layer_count));
    f.gl.text(.{ margin, top }, "a texture array: each layer drawn into, and shown, through its own view", .{
        .size = 16,
        .color = dim_color,
        .font = &s.font,
    });
    const row_top: f32 = top + 24;
    for (s.layer_views, 0..) |view, layer| {
        const x: f32 = margin + float(layer) * (cell + gap);
        const layer_texture: z.WgpuTexture = drawableOf(s.array, view, s.sampler, layer_size);
        f.gl.texture(.{ .x = x, .y = row_top, .width = cell, .height = cell }, layer_texture, .{});
    }
}

fn update(f: *z.Frame, s: *State) void {
    // The offscreen passes first: a render pass draws into one level of one layer, so each gets its own.
    if (!s.is_chain_painted) {
        paintChain(f, s);
    }
    paintLayers(f, s);
    z.beginDrawing(f.gl);
    const width: f32 = f.window.widthf();
    const after_levels: f32 = drawLevels(f, s, 44, width);
    const after_chain: f32 = drawChain(f, s, after_levels, width);
    drawLayers(f, s, after_chain, width);
    common.caption(f.gl, s.font, "texture_views: levels and layers, each through its own view");
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - texture views",
            .width = 820,
            .height = 640,
            .scale_mode = .responsive,
            .clear = .{ .r = 0.059, .g = 0.067, .b = 0.090, .a = 1.0 },
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
    .manages_own_frame = true,
};
