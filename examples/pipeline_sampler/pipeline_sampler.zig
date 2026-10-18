//! pipeline_sampler - texture sampling control (`src/notes/webgpu_control.md`, Phase 3): one texture drawn four ways,
//! each through its own sampler, with texture coordinates running from 0 to 2.5 so that both halves of a sampler show:
//!
//!   nearest / repeat   linear / repeat
//!   linear  / clamp    linear / mirror
//!
//! The FILTER decides how texels become pixels when the texture is magnified: nearest keeps every texel a hard square,
//! linear blends the four texels around each pixel. The ADDRESS MODE decides what a coordinate past the edge (u or v
//! above 1) reads: repeat starts the texture over, clamp holds the edge texel, mirror flips every other copy.
//!
//! The pattern - a checkerboard tinted by a gradient, red across and green down - is computed on the CPU and uploaded
//! once (`patternPixels`). The 2D renderer draws the cells, so the example has no shader of its own and runs the same
//! on the web and on Windows. Each cell is the one texture seen through a view of its own, paired with its own sampler:
//! the 2D renderer keeps one material per texture view, so four samplers need four views.
//!
//! Build: zig build pipeline-sampler -Dplatform=web (or -Dplatform=windows)

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const common = @import("example_common");
const zm = @import("zm");
const Vec3 = zm.Vec3;
const clamp01 = zm.clamp01;
const float = zm.float;
const lerp = zm.lerp;
const vec3 = zm.vec3;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

/// The texture is this many texels on a side.
const texture_size: u32 = 128;
/// RGBA8: four bytes a texel.
const pattern_bytes: usize = texture_size * texture_size * 4;
/// The cells' texture coordinates run from 0 to this, so each cell shows the texture this many times across.
const uv_max: f32 = 2.5;
/// Checkerboard squares along each side of the texture.
const checker_squares: f32 = 6;
const dark: Vec3 = .{ 0.10, 0.12, 0.20 };
const light: Vec3 = .{ 0.96, 0.92, 0.80 };
/// How far the checkerboard is mixed toward the gradient.
const tint_amount: f32 = 0.45;
/// The gradient's blue, everywhere: its red runs with u and its green with v.
const tint_blue: f32 = 0.55;
/// Half a cell's side, in the layout's unit: half the window's smaller side.
const cell_half_side: f32 = 0.42;

/// One of the four ways of sampling the texture, and where it is drawn.
const Cell = struct {
    /// The cell's centre, in the layout's unit from the window's centre, y up.
    center_x: f32,
    center_y: f32,
    label: []const u8,
    /// Linear filtering, magnifying and minifying, or nearest.
    is_linear: bool,
    address: z.wgpu.SamplerDesc.AddressMode,
};

const cells = [4]Cell{
    .{ .center_x = -0.52, .center_y = 0.52, .label = "nearest / repeat", .is_linear = false, .address = .repeat },
    .{ .center_x = 0.52, .center_y = 0.52, .label = "linear / repeat", .is_linear = true, .address = .repeat },
    .{ .center_x = -0.52, .center_y = -0.52, .label = "linear / clamp", .is_linear = true, .address = .clamp_to_edge },
    .{ .center_x = 0.52, .center_y = -0.52, .label = "linear / mirror", .is_linear = true, .address = .mirror_repeat },
};

const State = struct {
    font: z.Font,
    /// The pattern, uploaded once.
    texture: z.wgpu.TextureHandle,
    /// One view of the texture per cell, each drawn with the sampler beside it.
    views: [cells.len]z.wgpu.TextureViewHandle,
    samplers: [cells.len]z.wgpu.SamplerHandle,
};

