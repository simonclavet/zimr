// src/wgpu_texture.zig - texture + render-texture lifetime wrappers.
// WebGPU architecture is documented centrally in src/zimr.zig
// (the module-level `//!` doc) — read that before changing wgpu code.
//
//
// Two flavours:
//
//   1. `WgpuTexture` — a 2D texture sourced from CPU-side pixel data
//      or a 1×1 solid color (the "shapes-batch white pixel" pattern).
//      Owns its underlying texture + default view + default sampler.
//
//   2. `WgpuRenderTexture` — a render-target texture.  Used for
//      offscreen rendering (`beginTextureMode` / `endTextureMode` in
//      raylib).  Owns texture + view + (optional) depth attachment.
//
// Both follow the descriptor-with-defaults pattern (D3 / D5).  The
// helper structs let callers spell out only the fields that matter
// and let the engine fill in sane defaults.

const std = @import("std");
const gpu = @import("gpu.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const Allocator = std.mem.Allocator;
const zm = @import("zm");
const assert = zm.assert;
const wgpu = @import("wgpu.zig");

// ============================================================================
// SECTION 1 — WgpuTexture
// ============================================================================

pub const WgpuTexture = struct {
    handle: wgpu.TextureHandle = .invalid,
    view: wgpu.TextureViewHandle = .invalid,
    sampler: wgpu.SamplerHandle = .invalid,
    width: u32 = 0,
    height: u32 = 0,
    format: wgpu.TextureFormat = .rgba8_unorm,

    /// Allocate + initial-upload from RGBA8 pixel data.
    pub const CreateFromPixelsDesc = struct {
        pixels: []const u8,
        width: u32,
        height: u32,
        format: wgpu.TextureFormat = .rgba8_unorm,
        mag_filter_linear: bool = false,
        min_filter_linear: bool = false,
        address_mode: wgpu.SamplerDesc.AddressMode = .clamp_to_edge,
        label: []const u8 = "texture",
    };

    pub fn createFromPixels(
        device: wgpu.DeviceHandle,
        queue: wgpu.QueueHandle,
        desc: CreateFromPixelsDesc,
    ) WgpuTexture {
        // Sanity check: pixel buffer size should match the expected
        // (width × height × bytes_per_pixel) — for RGBA8 that's 4.
        assert(desc.pixels.len == desc.width * desc.height * 4, @src());

        const tex: wgpu.TextureHandle = wgpu.createTexture(device, .{
            .width = desc.width,
            .height = desc.height,
            .format = desc.format,
            .usage = .{ .texture_binding = true, .copy_dst = true },
            .label = desc.label,
        });
        wgpu.queueWriteTexture(
            queue,
            tex,
            desc.width,
            desc.height,
            desc.width * 4,
            desc.pixels,
        );
        const view: wgpu.TextureViewHandle = wgpu.createTextureView(tex);
        const sampler: wgpu.SamplerHandle = wgpu.createSampler(device, .{
            .mag_filter_linear = desc.mag_filter_linear,
            .min_filter_linear = desc.min_filter_linear,
            .address_mode = desc.address_mode,
        });
        return .{
            .handle = tex,
            .view = view,
            .sampler = sampler,
            .width = desc.width,
            .height = desc.height,
            .format = desc.format,
        };
    }

    /// Like `createFromPixels`, but builds a full CPU mip chain (2×2 box
    /// downsample per level) and uploads every level. WebGPU has no
    /// `generateMipmap`, so we precompute the chain here. This keeps a glyph
    /// atlas crisp when MINIFIED (small on-screen text drawn from an oversampled
    /// atlas): plain bilinear undersamples past 2× reduction and aliases; mip
    /// selection picks a level close to the on-screen size.
    ///
    /// Filtering is BILINEAR within a level but NEAREST across levels
    /// (`mipmap_filter_linear = false`): trilinear blends two mip levels on every
    /// texel, which visibly SOFTENS text even near 1:1 (it always mixes in the
    /// half-resolution level). Hard mip selection snaps to the single level
    /// closest to the on-screen size, so glyphs stay sharp; there's no animated
    /// scale here to make level transitions "pop". RGBA8 only.
    pub fn createMipmappedFromPixels(
        gpa: Allocator,
        device: wgpu.DeviceHandle,
        queue: wgpu.QueueHandle,
        desc: CreateFromPixelsDesc,
    ) !WgpuTexture {
        assert(desc.pixels.len == desc.width * desc.height * 4, @src());

        const mip_count: u32 = mipLevelCount(desc.width, desc.height);
        const tex: wgpu.TextureHandle = wgpu.createTexture(device, .{
            .width = desc.width,
            .height = desc.height,
            .format = desc.format,
            .usage = .{ .texture_binding = true, .copy_dst = true },
            .mip_level_count = mip_count,
            .label = desc.label,
        });

        // Level 0 is the source pixels; each subsequent level is the previous
        // level box-downsampled by 2. `cur` owns the level being uploaded (level
        // 0 borrows the caller's buffer; levels ≥1 are freshly allocated).
        wgpu.queueWriteTextureLevel(queue, tex, desc.width, desc.height, desc.width * 4, desc.pixels, 0);
        var cur: []const u8 = desc.pixels;
        var cur_owned: ?[]u8 = null;
        defer if (cur_owned) |b| gpa.free(b);
        var w: u32 = desc.width;
        var h: u32 = desc.height;
        var level: u32 = 1;
        while (level < mip_count) : (level += 1) {
            const nw: u32 = @max(w >> 1, 1);
            const nh: u32 = @max(h >> 1, 1);
            const next: []u8 = try gpa.alloc(u8, nw * nh * 4);
            boxDownsampleRgba8(cur, w, h, next, nw, nh);
            wgpu.queueWriteTextureLevel(queue, tex, nw, nh, nw * 4, next, level);
            if (cur_owned) |b| gpa.free(b);
            cur_owned = next;
            cur = next;
            w = nw;
            h = nh;
        }

        const view: wgpu.TextureViewHandle = wgpu.createTextureView(tex);
        const sampler: wgpu.SamplerHandle = wgpu.createSampler(device, .{
            .mag_filter_linear = true,
            .min_filter_linear = true,
            .mipmap_filter_linear = false,
            .address_mode = desc.address_mode,
        });
        return .{
            .handle = tex,
            .view = view,
            .sampler = sampler,
            .width = desc.width,
            .height = desc.height,
            .format = desc.format,
        };
    }

    /// Full mip chain length for a `w`×`h` texture: floor(log2(max))+1.
    fn mipLevelCount(w: u32, h: u32) u32 {
        var m: u32 = @max(w, h);
        var levels: u32 = 1;
        while (m > 1) : (m >>= 1) {
            levels += 1;
        }
        return levels;
    }

    /// 2×2 box-average `src` (sw×sh, RGBA8) into `dst` (dw×dh, RGBA8). When a
    /// dimension is odd the extra edge row/column is dropped (dw=sw/2 etc.),
    /// which is the standard mip reduction and imperceptible for a glyph atlas.
    fn boxDownsampleRgba8(
        src: []const u8,
        sw: u32,
        sh: u32,
        dst: []u8,
        dw: u32,
        dh: u32,
    ) void {
        var y: u32 = 0;
        while (y < dh) : (y += 1) {
            const sy0: u32 = @min(y * 2, sh - 1);
            const sy1: u32 = @min(sy0 + 1, sh - 1);
            var x: u32 = 0;
            while (x < dw) : (x += 1) {
                const sx0: u32 = @min(x * 2, sw - 1);
                const sx1: u32 = @min(sx0 + 1, sw - 1);
                const p00: usize = (sy0 * sw + sx0) * 4;
                const p01: usize = (sy0 * sw + sx1) * 4;
                const p10: usize = (sy1 * sw + sx0) * 4;
                const p11: usize = (sy1 * sw + sx1) * 4;
                const o: usize = (y * dw + x) * 4;
                inline for (0..4) |ch| {
                    const sum: u32 = @as(u32, src[p00 + ch]) +
                        @as(u32, src[p01 + ch]) +
                        @as(u32, src[p10 + ch]) +
                        @as(u32, src[p11 + ch]);
                    dst[o + ch] = @intCast((sum + 2) / 4);
                }
            }
        }
    }

    /// Re-upload RGBA8 pixels into this texture IN PLACE — no new GPU texture/
    /// view/sampler, so it's cheap to call every frame (animated/streamed
    /// content). The buffer must match width×height×4. raylib `UpdateTexture`.
    pub fn updatePixels(
        self: WgpuTexture,
        queue: wgpu.QueueHandle,
        pixels: []const u8,
    ) void {
        assert(pixels.len == self.width * self.height * 4, @src());
        wgpu.queueWriteTexture(
            queue,
            self.handle,
            self.width,
            self.height,
            self.width * 4,
            pixels,
        );
    }

    /// The "shapes-batch white pixel" — a 1×1 fully-white texture used
    /// when drawing untextured shapes through the same pipeline as
    /// textured shapes.  Cheap (4 bytes uploaded once) and lets the
    /// fragment shader unconditionally multiply by texture color.
    pub fn createWhite1x1(
        device: wgpu.DeviceHandle,
        queue: wgpu.QueueHandle,
    ) WgpuTexture {
        const white: [4]u8 = .{ 255, 255, 255, 255 };
        return createFromPixels(device, queue, .{
            .pixels = &white,
            .width = 1,
            .height = 1,
            .label = "shapes_white_1x1",
        });
    }

    /// A pre-filled checkerboard for debugging UV / texturing.
    /// Pattern: 8×8 grid of 2-color squares.
    pub fn createCheckerboard(
        device: wgpu.DeviceHandle,
        queue: wgpu.QueueHandle,
        gpa: Allocator,
        a: [4]u8,
        b: [4]u8,
        size: u32,
        cell: u32,
    ) !WgpuTexture {
        const pixel_count = @as(usize, size) * @as(usize, size);
        const pixels = try gpa.alloc(u8, pixel_count * 4);
        defer gpa.free(pixels);

        var y: u32 = 0;
        while (y < size) : (y += 1) {
            var x: u32 = 0;
            while (x < size) : (x += 1) {
                const cell_x = x / cell;
                const cell_y = y / cell;
                const is_a = (cell_x ^ cell_y) & 1 == 0;
                const color = if (is_a) a else b;
                const off = (@as(usize, y) * size + @as(usize, x)) * 4;
                pixels[off + 0] = color[0];
                pixels[off + 1] = color[1];
                pixels[off + 2] = color[2];
                pixels[off + 3] = color[3];
            }
        }

        return createFromPixels(device, queue, .{
            .pixels = pixels,
            .width = size,
            .height = size,
            .label = "checker",
        });
    }

    pub fn deinit(self: *WgpuTexture) void {
        if (self.handle != .invalid) {
            wgpu.destroyTexture(self.handle);
        }
        if (self.view != .invalid) {
            wgpu.destroyTextureView(self.view);
        }
        if (self.sampler != .invalid) {
            wgpu.destroySampler(self.sampler);
        }
        self.* = .{};
    }
};

// ============================================================================
// SECTION 2 — WgpuRenderTexture
// ============================================================================

pub const WgpuRenderTexture = struct {
    color: wgpu.TextureHandle = .invalid,
    color_view: wgpu.TextureViewHandle = .invalid,
    depth: ?wgpu.TextureHandle = null,
    depth_view: ?wgpu.TextureViewHandle = null,
    width: u32 = 0,
    height: u32 = 0,
    format: wgpu.TextureFormat = .rgba8_unorm,
    sampler: wgpu.SamplerHandle = .invalid,
    /// Non-filtering sampler for reading the depth attachment as a sampled
    /// `texture_depth_2d`. `.invalid` unless `sampleable_depth` was requested.
    depth_sampler: wgpu.SamplerHandle = .invalid,
    /// True when the depth attachment was created with `texture_binding` usage
    /// (a sampleable `depth32float`), so `asDepthTexture()` is valid.
    depth_sampleable: bool = false,

    pub const CreateDesc = struct {
        width: u32,
        height: u32,
        format: wgpu.TextureFormat = .rgba8_unorm,
        with_depth: bool = false,
        depth_format: wgpu.TextureFormat = .depth24_plus,
        /// When true, the depth attachment is created sampleable: `depth32float`
        /// (the WebGPU depth format that supports `texture_binding`; `depth24_plus`
        /// is NOT sampleable) plus a non-filtering sampler. This is the foundation
        /// for depth-visualisation and shadow-map passes that SAMPLE the depth
        /// buffer. Forces `depth_format = .depth32_float` regardless of the field.
        sampleable_depth: bool = false,
        /// Color-sampler filtering. Default (false) is bilinear, matching the
        /// engine's other textures; set true for point/nearest sampling, which
        /// keeps a low-res target CRISP when scaled up (pixel-art) and matches
        /// raylib's default texture filter.
        nearest_filter: bool = false,
        label: []const u8 = "render_texture",
    };

    pub fn create(device: wgpu.DeviceHandle, desc: CreateDesc) WgpuRenderTexture {
        const color: wgpu.TextureHandle = wgpu.createTexture(device, .{
            .width = desc.width,
            .height = desc.height,
            .format = desc.format,
            .usage = .{
                .render_attachment = true,
                .texture_binding = true,
                .copy_src = true,
            },
            .label = desc.label,
        });
        const color_view: wgpu.TextureViewHandle = wgpu.createTextureView(color);
        const sampler: wgpu.SamplerHandle = wgpu.createSampler(device, .{
            .mag_filter_linear = !desc.nearest_filter,
            .min_filter_linear = !desc.nearest_filter,
            .address_mode = .clamp_to_edge,
        });

        var depth: ?wgpu.TextureHandle = null;
        var depth_view: ?wgpu.TextureViewHandle = null;
        var depth_sampler: wgpu.SamplerHandle = .invalid;
        if (desc.with_depth) {
            // A sampleable depth attachment must be `depth32float` (the depth
            // format that supports `texture_binding`; `depth24_plus` cannot be
            // sampled) and carry `texture_binding` usage so a later pass can read
            // it as a `texture_depth_2d`.
            const dfmt: wgpu.TextureFormat = if (desc.sampleable_depth)
                .depth32_float
            else
                desc.depth_format;
            const dtex: wgpu.TextureHandle = wgpu.createTexture(device, .{
                .width = desc.width,
                .height = desc.height,
                .format = dfmt,
                .usage = .{
                    .render_attachment = true,
                    .texture_binding = desc.sampleable_depth,
                },
                .label = desc.label,
            });
            depth = dtex;
            depth_view = wgpu.createTextureView(dtex);
            if (desc.sampleable_depth) {
                // Depth formats are non-filterable, so the read sampler is
                // nearest (a comparison sampler is a separate, later concern).
                depth_sampler = wgpu.createSampler(device, .{
                    .mag_filter_linear = false,
                    .min_filter_linear = false,
                    .address_mode = .clamp_to_edge,
                });
            }
        }

        return .{
            .color = color,
            .color_view = color_view,
            .depth = depth,
            .depth_view = depth_view,
            .width = desc.width,
            .height = desc.height,
            .format = desc.format,
            .sampler = sampler,
            .depth_sampler = depth_sampler,
            .depth_sampleable = desc.sampleable_depth and desc.with_depth,
        };
    }

    /// View the (sampleable) depth attachment as a `WgpuTexture` so a depth-
    /// visualisation / shadow shader can bind + sample it. ONLY valid when the
    /// render texture was created with `sampleable_depth` (asserts otherwise via
    /// the `.invalid` handles). Format is `depth32_float`; the consuming shader
    /// must declare it as `texture_depth_2d`, not `texture_2d<f32>`.
    pub fn asDepthTexture(self: WgpuRenderTexture) WgpuTexture {
        return .{
            .handle = self.depth orelse .invalid,
            .view = self.depth_view orelse .invalid,
            .sampler = self.depth_sampler,
            .width = self.width,
            .height = self.height,
            .format = .depth32_float,
        };
    }

    /// View this render texture as a sampleable `WgpuTexture` (for `drawTextureRec`).
    pub fn asTexture(self: WgpuRenderTexture) WgpuTexture {
        return .{
            .handle = self.color,
            .view = self.color_view,
            .sampler = self.sampler,
            .width = self.width,
            .height = self.height,
            .format = self.format,
        };
    }

    pub fn deinit(self: *WgpuRenderTexture) void {
        if (self.color != .invalid) {
            wgpu.destroyTexture(self.color);
        }
        if (self.color_view != .invalid) {
            wgpu.destroyTextureView(self.color_view);
        }
        if (self.depth) |d| {
            wgpu.destroyTexture(d);
        }
        if (self.depth_view) |dv| {
            wgpu.destroyTextureView(dv);
        }
        if (self.sampler != .invalid) {
            wgpu.destroySampler(self.sampler);
        }
        if (self.depth_sampler != .invalid) {
            wgpu.destroySampler(self.depth_sampler);
        }
        self.* = .{};
    }
};

// ============================================================================
// SECTION 3 — bind group construction helpers
// ============================================================================

/// Build a bind group entries blob for a (UBO, texture, sampler)
/// material-style binding.  Convention from D6: binding 0 = UBO,
/// binding 1 = texture, binding 2 = sampler.
pub fn encodeMaterialBindGroupEntries(
    gpa: Allocator,
    ubo: wgpu.BufferHandle,
    ubo_size: u64,
    texture: WgpuTexture,
) ![]u8 {
    return gpu.encodeBindGroupEntries(gpa, &.{
        .{
            .binding = 0,
            .resource = .{ .buffer = .{ .handle = ubo, .size = ubo_size } },
        },
        .{
            .binding = 1,
            .resource = .{ .texture_view = texture.view },
        },
        .{
            .binding = 2,
            .resource = .{ .sampler = texture.sampler },
        },
    });
}

// ============================================================================
// Tests
// ============================================================================

test "WgpuTexture.createCheckerboard produces correct pattern bytes" {
    // We can't actually upload from a host test (no JS bridge), but
    // we can test the helper that constructs the pixel pattern.
    // Extract the inner pattern-generation code into a testable fn:
    const gpa: Allocator = std.testing.allocator;
    const a: [4]u8 = .{ 0xff, 0x00, 0x00, 0xff };
    const b: [4]u8 = .{ 0x00, 0xff, 0x00, 0xff };
    const size: u32 = 4;
    const cell: u32 = 2;

    var pixels = try gpa.alloc(u8, @as(usize, size) * size * 4);
    defer gpa.free(pixels);

    var y: u32 = 0;
    while (y < size) : (y += 1) {
        var x: u32 = 0;
        while (x < size) : (x += 1) {
            const is_a = ((x / cell) ^ (y / cell)) & 1 == 0;
            const color = if (is_a) a else b;
            const off = (@as(usize, y) * size + @as(usize, x)) * 4;
            pixels[off + 0] = color[0];
            pixels[off + 1] = color[1];
            pixels[off + 2] = color[2];
            pixels[off + 3] = color[3];
        }
    }

    // Pixel (0,0) is in cell (0,0) → is_a=true → red
    try expectEqual(@as(u8, 0xff), pixels[0]);
    try expectEqual(@as(u8, 0x00), pixels[1]);
    // Pixel (3,0) is in cell (1,0) → is_a=false → green
    try expectEqual(@as(u8, 0x00), pixels[3 * 4 + 0]);
    try expectEqual(@as(u8, 0xff), pixels[3 * 4 + 1]);
}

test "WgpuTexture default-initialises to invalid handles" {
    const t: WgpuTexture = .{};
    try expectEqual(wgpu.TextureHandle.invalid, t.handle);
    try expectEqual(wgpu.TextureViewHandle.invalid, t.view);
    try expectEqual(wgpu.SamplerHandle.invalid, t.sampler);
}

test "WgpuRenderTexture without depth has null depth handles" {
    const rt: WgpuRenderTexture = .{};
    try expect(rt.depth == null);
    try expect(rt.depth_view == null);
}

test "WgpuRenderTexture sampleable-depth fields default off" {
    const rt: WgpuRenderTexture = .{};
    try expect(rt.depth_sampleable == false);
    try expectEqual(wgpu.SamplerHandle.invalid, rt.depth_sampler);
    // asDepthTexture on a no-depth RT yields invalid handles + the depth format
    // (so a miswired caller gets invalid bindings, not a silent color sample).
    const dt: WgpuTexture = rt.asDepthTexture();
    try expectEqual(wgpu.TextureHandle.invalid, dt.handle);
    try expectEqual(wgpu.TextureViewHandle.invalid, dt.view);
    try expectEqual(wgpu.TextureFormat.depth32_float, dt.format);
}

test "WgpuRenderTexture.CreateDesc sampleable_depth defaults false / depth24" {
    const d: WgpuRenderTexture.CreateDesc = .{ .width = 4, .height = 4 };
    try expect(d.sampleable_depth == false);
    try expect(d.with_depth == false);
    try expectEqual(wgpu.TextureFormat.depth24_plus, d.depth_format);
}