/// The pattern as RGBA8 texels, row by row from the top: a checkerboard of `checker_squares` squares a side, dark and
/// light, mixed `tint_amount` of the way toward a gradient that runs red left to right and green top to bottom.
fn patternPixels(out_pixels: *[pattern_bytes]u8) void {
    for (0..texture_size) |row| {
        for (0..texture_size) |column| {
            const u: f32 = float(column) / float(texture_size);
            const v: f32 = float(row) / float(texture_size);
            const checker: f32 = @mod(@floor(u * checker_squares) + @floor(v * checker_squares), 2.0);
            const base: Vec3 = lerp(dark, light, checker);
            const tinted: Vec3 = clamp01(lerp(base, vec3(u, v, tint_blue), tint_amount));
            const texel: usize = (row * texture_size + column) * 4;
            out_pixels[texel + 0] = @round(tinted[0] * 255.0);
            out_pixels[texel + 1] = @round(tinted[1] * 255.0);
            out_pixels[texel + 2] = @round(tinted[2] * 255.0);
            out_pixels[texel + 3] = 255;
        }
    }
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const pixels: *[pattern_bytes]u8 = try gpa.create([pattern_bytes]u8);
    defer gpa.destroy(pixels);
    patternPixels(pixels);
    // Loaded before any GPU object is made: nothing below can fail, so nothing needs undoing.
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 20);

    const texture: z.wgpu.TextureHandle = z.wgpu.createTexture(f.gpu.device, .{
        .width = texture_size,
        .height = texture_size,
        .format = .rgba8_unorm,
        .usage = .{ .texture_binding = true, .copy_dst = true },
        .label = "sampler pattern",
    });
    z.wgpu.queueWriteTexture(f.gpu.queue, texture, texture_size, texture_size, texture_size * 4, pixels);
    var views: [cells.len]z.wgpu.TextureViewHandle = undefined;
    var samplers: [cells.len]z.wgpu.SamplerHandle = undefined;
    for (cells, &views, &samplers) |cell, *view, *sampler| {
        view.* = z.wgpu.createTextureView(texture);
        sampler.* = z.wgpu.createSampler(f.gpu.device, .{
            .mag_filter_linear = cell.is_linear,
            .min_filter_linear = cell.is_linear,
            .address_mode = cell.address,
        });
    }
    s.* = .{
        .font = font,
        .texture = texture,
        .views = views,
        .samplers = samplers,
    };
}

fn deinit(gpa: Allocator, s: *State) void {
    for (s.views, s.samplers) |view, sampler| {
        z.wgpu.destroyTextureView(view);
        z.wgpu.destroySampler(sampler);
    }
    z.wgpu.destroyTexture(s.texture);
    z.unloadFont(gpa, s.font);
}

fn update(f: *z.Frame, s: *State) void {
    z.beginDrawing(f.gl);
    const width: f32 = f.window.widthf();
    const height: f32 = f.window.heightf();
    // The layout's unit, half the window's smaller side, keeps the cells square at any aspect.
    const unit: f32 = 0.5 * @min(width, height);
    const window_center_x: f32 = 0.5 * width;
    const window_center_y: f32 = 0.5 * height;
    const cell_side: f32 = 2 * cell_half_side * unit;
    // In texels, as `source` always is: `uv_max` times the texture's size runs the coordinates from 0 to `uv_max`.
    const source_side: f32 = uv_max * float(texture_size);
    const source: z.Rectangle = .{ .x = 0, .y = 0, .width = source_side, .height = source_side };
    for (cells, s.views, s.samplers) |cell, view, sampler| {
        const left: f32 = window_center_x + (cell.center_x - cell_half_side) * unit;
        const top: f32 = window_center_y - (cell.center_y + cell_half_side) * unit;
        const drawable: z.WgpuTexture = .{
            .handle = s.texture,
            .view = view,
            .sampler = sampler,
            .width = texture_size,
            .height = texture_size,
        };
        const cell_rect: z.Rectangle = .{ .x = left, .y = top, .width = cell_side, .height = cell_side };
        f.gl.texture(cell_rect, drawable, .{ .source = source });
        // Under the cell, roughly centred.
        const label_x: f32 = window_center_x + cell.center_x * unit - 70;
        const label_y: f32 = window_center_y - (cell.center_y - cell_half_side) * unit + 8;
        f.gl.text(.{ label_x, label_y }, cell.label, .{
            .size = 20,
            .color = common.palette.ink_dim,
            .font = &s.font,
        });
    }
    common.caption(f.gl, s.font, "pipeline_sampler: filter (nearest/linear) + address (repeat/clamp/mirror)");
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - pipeline sampler",
            .width = 800,
            .height = 600,
            .scale_mode = .responsive,
            .clear = .{ .r = 0.02, .g = 0.02, .b = 0.03, .a = 1.0 },
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
    .manages_own_frame = true,
};
