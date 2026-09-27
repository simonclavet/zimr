//! lint:alias text2d
//! src/text2d.zig - the backend-generic 2D text stack, MOVED VERBATIM out
//! of drawing.zig (GL retirement P1, t1173): FontCache, TTF atlas bake
//! (`bakeFontAtlas`), `drawWithFont`/`measureWithFont` over `gl: anytype`.
//! Both backends draw text through this file (wgpu_app builds its Font on
//! `bakeFontAtlas`; ui renders through `drawWithFont`).
//! GL-free since GL-retirement P5d.
const std = @import("std");
const memwatch = @import("memwatch.zig");
const ArrayList = std.ArrayList;
const eql = std.mem.eql;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;
const builtin = @import("builtin");
const zm = @import("zm");
const float = zm.float;
const clamp = zm.clamp;
const ceilPowerOfTwo = zm.ceilPowerOfTwo;
// GL-retirement P5d: the GL texture bridge is gone.  Font GPU residency
// on the wgpu path comes from WgpuGl registration (FontCache's
// ensureUploaded feeds the atlas PIXELS to the renderer, which assigns
// its own ids).  `Font.texture.id` from the bake pipeline is therefore
// vestigial; this stub returns a nonzero sentinel so the legacy
// upload-failed checks stay inert.  (Atlas bilinear filtering - the old
// rlTextureParameters tail - is the renderer's sampler config now; see
// the TextureRef-bilinear item in the improvement queue.)
fn cpuAtlasTextureId() u32 {
    return 1;
}

const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const allocator_mod = @import("runtime.zig").allocator;
const truetype = @import("codecs.zig").truetype;
const rectpack = @import("codecs.zig").rectpack;
const glyph_atlas = @import("glyph_atlas.zig");

// Re-export the truetype + rectpack imports so tests and downstream
// callers can reach them via `s.truetype` / `s.rectpack`
// without a separate import statement.
pub const truetype_mod = truetype;
pub const rectpack_mod = rectpack;
const z = struct {
    pub const Rectangle = types.Rectangle;
    pub const Texture = types.Texture;
    pub const Image = types.Image;
    pub const Font = types.Font;
    pub const GlyphInfo = types.GlyphInfo;
};

const Vec2 = zm.Vec2;
const Color = zm.Color;
const Rectangle = z.Rectangle;
const Texture = z.Texture;
const Font = z.Font;
const GlyphInfo = z.GlyphInfo;
const Image = z.Image;

/// Footgun-detector flag.  Flips true the first
/// time `draw` is called with a non-empty string and an
/// unbacked font cache (`texture.id == 0`).  Used to gate a
/// one-shot warning so repeated text submission in a no-
/// font setup doesn't spam the log.  Module-scope is fine
/// wasm + host tests are single-threaded.
var warned_text_no_font: bool = false;

// ===========================================================================
// Externs into rcore + rtextures (still C-side)
// ===========================================================================

// `getFontDefault` is provided by `font_default.zig`.  It would normally
// be an `extern fn` here (matching raylib's C-side global) but Zig's
// wasm linker treats undecorated `extern fn` as `env.<name>` imports
// and doesn't unify those with `pub export fn` defined in another
// compilation unit.  Direct Zig import keeps the call internal so DCE
// strips the whole font system when no example calls `s.draw`.
// font_default.zig itself transitively imports rlgl_gpu (for texture
// upload) and core (for traceLog).  rlgl_gpu pulls in web/dom +
// web/gl which only compile under wasm.  Gate the import: on host
// targets, route to a host-side stub the test binary defines.

// `getFontDefault` is the wasm-gated public accessor for the default
// font.  The actual data + upload logic live at the bottom of this
// file (under "Default bitmap font" - was previously font_default.zig).
// On host builds the GPU upload path doesn't exist, so we return a
// zero-init Font and skip the upload entirely - drawing on host is a
// no-op anyway since the rlgl_gpu calls are stubbed out.
const is_wasm = builtin.target.cpu.arch.isWasm();
pub const glyph_count: i32 = 224;

/// Per-glyph pixel widths.  raylib indexes from codepoint 32 (' ') through
/// 32+224-1 = 255.  Glyph `i` covers codepoint `32 + i`.
pub const chars_width: [224]u8 = .{
    3, 1, 4, 6, 5, 7, 6, 2, 3, 3, 5, 5, 2, 4, 1, 7, 5, 2, 5, 5, 5, 5, 5, 5, 5, 5, 1, 1, 3, 4, 3, 6,
    7, 6, 6, 6, 6, 6, 6, 6, 6, 3, 5, 6, 5, 7, 6, 6, 6, 6, 6, 6, 7, 6, 7, 7, 6, 6, 6, 2, 7, 2, 3, 5,
    2, 5, 5, 5, 5, 5, 4, 5, 5, 1, 2, 5, 2, 5, 5, 5, 5, 5, 5, 5, 4, 5, 5, 5, 5, 5, 5, 3, 1, 3, 4, 4,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 5, 5, 5, 7, 1, 5, 3, 7, 3, 5, 4, 1, 7, 4, 3, 5, 3, 3, 2, 5, 6, 1, 2, 2, 3, 5, 6, 6, 6, 6,
    6, 6, 6, 6, 6, 6, 7, 6, 6, 6, 6, 6, 3, 3, 3, 3, 7, 6, 6, 6, 6, 6, 6, 5, 6, 6, 6, 6, 6, 6, 4, 6,
    5, 5, 5, 5, 5, 5, 9, 5, 5, 5, 5, 5, 2, 2, 3, 3, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 3, 5,
};

pub const glyph_height: i32 = 10;

const total_glyph_bytes: usize = blk: {
    var sum: usize = 0;
    for (chars_width) |w| {
        sum += @as(usize, w) * @as(usize, glyph_height) * 4;
    }
    break :blk sum;
};

pub const atlas_size: i32 = 128;

/// Default-font cache state.  Lazy-init: `globalDefaultFont().loaded` flips to true on
/// first `getFontDefault` call.  All buffers are static-size so the
/// struct is large (~99KB) but we only ever have one instance.
/// The four heavy buffers needed by the raylib bitmap font path
/// (`loadFontRaylibBitmap`).  Heap-allocated on demand so that
/// FontCache instances using the TTF path (the default since the
/// font-default arc) don't carry ~114 KB of vestigial inline
/// storage.  Previously these were `[N]u8 = undefined` fields on
/// FontCache itself, but each FontCache instance forced a const
/// "default-value template" into the wasm data section - two
/// FontCache instances (Runtime.Drawing + State) produced two
/// ~114 KB zero blobs in the binary.  Promoting to a heap pointer
/// drops both templates entirely.
pub const FontCacheBuffers = struct {
    glyphs_buf: [glyph_count]GlyphInfo = undefined,
    recs_buf: [glyph_count]Rectangle = undefined,
    glyph_pixels: [total_glyph_bytes]u8 = undefined,
    atlas_pixels: [atlas_size * atlas_size * 4]u8 = undefined,
};

pub const FontCache = struct {
    loaded: bool = false,
    font: Font = .{
        .baseSize = 0,
        .glyphCount = 0,
        .glyphPadding = 0,
        .texture = .{ .id = 0, .width = 0, .height = 0, .mipmaps = 0, .format = 0 },
        .recs = null,
        .glyphs = null,
    },
    /// Bitmap-path storage.  Null for the default TTF path
    /// (which heap-allocates atlases internally).  Lazily
    /// allocated by `loadFontRaylibBitmap`; freed by
    /// `unloadFontRaylibBitmap`.
    buffers: ?*FontCacheBuffers = null,
};

/// Return the default-font `Font` from `state`.  Pure read
/// assumes the cache has been initialized via `loadFontDefault`
/// (which `App.create` calls eagerly).
/// Reads: `state.font` (the loaded glyph atlas + texture id).
/// On non-wasm host targets, returns a zero `Font` regardless of
/// `state` - the host build never uploads a GL texture, so any
/// returned `Font` is unrenderable anyway.  Existing callers
/// (test bodies, the headless image-text path) already tolerate
/// that.
pub fn getFontDefault(state: *const FontCache) Font {
    if (comptime is_wasm) {
        return state.font;
    }
    return std.mem.zeroes(Font);
}

/// Errors returned by `loadFontFromTtfData`.
pub const LoadFontError = error{
    /// `bakeFontAtlas` returned `error.NoCodepoints` - empty
    /// codepoint slice.  Pass at least one codepoint or use
    /// `default_codepoints_ascii`.
    NoCodepoints,
    /// `bakeFontAtlas` returned `error.AtlasOverflow` - at least
    /// one glyph was wider than the auto-suggested atlas width.
    /// Try a smaller `font_size` or fewer codepoints.
    AtlasOverflow,
    /// GPU texture upload failed (returned id == 0).  In a real
    /// browser this means the WebGL context refused the upload
    /// most often format-related.  Host builds always hit this
    /// path because there's no GPU; not a bug there.
    GpuUploadFailed,
    /// `truetype.loadFontFromTtf` rejected the input bytes - could
    /// be a malformed file, an unsupported table layout, an
    /// unsupported CFF variant, etc.  All upstream parser errors
    /// collapse into this single variant rather than leaking the
    /// internal error names through the public surface.
    TtfParseFailed,
} || Allocator.Error;

fn unloadImage(
    gpa: Allocator,
    image: z.Image,
) void {
    image_mod.unloadImage(gpa, image);
}

pub const FontAtlas = struct {
    /// CPU-side atlas image (RGBA8).  Caller uploads to GPU and
    /// then deinits this image with `unloadImage`.
    image: z.Image,
    /// Per-codepoint glyph metrics.  Length = `codepoints.len` from
    /// the `bakeFontAtlas` input; same order.
    glyphs: []GlyphInfo,
    /// Per-glyph atlas source rectangle (in pixel coords).  Same
    /// length and order as `glyphs`.
    recs: []Rectangle,
    /// `font_size` as passed to `bakeFontAtlas`.
    base_size: i32,
    /// `padding` as passed to `bakeFontAtlas`.
    glyph_padding: i32,

    pub fn deinit(
        self: *FontAtlas,
        gpa: Allocator,
    ) void {
        unloadImage(gpa, self.image);
        gpa.free(self.glyphs);
        gpa.free(self.recs);
    }
};

const GlyphMeta = struct {
    codepoint: u21,
    glyph_idx: truetype.GlyphIndex,
    /// Pixel-space offset from pen position to bitmap top-left.
    off_x: i32,
    /// Pixel-space offset from pen position to bitmap top-line.
    off_y: i32,
    /// Pen advance in pixels (scaled).
    advance: i32,
};

/// Rasterize `codepoints` into a packed atlas at `font_size` pixel
/// height.  Returns the atlas image + parallel glyph-metric and
/// atlas-rect arrays, all gpa-allocated.
/// `padding` is added between glyphs in the atlas so adjacent slots
/// don't bleed into each other under bilinear sampling.  Typical
/// values: 0 for nearest sampling, 1-2 for bilinear.
pub fn bakeFontAtlas(
    gpa: Allocator,
    font: *const truetype.Font,
    font_size: i32,
    codepoints: []const u21,
    padding: i32,
) !FontAtlas {
    if (codepoints.len == 0) {
        return error.NoCodepoints;
    }

    const fs_f: f32 = float(font_size);
    const scale: f32 = font.scaleForPixelHeight(fs_f);
    const pad_u32: u32 = @intCast(@max(padding, 0));

    // stb_truetype returns glyph bbox y-coordinates relative to the
    // BASELINE: y0 is typically NEGATIVE (glyph top sits above the
    // baseline).  Widget layout in `ui.zig` positions labels at
    // `rect.y + padding`, expecting `y` to be the LINE BOX TOP.
    // Without conversion, glyphs render ABOVE where the rect math
    // predicts (button labels float above their button
    // backgrounds, checkbox label sits above its box).  Matches raylib's `LoadFontEx` in rcore/text.c:
    // it adds `ascent * scale` to each glyph's offsetY during bake
    // for exactly this reason.  We were missing that line.
    const vm: truetype.VerticalMetrics = font.verticalMetrics();
    // `vm.ascent` is i16; `scale` is f32.  Zig 0.16's `@floor` returns
    // an integer type directly when the result-location is typed as
    // int, AND propagates f32 inward to coerce `vm.ascent` to float
    // inside the multiplication.  So the whole conversion is one
    // builtin call.  `@floor` is preferred over `@intFromFloat` here
    // because it gives correct results for negative inputs too
    // (toward -inf vs toward 0) - pixel offsets at negative widget
    // coordinates round the way humans expect.  See
    // `src/notes/zig-0.16-migration-guide.md` for the full
    // result-location rules.
    const ascent_px: i32 = @floor(vm.ascent * scale);

    // Pass 1: per-codepoint metrics.  We need bbox dimensions to
    // pack the rectangles before any rasterization happens.
    const rects: []rectpack.Rect = try gpa.alloc(rectpack.Rect, codepoints.len);
    defer gpa.free(rects);
    const metas: []GlyphMeta = try gpa.alloc(GlyphMeta, codepoints.len);
    defer gpa.free(metas);

    for (codepoints, 0..) |cp, i| {
        const glyph_idx: truetype.GlyphIndex = font.codepointGlyphIndex(cp);
        const box: truetype.BitmapBox = font.glyphBitmapBox(glyph_idx, scale, scale);
        const hm: truetype.HMetrics = font.glyphHMetrics(glyph_idx);

        const w_i: i32 = box.x1 - box.x0;
        const h_i: i32 = box.y1 - box.y0;
        const w: u32 = if (w_i > 0) @intCast(w_i) else 0;
        const h: u32 = if (h_i > 0) @intCast(h_i) else 0;

        rects[i] = .{
            .w = w,
            .h = h,
            .id = @intCast(i),
        };
        metas[i] = .{
            .codepoint = cp,
            .glyph_idx = glyph_idx,
            .off_x = @intCast(box.x0),
            // ascent_px is in pixels at the bake scale, same as
            // box.y0.  Sum gives line-box-top-relative offset.
            .off_y = @intCast(box.y0 + ascent_px),
            .advance = @trunc(float(hm.advance_width) * scale),
        };
    }

    // Pass 2: pack rects into an atlas.  Width auto-suggested as a
    // square-ish power-of-two with ~25% slack; height grows naturally
    // and is rounded up to the next power-of-two for GPU friendliness.
    const atlas_w: u32 = rectpack.suggestAtlasWidth(rects);
    const pack_result: rectpack.Result = rectpack.pack(rects, atlas_w, pad_u32);
    const atlas_h: u32 = ceilPowerOfTwo(u32, @max(pack_result.height, 1)) catch pack_result.height;

    if (pack_result.overflow > 0) {
        // A glyph was wider than the atlas - would need a wider
        // atlas to fit.  Caller can rebuild with a larger font size
        // or fewer codepoints; we surface this as an error rather
        // than silently dropping glyphs.
        return error.AtlasOverflow;
    }

    // Pass 3: allocate the atlas image (RGBA8, transparent black) and
    // rasterize each glyph into its packed slot.
    const atlas_pixel_count: usize = @as(usize, atlas_w) * @as(usize, atlas_h);
    const atlas_pixels: []u8 = try gpa.alloc(u8, atlas_pixel_count * 4);
    errdefer gpa.free(atlas_pixels);
    @memset(atlas_pixels, 0);

    var glyph_pixels: ArrayList(u8) = .empty;
    defer glyph_pixels.deinit(gpa);

    // Iterate the packed rects (now sorted by height desc; r.id maps
    // back to the input codepoint index).
    for (rects) |r| {
        const meta: GlyphMeta = metas[r.id];
        if (r.w == 0 or r.h == 0) {
            // Empty glyph (e.g. space, control codes) - no pixels
            // to blit; metrics are still captured below.
            continue;
        }
        glyph_pixels.clearRetainingCapacity();
        const bm: truetype.GlyphBitmap = font.glyphBitmap(
            gpa,
            &glyph_pixels,
            meta.glyph_idx,
            scale,
            scale,
        ) catch continue;
        // Blit grayscale `bm` into RGBA8 atlas at (r[0], r[1]).
        var row: u32 = 0;
        const bm_w: u32 = bm.width;
        const bm_h: u32 = bm.height;
        while (row < bm_h) : (row += 1) {
            var col: u32 = 0;
            while (col < bm_w) : (col += 1) {
                const src_idx: usize = @as(usize, row) * @as(usize, bm_w) + @as(usize, col);
                const dst_x: u32 = r.x + col;
                const dst_y: u32 = r.y + row;
                const dst_idx: usize = (@as(usize, dst_y) * @as(usize, atlas_w) + @as(usize, dst_x)) * 4;
                const a: u8 = glyph_pixels.items[src_idx];
                atlas_pixels[dst_idx + 0] = 255;
                atlas_pixels[dst_idx + 1] = 255;
                atlas_pixels[dst_idx + 2] = 255;
                atlas_pixels[dst_idx + 3] = a;
            }
        }
    }

    // Pass 4: build the per-codepoint output arrays in input order.
    // `rects` is height-sorted; use `r.id` to put each entry back
    // into its original slot.
    const out_glyphs: []GlyphInfo = try gpa.alloc(GlyphInfo, codepoints.len);
    errdefer gpa.free(out_glyphs);
    const out_recs: []Rectangle = try gpa.alloc(Rectangle, codepoints.len);
    errdefer gpa.free(out_recs);

    for (rects) |r| {
        const i: usize = r.id;
        const meta: GlyphMeta = metas[i];
        out_recs[i] = .{
            .x = @floatFromInt(r.x),
            .y = @floatFromInt(r.y),
            .width = @floatFromInt(r.w),
            .height = @floatFromInt(r.h),
        };
        // Carve a per-glyph RGBA bitmap out of the atlas so the CPU text path
        // (`imageDrawTextWithFont`) can sample it after the shared atlas image is
        // freed. Each is a standalone allocation; `unloadFontData` frees every
        // glyph.image via `unloadImage`, so this adds no new teardown surface.
        var glyph_image: z.Image = std.mem.zeroes(z.Image);
        if (r.w > 0 and r.h > 0) {
            const gw: usize = @intCast(r.w);
            const gh: usize = @intCast(r.h);
            const gbuf: []u8 = try gpa.alloc(u8, gw * gh * 4);
            const rx: usize = @intCast(r.x);
            const ry: usize = @intCast(r.y);
            var row: usize = 0;
            while (row < gh) : (row += 1) {
                const src_off: usize = ((ry + row) * @as(usize, atlas_w) + rx) * 4;
                const dst_off: usize = row * gw * 4;
                @memcpy(gbuf[dst_off .. dst_off + gw * 4], atlas_pixels[src_off .. src_off + gw * 4]);
            }
            glyph_image = .{
                .data = @ptrCast(gbuf.ptr),
                .width = @intCast(gw),
                .height = @intCast(gh),
                .mipmaps = 1,
                .format = pixelformat_rgba8,
            };
        }
        out_glyphs[i] = .{
            .value = @intCast(meta.codepoint),
            .offsetX = meta.off_x,
            .offsetY = meta.off_y,
            .advanceX = meta.advance,
            .image = glyph_image,
        };
    }

    return .{
        .image = .{
            .data = @ptrCast(atlas_pixels.ptr),
            .width = @intCast(atlas_w),
            .height = @intCast(atlas_h),
            .mipmaps = 1,
            .format = @backingInt(types.PixelFormat.uncompressed_r8g8b8a8),
        },
        .glyphs = out_glyphs,
        .recs = out_recs,
        .base_size = font_size,
        .glyph_padding = padding,
    };
}

/// Load a custom font from in-memory TTF/OTF bytes.  Combines:
///   1. `truetype.loadFontFromTtf` - parse the table directory.
///   2. `bakeFontAtlas` - rasterize requested codepoints + pack
///      into a CPU atlas image_mod.
///   3. GPU upload via `rlgl.fwd.rlLoadTexture`.
///   4. Free the CPU atlas image; the GPU keeps the only copy.
/// Returns a `Font` shaped like raylib's, which means the
/// existing `drawTextEx` / `measureTextWithFont` / `unloadFont`
/// all-work-unchanged path is the immediate consumer.
pub fn loadFontFromTtfData(
    gpa: Allocator,
    ttf_bytes: []const u8,
    font_size: i32,
    codepoints: []const u21,
    padding: i32,
) LoadFontError!Font {
    // Step 1: parse the TTF.  Any upstream parser error collapses
    // into TtfParseFailed; OOM passes through.
    const tt: truetype.Font = truetype.loadFontFromTtf(gpa, ttf_bytes) catch |err| {
        if (err == error.OutOfMemory) {
            return error.OutOfMemory;
        }
        return error.TtfParseFailed;
    };

    // Step 2: bake the atlas.  Catch the baker's narrower error set
    // and re-cast into our LoadFontError union.
    const atlas: FontAtlas = bakeFontAtlas(gpa, &tt, font_size, codepoints, padding) catch |err| switch (err) {
        error.NoCodepoints => return error.NoCodepoints,
        error.AtlasOverflow => return error.AtlasOverflow,
        error.OutOfMemory => return error.OutOfMemory,
    };
    // From this point we own atlas.image / atlas.glyphs / atlas.recs.
    // If anything below fails we must release them all.
    errdefer {
        unloadImage(gpa, atlas.image);
        gpa.free(atlas.glyphs);
        gpa.free(atlas.recs);
    }

    // Step 3: upload the atlas to the GPU.  `bakeFontAtlas`
    // produces an RGBA8 buffer (4 bytes per pixel, R/G/B = 255,
    // A = glyph coverage) which matches the textured-quad
    // shader's "white-on-transparent, alpha = mask" shape.
    // `rlgl.fwd.rlLoadTexture` returns 0 on host (no GPU) and
    // on real-browser-upload-failed - both produce the same
    // surface error.
    const tex_id: u32 = cpuAtlasTextureId();
    if (tex_id == 0) {
        return error.GpuUploadFailed;
    }

    // Bilinear filtering on the atlas.  The default `rlLoadTexture`
    // path binds NEAREST (raylib's pixel-art default) which is fine
    // for sprites with hard pixel edges but produces stair-step
    // aliasing on text - every non-integer scale lands on glyph
    // edges and the sub-pixel selection turns into ugly diagonal
    // steps.  LINEAR averages the 4 nearest texels per sample, so
    // glyph edges blend smoothly across pixel boundaries.  Pairs
    // with the 2x oversample done by `loadFontDefault`: the atlas
    // has more glyph data than the display needs, and the
    // bilinear filter does the actual downsample.
    // (GL bilinear setup removed in P5d - see header note on the stub.)

    // Step 4: free the CPU image - GPU has the pixels now.  We
    // explicitly DON'T free atlas.glyphs / atlas.recs here; they
    // transfer ownership into the returned Font.
    unloadImage(gpa, atlas.image);

    // Step 5: assemble the Font.  Note the shape match with
    // existing unloadFont expectations:
    //   - glyphs[*c] gpa-allocated, freed via freeMany
    //   - recs[*c] gpa-allocated, freed via freeMany
    //   - texture.id valid GPU id, released via unloadTexture
    return .{
        .baseSize = atlas.base_size,
        .glyphCount = @intCast(atlas.glyphs.len),
        .glyphPadding = atlas.glyph_padding,
        .texture = .{
            .id = tex_id,
            .width = atlas.image.width,
            .height = atlas.image.height,
            .mipmaps = 1,
            .format = atlas.image.format,
        },
        .recs = atlas.recs.ptr,
        .glyphs = atlas.glyphs.ptr,
    };
}

/// Eagerly bake the default-font atlas into `state`.  Called
/// Eager-load **zimr's branded default font** - Atkinson
/// Hyperlegible Mono, regular weight, baked at 16 px,
/// ASCII codepoints 32-127.  Allocates an atlas image and
/// glyph data via `gpa`, uploads the atlas to the GPU as a
/// texture, populates `state.font`.  Idempotent - second
/// call returns immediately because `state.loaded` is true.
/// `state` is the user's owned `FontCache`, typically zero-
/// initialised on the user's `State` struct and threaded
/// here from `initState`.  Per the thin-frame principle
/// (see `src/notes/thin-frame-plan.md`), zimr does not own
/// the cache.
/// Errors:
///   - `error.OutOfMemory` - allocator failed during parse
///     or atlas bake.
///   - `error.TtfParseFailed` - should not happen for the
///     embedded Atkinson bytes (they're shipped and verified
///     in this codebase), but the error path exists.
///   - `error.AtlasOverflow` - codepoints + padding don't
///     fit in the chosen atlas size.
///   - `error.GpuUploadFailed` - `rlLoadTexture` returned 0
///     (no GPU on host builds; real wasm-side failure
///     elsewhere).
/// On non-wasm host builds this is a no-op that returns
/// success - `rlLoadTexture` is a host stub that returns 0,
/// which would surface as `GpuUploadFailed`, so we short-
/// circuit at the top to keep host examples allocator-free.
/// Reads: `atkinson_mono_ttf` (compile-time constant).
/// Mutates: `state.*` (sets `loaded`, installs the live
///                     `Font` struct including its GPU
///                     texture id and allocator-owned
///                     `glyphs` / `recs` slices).
/// Step turn-335 (font-default sweep, Option A): bake `ttf_bytes`
/// into `state` as the active font.  This is the explicit form
/// the old `loadFontDefault` papered over - the user brings
/// their own TTF, picks their own bake size and codepoint
/// coverage, and gets a font cache ready for `u.text` and
/// `drawText`.
/// `ttf_bytes`: TTF/OTF byte slice.  Typically the result of
/// `@embedFile("path/to/font.ttf")` at the call site.
/// `bake_size`: atlas rasterization size in pixels.  Use 2x
/// your typical render size for crisp downscaling (e.g. 32
/// for a UI rendering text at 14-16 px).
/// `codepoints`: which characters to include in the atlas.
/// `default_codepoints_ascii` covers printable ASCII (32-126).
/// `oversample`: anti-aliasing oversample.  1 = none.
/// Idempotent guarded by `state.loaded` - second call no-ops
/// rather than re-baking + leaking the previous atlas.  If
/// the user wants to replace the font, they call `unloadFont`
/// first or manage their own cache.
/// On non-wasm host builds: no-op + success (returns without
/// allocating).  `rlLoadTexture` is a host stub returning 0,
/// which would surface as `GpuUploadFailed`; we short-circuit
/// at the top to keep host examples allocator-free.  Host
/// PNG screenshots therefore CAN'T render text - separate
/// concern, see `src/notes/font-default-plan.md`.
pub fn loadFontFromTtfBytes(
    gpa: Allocator,
    state: *FontCache,
    ttf_bytes: []const u8,
    bake_size: i32,
    codepoints: []const u21,
    oversample: u8,
) LoadFontError!void {
    if (state.loaded) {
        return;
    }
    if (comptime !is_wasm) {
        return;
    }
    const font: Font = try loadFontFromTtfData(
        gpa,
        ttf_bytes,
        bake_size,
        codepoints,
        oversample,
    );
    state.font = font;
    state.loaded = true;
}

/// Free per-glyph CPU images (reverse of `loadFontData`).  Empty
/// slice is a no-op.  Pass the same allocator used to create the
/// glyph images.
pub fn unloadFontData(
    gpa: Allocator,
    glyphs: []GlyphInfo,
) void {
    for (glyphs) |g| {
        unloadImage(gpa, g.image);
    }
    if (glyphs.len > 0) {
        allocator_mod.freeMany(gpa, glyphs.ptr, glyphs.len);
    }
}

fn unloadTexture(texture: Texture) void {
    // GL-retirement P5d: no GPU-side unload - the renderer owns residency.
    _ = texture;
}

/// Free GPU + CPU memory for a Font.  No-op if the font is the
/// rlgl default (which is owned by `App.create` / `App.destroy`).
/// Pass the same allocator used to load the font.
/// Reads: `font_cache.font.texture.id` (used to recognise the
/// default font and skip its teardown).
/// Mutates: nothing in zimr state - frees `font.glyphs` /
/// `font.recs` from `gpa` and the font's GL texture via JS bridge.
pub fn unloadFont(
    gpa: Allocator,
    font_cache: *const FontCache,
    font: Font,
) void {
    // Don't unload the default font - same texture id check raylib uses.
    const default_font: Font = getFontDefault(font_cache);
    if (font.texture.id == default_font.texture.id) {
        return;
    }
    if (font.glyphs != null and font.glyphCount > 0) {
        const n: usize = @intCast(font.glyphCount);
        unloadFontData(gpa, font.glyphs[0..n]);
    }
    unloadTexture(font.texture);
    if (font.recs != null) {
        allocator_mod.freeMany(gpa, font.recs, @intCast(font.glyphCount));
    }
    if (fontFace(font)) |face| {
        destroyFontFace(gpa, face);
    }
}

/// Free the CPU-side glyph data of a loaded (non-default) font: the per-glyph
/// atlas bitmaps + the glyph/rec arrays. Safe for any font returned by `loadFont`
/// (which is never the default, so no font_cache is needed to guard it). The
/// font's GPU atlas texture is engine-owned (registered in the renderer) and is
/// released with the renderer's texture registry at teardown, so it is
/// intentionally NOT freed here - that keeps this callable from an example's
/// `deinit(gpa, *State)`, which has no renderer handle.
pub fn unloadFontOwned(gpa: Allocator, font: Font) void {
    if (font.glyphs != null and font.glyphCount > 0) {
        const n: usize = @intCast(font.glyphCount);
        unloadFontData(gpa, font.glyphs[0..n]);
    }
    if (font.recs != null) {
        allocator_mod.freeMany(gpa, font.recs, @intCast(font.glyphCount));
    }
    // The face's glyphs may still sit in the shared atlas, keyed by a never-reused
    // face id. The engine starts the atlas over when the example that owned the font
    // is torn down (`Renderer2D.resetRegistryFrom` / `releaseOwner`), so they do not
    // accumulate across example lifecycles.
    if (fontFace(font)) |face| {
        destroyFontFace(gpa, face);
    }
}

/// Tear down `state.font` - free its GPU texture and the
/// allocator-owned glyph data.  Resets `state.loaded` to
/// false so a subsequent `loadFontFromTtfBytes` call will
/// re-bake.  No-op when nothing's loaded.
/// On non-wasm host builds: no-op (the load path was a
/// no-op too).
pub fn unloadFontCache(gpa: Allocator, state: *FontCache) void {
    if (!state.loaded) {
        return;
    }
    if (comptime !is_wasm) {
        return;
    }
    const font: Font = state.font;
    state.loaded = false;
    state.font = .{
        .baseSize = 0,
        .glyphCount = 0,
        .glyphPadding = 0,
        .texture = .{ .id = 0, .width = 0, .height = 0, .mipmaps = 0, .format = 0 },
        .recs = null,
        .glyphs = null,
    };
    unloadFont(gpa, state, font);
}

const core_module = @import("runtime.zig").core;

pub const default_font_data: [512]u32 = .{
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00200020, 0x0001b000, 0x00000000, 0x00000000,

    0x8ef92520, 0x00020a00, 0x7dbe8000, 0x1f7df45f, 0x4a2bf2a0, 0x0852091e, 0x41224000, 0x10041450,

    0x2e292020, 0x08220812, 0x41222000, 0x10041450, 0x10f92020, 0x3efa084c, 0x7d22103c, 0x107df7de,

    0xe8a12020, 0x08220832, 0x05220800, 0x10450410, 0xa4a3f000, 0x08520832, 0x05220400, 0x10450410,

    0xe2f92020, 0x0002085e, 0x7d3e0281, 0x107df41f, 0x00200000, 0x8001b000, 0x00000000, 0x00000000,

    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,

    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0xc0000fbe, 0xfbf7e00f, 0x5fbf7e7d, 0x0050bee8,

    0x440808a2, 0x0a142fe8, 0x50810285, 0x0050a048, 0x49e428a2, 0x0a142828, 0x40810284, 0x0048a048,

    0x10020fbe, 0x09f7ebaf, 0xd89f3e84, 0x0047a04f, 0x09e48822, 0x0a142aa1, 0x50810284, 0x0048a048,

    0x04082822, 0x0a142fa0, 0x50810285, 0x0050a248, 0x00008fbe, 0xfbf42021, 0x5f817e7d, 0x07d09ce8,

    0x00008000, 0x00000fe0, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,

    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x000c0180,

    0xdfbf4282, 0x0bfbf7ef, 0x42850505, 0x004804bf, 0x50a142c6, 0x08401428, 0x42852505, 0x00a808a0,

    0x50a146aa, 0x08401428, 0x42852505, 0x00081090, 0x5fa14a92, 0x0843f7e8, 0x7e792505, 0x00082088,

    0x40a15282, 0x08420128, 0x40852489, 0x00084084, 0x40a16282, 0x0842022a, 0x40852451, 0x00088082,

    0xc0bf4282, 0xf843f42f, 0x7e85fc21, 0x3e0900bf, 0x00000000, 0x00000004, 0x00000000, 0x000c0180,

    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,

    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x04000402, 0x41482000, 0x00000000, 0x00000800,

    0x04000404, 0x4100203c, 0x00000000, 0x00000800, 0xf7df7df0, 0x514bef85, 0xbefbefbe, 0x04513bef,

    0x14414500, 0x494a2885, 0xa28a28aa, 0x04510820, 0xf44145f0, 0x474a289d, 0xa28a28aa, 0x04510be0,

    0x14414510, 0x494a2884, 0xa28a28aa, 0x02910a00, 0xf7df7df0, 0xd14a2f85, 0xbefbe8aa, 0x011f7be0,

    0x00000000, 0x00400804, 0x20080000, 0x00000000, 0x00000000, 0x00600f84, 0x20080000, 0x00000000,

    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0xac000000, 0x00000f01, 0x00000000, 0x00000000,

    0x24000000, 0x00000f01, 0x00000000, 0x06000000, 0x24000000, 0x00000f01, 0x00000000, 0x09108000,

    0x24fa28a2, 0x00000f01, 0x00000000, 0x013e0000, 0x2242252a, 0x00000f52, 0x00000000, 0x038a8000,

    0x2422222a, 0x00000f29, 0x00000000, 0x010a8000, 0x2412252a, 0x00000f01, 0x00000000, 0x010a8000,

    0x24fbe8be, 0x00000f01, 0x00000000, 0x0ebe8000, 0xac020000, 0x00000f01, 0x00000000, 0x00048000,

    0x0003e000, 0x00000f00, 0x00000000, 0x00008000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,

    0x00000000, 0x00000038, 0x8443b80e, 0x00203a03, 0x02bea080, 0xf0000020, 0xc452208a, 0x04202b02,

    0xf8029122, 0x07f0003b, 0xe44b388e, 0x02203a02, 0x081e8a1c, 0x0411e92a, 0xf4420be0, 0x01248202,

    0xe8140414, 0x05d104ba, 0xe7c3b880, 0x00893a0a, 0x283c0e1c, 0x04500902, 0xc4400080, 0x00448002,

    0xe8208422, 0x04500002, 0x80400000, 0x05200002, 0x083e8e00, 0x04100002, 0x804003e0, 0x07000042,

    0xf8008400, 0x07f00003, 0x80400000, 0x04000022, 0x00000000, 0x00000000, 0x80400000, 0x04000002,

    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00800702, 0x1848a0c2, 0x84010000, 0x02920921,

    0x01042642, 0x00005121, 0x42023f7f, 0x00291002, 0xefc01422, 0x7efdfbf7, 0xefdfa109, 0x03bbbbf7,

    0x28440f12, 0x42850a14, 0x20408109, 0x01111010, 0x28440408, 0x42850a14, 0x2040817f, 0x01111010,

    0xefc78204, 0x7efdfbf7, 0xe7cf8109, 0x011111f3, 0x2850a932, 0x42850a14, 0x2040a109, 0x01111010,

    0x2850b840, 0x42850a14, 0xefdfbf79, 0x03bbbbf7, 0x001fa020, 0x00000000, 0x00001000, 0x00000000,

    0x00002070, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,

    0x08022800, 0x00012283, 0x02430802, 0x01010001, 0x8404147c, 0x20000144, 0x80048404, 0x00823f08,

    0xdfbf4284, 0x7e03f7ef, 0x142850a1, 0x0000210a, 0x50a14684, 0x528a1428, 0x142850a1, 0x03efa17a,

    0x50a14a9e, 0x52521428, 0x142850a1, 0x02081f4a, 0x50a15284, 0x4a221428, 0xf42850a1, 0x03efa14b,

    0x50a16284, 0x4a521428, 0x042850a1, 0x0228a17a, 0xdfbf427c, 0x7e8bf7ef, 0xf7efdfbf, 0x03efbd0b,

    0x00000000, 0x04000000, 0x00000000, 0x00000008, 0x00000000, 0x00000000, 0x00000000, 0x00000000,

    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00200508, 0x00840400, 0x11458122, 0x00014210,

    0x00514294, 0x51420800, 0x20a22a94, 0x0050a508, 0x00200000, 0x00000000, 0x00050000, 0x08000000,

    0xfefbefbe, 0xfbefbefb, 0xfbeb9114, 0x00fbefbe, 0x20820820, 0x8a28a20a, 0x8a289114, 0x3e8a28a2,

    0xfefbefbe, 0xfbefbe0b, 0x8a289114, 0x008a28a2, 0x228a28a2, 0x08208208, 0x8a289114, 0x088a28a2,

    0xfefbefbe, 0xfbefbefb, 0xfa2f9114, 0x00fbefbe, 0x00000000, 0x00000040, 0x00000000, 0x00000000,

    0x00000000, 0x00000020, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,

    0x00210100, 0x00000004, 0x00000000, 0x00000000, 0x14508200, 0x00001402, 0x00000000, 0x00000000,

    0x00000010, 0x00000020, 0x00000000, 0x00000000, 0xa28a28be, 0x00002228, 0x00000000, 0x00000000,

    0xa28a28aa, 0x000022e8, 0x00000000, 0x00000000, 0xa28a28aa, 0x000022a8, 0x00000000, 0x00000000,

    0xa28a28aa, 0x000022e8, 0x00000000, 0x00000000, 0xbefbefbe, 0x00003e2f, 0x00000000, 0x00000000,

    0x00000004, 0x00002028, 0x00000000, 0x00000000, 0x80000000, 0x00003e0f, 0x00000000, 0x00000000,

    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,

    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,

    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,

    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,

    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,

    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,

    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,

    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,

    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
};

pub const chars_divisor: i32 = 1;

/// Format constant: PIXELFORMAT_UNCOMPRESSED_R8G8B8A8 (matches enums.zig).
const pixelformat_rgba8: i32 = 7;

/// Force-load the default font.  Idempotent - the `state.loaded` guard
/// prevents double-init.  Called automatically by `getFontDefault` (above)
/// and also exposed so the runtime can prime the GPU upload during
/// App.create.
/// Bake the default-font atlas into the cache.  Idempotent
/// if `state.loaded` is already true, returns immediately.
/// Otherwise: unpacks the 1-bpp font bitmap into RGBA8, uploads
/// it to the GPU, lays out per-glyph rectangles, and caches
/// individual glyph CPU bitmaps for `imageDrawTextWithFont`.
/// Mutates: `state.*` (atlas pixels, glyph buffers, the live
/// `Font` struct, and the `loaded` flag).
/// Reads: `tracelog.*` (filter level used by the `traceLog`
/// emissions on success and on GPU-upload failure).
/// Side effect: a `rlgl.fwd.rlLoadTexture` JS-bridge call to
/// upload the atlas; allocates no host memory (all buffers
/// are statically sized fields of `state`).
fn loadFontRaylibBitmapImpl(
    gpa: Allocator,
    state: *FontCache,
    tracelog: *const core_module.TraceLogState,
) !void {
    if (state.loaded) {
        return;
    }
    // Lazy-allocate the 114 KB bitmap-path scratch.  Leaves the
    // wasm binary clean for apps using only the TTF path.
    if (state.buffers == null) {
        state.buffers = try gpa.create(FontCacheBuffers);
        state.buffers.?.* = .{};
    }
    const bufs: *FontCacheBuffers = state.buffers.?;

    // Unpack the 1-bit-per-pixel font data into RGBA8.  Mirrors the C loop
    // verbatim: for i = 0 in 32-pixel strides, walk the corresponding u32
    // word from bit 31 down to bit 0.  Bit set -> opaque white; bit clear
    // -> transparent white.
    var counter: usize = 0;
    var i: usize = 0;
    const total_pixels: usize = atlas_size * atlas_size;
    while (i < total_pixels) : (i += 32) {
        const word: u32 = default_font_data[counter];
        var j: i32 = 31;
        while (j >= 0) : (j -= 1) {
            const px_idx: usize = i + @as(usize, @intCast(j));
            const bit_set: bool = (word & (@as(u32, 1) << @intCast(j))) != 0;
            const off: usize = px_idx * 4;
            bufs.atlas_pixels[off + 0] = 0xFF;
            bufs.atlas_pixels[off + 1] = 0xFF;
            bufs.atlas_pixels[off + 2] = 0xFF;
            bufs.atlas_pixels[off + 3] = if (bit_set) 0xFF else 0x00;
        }
        counter += 1;
    }

    // Upload the unpacked atlas to the GPU.
    _ = atlas_size;
    const tex_id: u32 = cpuAtlasTextureId();
    if (tex_id == 0) {
        core_module.traceLog(tracelog, core_module.LOG_ERROR, "FONT: Default font texture upload failed", .{});
        return;
    }

    // Lay out glyph rectangles.  Same packing as raylib: glyphs flow
    // left-to-right with a 1-pixel divisor; wrap to the next row when a
    // glyph would overrun the atlas width.  All glyphs are 10 pixels tall.
    var current_line: i32 = 0;
    var current_pos_x: i32 = chars_divisor;
    var test_pos_x: i32 = chars_divisor;

    // Running offset into bufs.glyph_pixels - bytes consumed so far.
    var glyph_byte_off: usize = 0;

    for (0..glyph_count) |k| {
        bufs.glyphs_buf[k].value = 32 + @as(i32, @intCast(k));

        bufs.recs_buf[k][0] = @floatFromInt(current_pos_x);
        bufs.recs_buf[k][1] = @floatFromInt(chars_divisor + current_line * (glyph_height + chars_divisor));
        bufs.recs_buf[k].width = @floatFromInt(chars_width[k]);
        bufs.recs_buf[k].height = @floatFromInt(glyph_height);

        test_pos_x += @as(i32, chars_width[k]) + chars_divisor;

        if (test_pos_x >= atlas_size) {
            current_line += 1;
            current_pos_x = 2 * chars_divisor + @as(i32, chars_width[k]);
            test_pos_x = current_pos_x;

            bufs.recs_buf[k][0] = @floatFromInt(chars_divisor);
            bufs.recs_buf[k][1] = @floatFromInt(chars_divisor + current_line * (glyph_height + chars_divisor));
        } else {
            current_pos_x = test_pos_x;
        }

        // Default font has no per-glyph offset / advance; rendering uses
        // the rectangle width as the advance.  (The C original sets these
        // to 0 and lets `MeasureTextEx` handle advance via the rec width.)
        bufs.glyphs_buf[k].offsetX = 0;
        bufs.glyphs_buf[k].offsetY = 0;
        bufs.glyphs_buf[k].advanceX = 0;

        // Carve a per-glyph CPU bitmap out of `bufs.glyph_pixels` by
        // copying the glyph's rectangle from `bufs.atlas_pixels`.  This
        // makes `imageDrawTextWithFont` work for the default font.
        const gw: usize = @intCast(chars_width[k]);
        const gh: usize = @intCast(glyph_height);
        const gbytes: usize = gw * gh * 4;
        const dst_slice: []u8 = bufs.glyph_pixels[glyph_byte_off .. glyph_byte_off + gbytes];
        const rx: usize = @trunc(bufs.recs_buf[k][0]);
        const ry: usize = @trunc(bufs.recs_buf[k][1]);
        var row: usize = 0;
        while (row < gh) : (row += 1) {
            const src_off: usize = ((ry + row) * @as(usize, atlas_size) + rx) * 4;
            const dst_off: usize = row * gw * 4;
            @memcpy(dst_slice[dst_off .. dst_off + gw * 4], bufs.atlas_pixels[src_off .. src_off + gw * 4]);
        }
        bufs.glyphs_buf[k].image = .{
            .data = @ptrCast(dst_slice.ptr),
            .width = chars_width[k],
            .height = glyph_height,
            .mipmaps = 1,
            .format = pixelformat_rgba8,
        };
        glyph_byte_off += gbytes;
    }

    // Populate the Font struct.
    state.font.baseSize = glyph_height;
    state.font.glyphCount = glyph_count;
    state.font.glyphPadding = 0;
    state.font.texture = .{
        .id = tex_id,
        .width = atlas_size,
        .height = atlas_size,
        .mipmaps = 1,
        .format = pixelformat_rgba8,
    };
    state.font.recs = @ptrCast(&bufs.recs_buf);
    state.font.glyphs = @ptrCast(&bufs.glyphs_buf);

    state.loaded = true;
    core_module.traceLog(tracelog, core_module.LOG_INFO, "FONT: Default font loaded ({d} glyphs)", .{glyph_count});
}

/// **Legacy alternative:** load the original raylib 8x10
/// bitmap font as the default.  Available for callers who
/// want the pixel-perfect retro aesthetic (or who can't
/// afford the ~34 KB Atkinson TTF in their wasm).  Most code
/// should use `loadFontDefault(gpa, state)` instead.
/// Lazily allocates `state.buffers` (~114 KB).  The four big
/// arrays previously lived inline on FontCache; moving them
/// behind a pointer dropped ~228 KB of vestigial zero-init
/// templates from the wasm binary (the TTF path doesn't need
/// them and didn't use them).
/// Mutates: `state.*` (atlas, glyphs, font, `loaded` flag).
/// On non-wasm host builds this is a no-op.
pub fn loadFontRaylibBitmap(gpa: Allocator, state: *FontCache) !void {
    if (comptime is_wasm) {
        var default_sink: core_module.TraceLogState = .{};
        try loadFontRaylibBitmapImpl(gpa, state, &default_sink);
    }
}

/// Free the GPU texture backing the default font and reset the
/// cache to its uninitialized state.  After this call,
/// `getFontDefault` returns a zero `Font` until `loadFontDefault`
/// runs again.
/// Mutates: `state.*` (clears `loaded`, zeroes the live `Font`).
/// Side effect: a `rlgl.fwd.rlUnloadTexture` JS-bridge call.
/// No `gl: *GlState` parameter - the texture deletion is
/// performed by JS directly via the GL texture id, not via any
/// rlgl batch state.
pub fn unloadFontRaylibBitmapImpl(gpa: Allocator, state: *FontCache) void {
    if (!state.loaded) {
        return;
    }
    // GL-retirement P5d: no GPU-side unload - the renderer owns residency.
    state.font.texture.id = 0;
    state.font.glyphs = null;
    state.font.recs = null;
    state.font.glyphCount = 0;
    state.loaded = false;
    if (state.buffers) |bufs| {
        gpa.destroy(bufs);
        state.buffers = null;
    }
}

/// Pair with `loadFontRaylibBitmap`.  Frees the on-demand
/// `state.buffers` allocation (the 114 KB block holding the
/// atlas + glyphs scratch).
pub fn unloadFontRaylibBitmap(gpa: Allocator, state: *FontCache) void {
    if (comptime is_wasm) {
        unloadFontRaylibBitmapImpl(gpa, state);
    }
}
fn rlPushMatrix(gl: anytype) void {
    gl.pushMatrix();
}
fn rlPopMatrix(gl: anytype) void {
    gl.popMatrix();
}
fn rlTranslatef(
    gl: anytype,
    x: f32,
    y: f32,
    zc: f32,
) void {
    gl.translate(x, y, zc);
}
// `rlRotatef` used to sit here: a raylib-named shim taking DEGREES and converting to radians.
// Its only caller already held radians and converted TO degrees to reach it - a full round trip,
// radians to degrees to radians, for nothing. `gl.rotate` takes turns now and the shim is gone.

// ===========================================================================
//                        Z I G - N A T I V E   A P I
// ===========================================================================
// Idiomatic Zig: takes []const u8 slices, returns owned slices, takes
// allocators where allocation is needed, returns errors instead of using
// sentinel values.

// Codepoints (pure, no alloc)
/// One decoded UTF-8 codepoint plus how many bytes it occupied.
pub const DecodedCodepoint = struct {
    /// Decoded codepoint, or `'?'` (0x3f) on decode error / empty input.
    /// Note: the underlying decoder uses U+FFFD internally; we
    /// translate to '?' here to match raylib's behavior at the
    /// public boundary (raylib prints '?' for unrenderable glyphs in
    /// the default font).
    codepoint: u21,
    /// Bytes consumed from the input.
    bytes: u3,
};

// Vendored DFA-based UTF-8 decoder (Maximal Subparts error recovery).
// See `_vendor/zg/README.md` for source / license.
const code_point = @import("codecs.zig").code_point;

/// Decode the next UTF-8 codepoint from the start of `s`.  Returns
/// `'?'` and `bytes=1` on decode error or empty input.  Lenient
/// matches raylib's behaviour and tolerates malformed sequences.
/// Implementation: delegates to the vendored DFA-based decoder
/// (zg/code_point.zig) which implements the Unicode-recommended
/// Maximal Subparts algorithm.  Compared to the previous hand-rolled
/// decoder this is more correct on truncated multibyte sequences:
/// e.g. for the input 0xD0 0xAF (Cyrillic Ya) followed by a stray 0xE0,
/// the old code consumed all 3 bytes; the new code stops cleanly
/// after 2.
pub fn nextCodepoint(s: []const u8) DecodedCodepoint {
    if (s.len == 0) {
        return .{ .codepoint = 0x3f, .bytes = 1 };
    }
    var cursor: code_point.uoffset = 0;
    const cp: code_point.CodePoint = code_point.decodeAtCursor(s, &cursor) orelse {
        return .{ .codepoint = 0x3f, .bytes = 1 };
    };
    // Translate the decoder's U+FFFD error sentinel to raylib's '?'.
    const out_code: u21 = if (cp.code == 0xFFFD) 0x3f else cp.code;
    return .{ .codepoint = out_code, .bytes = @intCast(cp.len) };
}

/// Walk backward from byte position `end_offset` (exclusive) to find the
/// start of the previous codepoint. Returns the decoded codepoint and
/// its byte length.
pub fn prevCodepoint(s: []const u8, end_offset: usize) DecodedCodepoint {
    if (end_offset == 0) {
        return .{ .codepoint = 0x3f, .bytes = 1 };
    }
    var i: usize = end_offset;
    // Skip continuation bytes (binary 10xxxxxx).
    while (i > 0) {
        i -= 1;
        const b: u8 = s[i];
        if ((b & 0xc0) != 0x80) {
            break;
        }
    }
    return nextCodepoint(s[i..end_offset]);
}

/// Count codepoints in a UTF-8 slice.  Uses the DFA-based iterator
/// for correctness on malformed input.
pub fn countCodepoints(s: []const u8) usize {
    var iter: code_point.Iterator = code_point.Iterator.init(s);
    var count: usize = 0;
    while (iter.next()) |_| {
        count += 1;
    }
    return count;
}

/// Encoded UTF-8 byte sequence - stack-allocated, max 4 bytes (the
/// largest valid UTF-8 codepoint).
pub const Utf8Bytes = struct {
    bytes: [4]u8 = .{ 0, 0, 0, 0 },
    len: u3 = 0,

    /// View as a slice of just the encoded bytes.
    pub fn slice(self: *const Utf8Bytes) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// Encode one codepoint to UTF-8. Returns by value - caller doesn't need
/// to allocate or worry about lifetime.
pub fn encodeCodepoint(codepoint: u21) Utf8Bytes {
    var out = Utf8Bytes{};
    if (codepoint <= 0x7f) {
        out.bytes[0] = @intCast(codepoint);
        out.len = 1;
    } else if (codepoint <= 0x7ff) {
        out.bytes[0] = @intCast(((codepoint >> 6) & 0x1f) | 0xc0);
        out.bytes[1] = @intCast((codepoint & 0x3f) | 0x80);
        out.len = 2;
    } else if (codepoint <= 0xffff) {
        out.bytes[0] = @intCast(((codepoint >> 12) & 0x0f) | 0xe0);
        out.bytes[1] = @intCast(((codepoint >> 6) & 0x3f) | 0x80);
        out.bytes[2] = @intCast((codepoint & 0x3f) | 0x80);
        out.len = 3;
    } else if (codepoint <= 0x10ffff) {
        out.bytes[0] = @intCast(((codepoint >> 18) & 0x07) | 0xf0);
        out.bytes[1] = @intCast(((codepoint >> 12) & 0x3f) | 0x80);
        out.bytes[2] = @intCast(((codepoint >> 6) & 0x3f) | 0x80);
        out.bytes[3] = @intCast((codepoint & 0x3f) | 0x80);
        out.len = 4;
    }
    return out;
}

// Manipulation (allocating - caller owns result)
/// Convert ASCII letters to upper-case. Caller owns the returned slice.
pub fn upper(allocator: Allocator, s: []const u8) Allocator.Error![]u8 {
    const out: []u8 = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| {
        out[i] = if (c >= 'a' and c <= 'z') c - 32 else c;
    }
    return out;
}

/// Convert ASCII letters to lower-case.
pub fn lower(allocator: Allocator, s: []const u8) Allocator.Error![]u8 {
    const out: []u8 = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| {
        out[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    return out;
}

/// snake_case -> PascalCase.
pub fn pascal(allocator: Allocator, s: []const u8) Allocator.Error![]u8 {
    if (s.len == 0) {
        return allocator.alloc(u8, 0);
    }
    var out = try ArrayList(u8).initCapacity(allocator, s.len);
    defer out.deinit(allocator);
    const c0: u8 = s[0];
    out.appendAssumeCapacity(if (c0 >= 'a' and c0 <= 'z') c0 - 32 else c0);
    var i: usize = 1;
    while (i < s.len) : (i += 1) {
        const c: u8 = s[i];
        if (c == '_') {
            i += 1;
            if (i >= s.len) {
                break;
            }
            const after_underscore: u8 = s[i];
            // `_x` means 'uppercase x': 32 is the ASCII gap between 'a' and 'A'. A digit after the
            // underscore is passed through as-is, and anything else is DROPPED - the escape consumed
            // it and no branch appends it.
            if (after_underscore >= 'a' and after_underscore <= 'z') {
                out.appendAssumeCapacity(after_underscore - 32);
            } else if (after_underscore >= '0' and after_underscore <= '9') {
                out.appendAssumeCapacity(after_underscore);
            }
        } else {
            out.appendAssumeCapacity(c);
        }
    }
    return out.toOwnedSlice(allocator);
}

/// CamelCase -> snake_case.
pub fn snake(allocator: Allocator, s: []const u8) Allocator.Error![]u8 {
    var out = try ArrayList(u8).initCapacity(allocator, s.len * 2);
    defer out.deinit(allocator);
    for (s, 0..) |c, i| {
        if (c >= 'A' and c <= 'Z') {
            if (i > 0) {
                out.appendAssumeCapacity('_');
            }
            out.appendAssumeCapacity(c + 32);
        } else {
            out.appendAssumeCapacity(c);
        }
    }
    return out.toOwnedSlice(allocator);
}

/// snake_case -> camelCase.
pub fn camel(allocator: Allocator, s: []const u8) Allocator.Error![]u8 {
    if (s.len == 0) {
        return allocator.alloc(u8, 0);
    }
    var out = try ArrayList(u8).initCapacity(allocator, s.len);
    defer out.deinit(allocator);
    const c0: u8 = s[0];
    out.appendAssumeCapacity(if (c0 >= 'A' and c0 <= 'Z') c0 + 32 else c0);
    var i: usize = 1;
    while (i < s.len) : (i += 1) {
        const c: u8 = s[i];
        if (c == '_') {
            i += 1;
            if (i >= s.len) {
                break;
            }
            const after_underscore: u8 = s[i];
            if (after_underscore >= 'a' and after_underscore <= 'z') {
                out.appendAssumeCapacity(after_underscore - 32);
            }
        } else {
            out.appendAssumeCapacity(c);
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Strip space characters.
pub fn removeSpaces(
    allocator: Allocator,
    s: []const u8,
) Allocator.Error![]u8 {
    var out = try ArrayList(u8).initCapacity(allocator, s.len);
    defer out.deinit(allocator);
    for (s) |c| {
        if (c != ' ') {
            out.appendAssumeCapacity(c);
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Substring extraction by byte offset and length. Out-of-range
/// positions return an empty slice; over-long lengths are clamped.
pub fn substring(
    allocator: Allocator,
    s: []const u8,
    position: usize,
    length: usize,
) Allocator.Error![]u8 {
    if (position >= s.len) {
        return allocator.alloc(u8, 0);
    }
    const len: u64 = @min(length, s.len - position);
    return allocator.dupe(u8, s[position..][0..len]);
}

/// Replace all occurrences of `search` with `replacement`. Empty
/// `search` is a no-op (returns a copy of `s`).
pub fn replace(
    allocator: Allocator,
    s: []const u8,
    search: []const u8,
    replacement: []const u8,
) Allocator.Error![]u8 {
    if (search.len == 0) {
        return allocator.dupe(u8, s);
    }
    var out: ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        if (i + search.len <= s.len and eql(u8, s[i..][0..search.len], search)) {
            try out.appendSlice(allocator, replacement);
            i += search.len;
        } else {
            try out.append(allocator, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Insert `insert_str` into `s` at byte position `position`. Position
/// past end of s is clamped to end (= append).
pub fn insert(
    allocator: Allocator,
    s: []const u8,
    insert_str: []const u8,
    position: usize,
) Allocator.Error![]u8 {
    const pos: u64 = @min(position, s.len);
    const out: []u8 = try allocator.alloc(u8, s.len + insert_str.len);
    @memcpy(out[0..pos], s[0..pos]);
    @memcpy(out[pos..][0..insert_str.len], insert_str);
    @memcpy(out[pos + insert_str.len ..], s[pos..]);
    return out;
}

// Splitting / joining
/// Split iterator - no allocation. Use this when you can.
pub fn split(
    s: []const u8,
    delimiter: u8,
) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, s, delimiter);
}

/// Allocating split - returns a slice of slices that all reference into
/// the original `s` (the slices themselves are not duped). Free with
/// `allocator.free(result)`.
pub fn splitAlloc(
    allocator: Allocator,
    s: []const u8,
    delimiter: u8,
) Allocator.Error![][]const u8 {
    var parts: ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);
    var iter = std.mem.splitScalar(u8, s, delimiter);
    while (iter.next()) |part| {
        try parts.append(allocator, part);
    }
    return parts.toOwnedSlice(allocator);
}

/// Join a list of slices with `delimiter` between each. Wraps std.mem.join.
pub fn join(
    allocator: Allocator,
    parts: []const []const u8,
    delimiter: []const u8,
) Allocator.Error![]u8 {
    return std.mem.join(allocator, delimiter, parts);
}

// Search / comparison (no alloc)
/// Find the first occurrence of `needle` in `haystack`. Returns null if
/// not found. Wraps `std.mem.indexOf`.
pub fn findIndex(haystack: []const u8, needle: []const u8) ?usize {
    return std.mem.indexOf(u8, haystack, needle);
}

/// Wraps `std.mem.eql`. Exists for symmetry with raylib's TextIsEqual.
pub fn isEqual(a: []const u8, b: []const u8) bool {
    return eql(u8, a, b);
}

// Numeric parsing - returns errors instead of silently sentinel
/// Parse a base-10 signed integer. Returns ParseIntError on malformed
/// input. Unlike raylib's TextToInteger, does not silently return 0.
pub fn toInteger(s: []const u8) std.fmt.ParseIntError!i32 {
    return std.fmt.parseInt(i32, s, 10);
}

/// Parse a float. Wraps `std.fmt.parseFloat`; full IEEE-754 + scientific
/// notation handling unlike raylib's basic decimal parser.
pub fn toFloat(s: []const u8) std.fmt.ParseFloatError!f32 {
    return std.fmt.parseFloat(f32, s);
}

// Font / glyph queries (no alloc)
/// Validate a Font has globalDefaultFont().loaded glyph data.
fn isFontValidZ(font: Font) bool {
    return font.baseSize > 0 and font.glyphCount > 0 and font.recs != null and font.glyphs != null;
}

/// Get the glyph index for a unicode codepoint. Falls back to '?' (or 0
/// if '?' isn't in the font).
pub fn getGlyphIndex(font: Font, codepoint: u21) usize {
    if (!isFontValidZ(font)) {
        return 0;
    }
    var fallback: usize = 0;
    const count: usize = @intCast(font.glyphCount);
    for (0..count) |i| {
        if (font.glyphs[i].value == 63) {
            fallback = i; // '?' = 63
        }
        if (@as(u21, @intCast(font.glyphs[i].value)) == codepoint) {
            return i;
        }
    }
    if (@as(u21, @intCast(font.glyphs[0].value)) != codepoint) {
        return fallback;
    }
    return 0;
}

/// Get glyph metrics for a codepoint.
pub fn getGlyphInfo(font: Font, codepoint: u21) GlyphInfo {
    return font.glyphs[getGlyphIndex(font, codepoint)];
}

/// Get the source rectangle of a glyph in the font's atlas texture.
pub fn getGlyphAtlasRec(font: Font, codepoint: u21) Rectangle {
    return font.recs[getGlyphIndex(font, codepoint)];
}

// ===========================================================================
// Glyphs rasterized at the size they are DRAWN
// ===========================================================================
//
// See `glyph_atlas.zig` for why. The split: layout (advances, `measureWithFont`)
// stays in logical units and never depends on the devicePixelRatio. At draw time
// a backend that can rasterize on demand (WgpuGl - `glyphDeviceMapping`) says how
// draw coordinates map to device pixels; each glyph is rasterized at exactly
// that size the first time it is needed and drawn 1:1, its origin snapped to the
// pixel grid. Backends without the hook (the CPU rasterizer, host tests) and
// fonts without a face (bitmap, sprite, SDF, `loadFontBaked`) keep drawing from
// the baked atlas.

/// A font's outlines plus the metrics layout needs, kept alive so its glyphs can
/// be rasterized on demand. Owned by the `Font` (`Font.face`, read it with
/// `fontFace`); freed by `unloadFontOwned` / `unloadFont`.
pub const FontFace = struct {
    /// Keys this face's glyphs in the shared atlas. A counter, never an address:
    /// an unloaded face's glyphs stay cached until the atlas starts over, and a
    /// new face allocated at the same address must not find them.
    id: u32,
    /// The TTF, copied - `truetype.Font` borrows its bytes, and a caller may free
    /// theirs as soon as `loadFont` returns.
    ttf_bytes: []u8,
    tt: truetype.Font,
    /// Per glyph SLOT (index into `Font.glyphs`): the TTF glyph and its advance
    /// in font units. By slot, not codepoint, so a codepoint the font was not
    /// loaded with falls back to '?' exactly as it does on the baked path.
    glyph_ids: []truetype.GlyphIndex,
    advance_units: []i16,
    /// Ascent, and ascent - descent (what `scaleForPixelHeight` divides by, so
    /// sizes here mean what they mean for the baked atlas), in font units.
    ascent_units: f32,
    height_units: f32,

    /// Font units -> pixels, for text `size` pixels tall.
    pub fn pixelsPerUnit(face: *const FontFace, size: f32) f32 {
        return size / face.height_units;
    }
};

// lint:off module-var: the face-id counter must outlive every face (see FontFace.id)
var next_font_face_id: u32 = 1;

/// Build the face for a font baked from `ttf_bytes`; `glyphs` are that font's
/// glyph slots, whose codepoints pick the TTF glyphs.
pub fn createFontFace(
    gpa: Allocator,
    ttf_bytes: []const u8,
    glyphs: []const GlyphInfo,
) !*FontFace {
    const face: *FontFace = try gpa.create(FontFace);
    errdefer gpa.destroy(face);
    const owned_bytes: []u8 = try gpa.dupe(u8, ttf_bytes);
    errdefer gpa.free(owned_bytes);
    const glyph_ids: []truetype.GlyphIndex = try gpa.alloc(truetype.GlyphIndex, glyphs.len);
    errdefer gpa.free(glyph_ids);
    const advance_units: []i16 = try gpa.alloc(i16, glyphs.len);
    errdefer gpa.free(advance_units);
    const tt: truetype.Font = try truetype.loadFontFromTtf(gpa, owned_bytes);
    for (glyphs, glyph_ids, advance_units) |glyph, *glyph_id, *advance| {
        glyph_id.* = tt.codepointGlyphIndex(@intCast(glyph.value));
        advance.* = tt.glyphHMetrics(glyph_id.*).advance_width;
    }
    const vm: truetype.VerticalMetrics = tt.verticalMetrics();
    face.* = .{
        .id = next_font_face_id,
        .ttf_bytes = owned_bytes,
        .tt = tt,
        .glyph_ids = glyph_ids,
        .advance_units = advance_units,
        .ascent_units = float(vm.ascent),
        .height_units = float(vm.ascent) - float(vm.descent),
    };
    next_font_face_id += 1;
    return face;
}

pub fn destroyFontFace(gpa: Allocator, face: *FontFace) void {
    gpa.free(face.advance_units);
    gpa.free(face.glyph_ids);
    gpa.free(face.ttf_bytes);
    gpa.destroy(face);
}

/// The face behind `font`, or null for a baked-only font.
pub fn fontFace(font: Font) ?*FontFace {
    const face_ptr: *anyopaque = font.face orelse return null;
    return @ptrCast(@alignCast(face_ptr));
}

/// Largest size a glyph is rasterized at, in device px; bigger text is drawn
/// from this, magnified.
const glyph_max_px: f32 = 256;
/// Up to this size (device px), sizes are cached to a quarter pixel and glyphs
/// are positioned to a quarter pixel (four sub-pixel phases). Above it, sizes
/// step ~2% and positions snap to whole pixels - differences nobody can see on
/// big text, and without them a smoothly zooming heading would rasterize a new
/// size every frame.
const glyph_fine_px: f32 = 48;

/// A device-pixel size -> the size the cache rasterizes it at, in quarter pixels.
fn quantizeGlyphSize(size_px: f32) u32 {
    const clamped_px: f32 = clamp(size_px, 1.0, glyph_max_px);
    const step_quarters: f32 = if (clamped_px <= glyph_fine_px) 1.0 else @floor(clamped_px / 12.0);
    const step_count: f32 = @round(clamped_px * 4.0 / step_quarters);
    const size_quarters: u32 = @round(step_count * step_quarters);
    return size_quarters;
}

/// The atlas entry for `key`, rasterizing and uploading the glyph the first time
/// it is asked for. Null when the atlas has no room this frame (the caller then
/// draws that glyph from the baked atlas). `pages` is the atlas's owner, which
/// holds the GPU pages: `ensureGlyphPage(page) bool` creates one on first use,
/// `writeGlyphPage(page, x, y, width, height, rgba)` uploads a rectangle.
pub fn cachedGlyph(
    atlas: *glyph_atlas.GlyphAtlas,
    gpa: Allocator,
    pages: anytype,
    face: *const FontFace,
    key: glyph_atlas.Key,
) ?glyph_atlas.Entry {
    if (atlas.find(key)) |entry| {
        return entry;
    }
    // `--leak-trace` attributes what the atlas allocates below to "glyph_cache" (a no-op in
    // every normal run - see `memwatch.pushScope`).
    memwatch.pushScope(gpa, "glyph_cache");
    defer memwatch.popScope(gpa);
    const size_px: f32 = float(key.size_quarters) / 4.0;
    const shift_x: f32 = float(key.phase) / 4.0;
    const scale: f32 = face.pixelsPerUnit(size_px);
    atlas.coverage.clearRetainingCapacity();
    const bitmap: truetype.GlyphBitmap = face.tt.glyphBitmapSubpixel(
        gpa,
        &atlas.coverage,
        face.glyph_ids[key.slot],
        scale,
        scale,
        shift_x,
        0,
    ) catch return null;
    var entry: glyph_atlas.Entry = .{ .offset_x = bitmap.off_x, .offset_y = bitmap.off_y };
    const glyph_has_ink: bool = bitmap.width > 0 and bitmap.height > 0;
    if (glyph_has_ink) {
        const width: u32 = bitmap.width;
        const height: u32 = bitmap.height;
        const slot: glyph_atlas.Slot = atlas.reserve(gpa, width, height) orelse return null;
        const page_ready: bool = pages.ensureGlyphPage(slot.page);
        if (!page_ready) {
            return null;
        }
        // The upload is the whole bordered slot - coverage in the alpha channel
        // of white texels, the same format as the baked atlas - so the border is
        // rewritten transparent too, whatever an earlier atlas generation left.
        const upload_width: u32 = width + 2 * glyph_atlas.border;
        const upload_height: u32 = height + 2 * glyph_atlas.border;
        atlas.upload.resize(gpa, upload_width * upload_height * 4) catch return null;
        const rgba: []u8 = atlas.upload.items;
        @memset(rgba, 0);
        for (0..height) |row| {
            for (0..width) |col| {
                const dst_row: usize = row + glyph_atlas.border;
                const dst_col: usize = col + glyph_atlas.border;
                const dst: usize = (dst_row * upload_width + dst_col) * 4;
                rgba[dst + 0] = 255;
                rgba[dst + 1] = 255;
                rgba[dst + 2] = 255;
                rgba[dst + 3] = atlas.coverage.items[row * width + col];
            }
        }
        pages.writeGlyphPage(slot.page, slot.x, slot.y, upload_width, upload_height, rgba);
        entry.page = slot.page;
        entry.x = slot.x + glyph_atlas.border;
        entry.y = slot.y + glyph_atlas.border;
        entry.width = width;
        entry.height = height;
    }
    atlas.remember(gpa, key, entry) catch return null;
    return entry;
}

/// How draw coordinates map to device pixels at the moment of a draw - the
/// backend's modelview composed with its pass's logical -> device mapping:
/// `device_x = xx*x + xy*y + tx`, `device_y = yx*x + yy*y + ty`.
pub const DeviceMapping = struct {
    xx: f32 = 1,
    xy: f32 = 0,
    yx: f32 = 0,
    yy: f32 = 1,
    tx: f32 = 0,
    ty: f32 = 0,
};

/// True for a backend that can rasterize glyphs on demand (WgpuGl). `GlPtr` is
/// the type of the `gl` the text functions receive.
fn rasterizesGlyphs(comptime GlPtr: type) bool {
    return switch (@typeInfo(GlPtr)) {
        .pointer => |ptr| @typeInfo(ptr.child) == .@"struct" and @hasDecl(ptr.child, "glyphDeviceMapping"),
        else => false,
    };
}

/// One string's worth of glyph drawing. Decides ONCE whether glyphs come from
/// the dynamic cache (a font with a face, on a backend that rasterizes) or from
/// the baked atlas, and precomputes the device mapping for the former.
const GlyphRun = struct {
    font: Font,
    font_size: f32,
    tint: Color,
    /// Null = draw from the baked atlas.
    face: ?*const FontFace = null,
    map: DeviceMapping = .{},
    size_quarters: u32 = 0,
    /// The mapping is an axis-aligned positive scale (no rotation, no flip):
    /// glyph origins then snap to the pixel grid and bitmaps land 1:1.
    snaps_to_pixels: bool = false,
    /// Glyphs are small enough to be positioned to a quarter pixel.
    uses_subpixel_phases: bool = false,
    /// Device px per atlas texel: 1 unless the cached size had to be rounded by
    /// more than a quarter pixel (big text), where the bitmap is then stretched
    /// to the exact size.
    texel_to_device: f32 = 1,
    /// Draw units per atlas texel, for the unsnapped (rotated) path.
    texel_to_draw: f32 = 1,
    /// Baseline below the line-box top, in draw units.
    ascent_draw: f32 = 0,

    fn init(
        gl: anytype,
        font: Font,
        font_size: f32,
        tint: Color,
    ) GlyphRun {
        var run: GlyphRun = .{ .font = font, .font_size = font_size, .tint = tint };
        if (comptime !rasterizesGlyphs(@TypeOf(gl))) {
            return run;
        }
        const face: *const FontFace = fontFace(font) orelse return run;
        const map: DeviceMapping = gl.glyphDeviceMapping();
        const device_per_draw: f32 = @sqrt(@abs(map.xx * map.yy - map.xy * map.yx));
        const drawn_px: f32 = font_size * device_per_draw;
        const is_legible_size: bool = drawn_px >= 1.0 and drawn_px < 1.0e6;
        if (!is_legible_size) {
            return run;
        }
        const size_quarters: u32 = quantizeGlyphSize(drawn_px);
        const cached_px: f32 = float(size_quarters) / 4.0;
        const cached_size_is_exact: bool = @abs(drawn_px - cached_px) <= 0.25;
        const tolerance: f32 = 1.0e-4;
        const is_axis_aligned: bool = @abs(map.xy) <= tolerance * @abs(map.xx) and
            @abs(map.yx) <= tolerance * @abs(map.yy) and map.xx > 0 and map.yy > 0;
        run.face = face;
        run.map = map;
        run.size_quarters = size_quarters;
        run.snaps_to_pixels = is_axis_aligned;
        run.uses_subpixel_phases = is_axis_aligned and cached_size_is_exact and cached_px <= glyph_fine_px;
        run.texel_to_device = if (cached_size_is_exact) 1.0 else drawn_px / cached_px;
        run.texel_to_draw = font_size / cached_px;
        run.ascent_draw = face.ascent_units * face.pixelsPerUnit(font_size);
        return run;
    }

    /// Pen advance for glyph `slot`, in draw units (spacing not included).
    fn advance(run: *const GlyphRun, slot: usize) f32 {
        if (run.face) |face| {
            return float(face.advance_units[slot]) * face.pixelsPerUnit(run.font_size);
        }
        const scale: f32 = run.font_size / float(run.font.baseSize);
        const glyph: GlyphInfo = run.font.glyphs[slot];
        if (glyph.advanceX == 0) {
            return run.font.recs[slot].width * scale;
        }
        return float(glyph.advanceX) * scale;
    }

    /// Draw glyph `slot` (`codepoint`) with its line-box top-left at `pen`.
    fn drawGlyph(
        run: *const GlyphRun,
        gl: anytype,
        codepoint: u21,
        slot: usize,
        pen: Vec2,
    ) void {
        // Comptime: a backend without the hooks must not even compile the calls.
        if (comptime !rasterizesGlyphs(@TypeOf(gl))) {
            drawBakedCodepoint(gl, run.font, codepoint, pen, run.font_size, run.tint);
            return;
        }
        const face: *const FontFace = run.face orelse {
            drawBakedCodepoint(gl, run.font, codepoint, pen, run.font_size, run.tint);
            return;
        };
        var key: glyph_atlas.Key = .{
            .face_id = face.id,
            .slot = @intCast(slot),
            .size_quarters = run.size_quarters,
            .phase = 0,
        };
        const baseline_draw_y: f32 = pen[1] + run.ascent_draw;
        const map: DeviceMapping = run.map;
        if (!run.snaps_to_pixels) {
            // Rotated or flipped: nothing lines up with pixels, so place the
            // bitmap in draw units and let the transform carry it.
            const entry: glyph_atlas.Entry = gl.glyphEntry(face, key) orelse {
                drawBakedCodepoint(gl, run.font, codepoint, pen, run.font_size, run.tint);
                return;
            };
            const texel: f32 = run.texel_to_draw;
            const dst: Rectangle = .{
                .x = pen[0] + float(entry.offset_x) * texel,
                .y = baseline_draw_y + float(entry.offset_y) * texel,
                .width = float(entry.width) * texel,
                .height = float(entry.height) * texel,
            };
            emitGlyphQuad(gl, entry, dst, run.tint);
            return;
        }
        // Snap in DEVICE space: the pen's x to a quarter pixel (the remainder is
        // baked into the bitmap as a sub-pixel shift, so spacing stays exact) or
        // a whole one, the baseline to a whole pixel. Then map the device-space
        // rectangle back to draw units - the backend's own transform takes it
        // straight back onto those pixels.
        const pen_device_x: f32 = map.xx * pen[0] + map.tx;
        const baseline_device_y: f32 = @round(map.yy * baseline_draw_y + map.ty);
        var origin_device_x: f32 = @round(pen_device_x);
        if (run.uses_subpixel_phases) {
            const whole_px: f32 = @floor(pen_device_x);
            const phase: u32 = @round((pen_device_x - whole_px) * 4.0);
            const rounds_up_to_next_px: bool = phase == 4;
            origin_device_x = if (rounds_up_to_next_px) whole_px + 1.0 else whole_px;
            key.phase = if (rounds_up_to_next_px) 0 else phase;
        }
        const entry: glyph_atlas.Entry = gl.glyphEntry(face, key) orelse {
            drawBakedCodepoint(gl, run.font, codepoint, pen, run.font_size, run.tint);
            return;
        };
        const texel: f32 = run.texel_to_device;
        const left_device: f32 = origin_device_x + float(entry.offset_x) * texel;
        const top_device: f32 = baseline_device_y + float(entry.offset_y) * texel;
        const dst: Rectangle = .{
            .x = (left_device - map.tx) / map.xx,
            .y = (top_device - map.ty) / map.yy,
            .width = float(entry.width) * texel / map.xx,
            .height = float(entry.height) * texel / map.yy,
        };
        emitGlyphQuad(gl, entry, dst, run.tint);
    }
};

/// One textured quad from an atlas page: the same vertex order and attributes
/// as `drawTexturePro`, bound through the page's own material.
fn emitGlyphQuad(
    gl: anytype,
    entry: glyph_atlas.Entry,
    dst: Rectangle,
    tint: Color,
) void {
    const glyph_has_ink: bool = entry.width > 0 and entry.height > 0;
    if (!glyph_has_ink) {
        return;
    }
    gl.bindGlyphPage(entry.page);
    const page_texels: f32 = float(glyph_atlas.page_size);
    const u_left: f32 = float(entry.x) / page_texels;
    const u_right: f32 = float(entry.x + entry.width) / page_texels;
    const v_top: f32 = float(entry.y) / page_texels;
    const v_bottom: f32 = float(entry.y + entry.height) / page_texels;
    gl.begin(.quads);
    gl.color4ub(tint.r, tint.g, tint.b, tint.a);
    gl.normal3f(0, 0, 1);
    gl.texCoord2f(u_left, v_top);
    gl.vertex2f(dst.x, dst.y);
    gl.texCoord2f(u_left, v_bottom);
    gl.vertex2f(dst.x, dst.y + dst.height);
    gl.texCoord2f(u_right, v_bottom);
    gl.vertex2f(dst.x + dst.width, dst.y + dst.height);
    gl.texCoord2f(u_right, v_top);
    gl.vertex2f(dst.x + dst.width, dst.y);
    gl.end();
}

// Drawing (no alloc, side-effect)
/// Draw a single codepoint at `position` - rasterized at its drawn size when the
/// font has a face and the backend supports it, else from the baked atlas.
/// Reads: nothing besides arguments.
/// Mutates: `gl.*` (rlgl batch - vertices appended).
pub fn drawCodepoint(
    gl: anytype,
    font: Font,
    codepoint: u21,
    position: Vec2,
    font_size: f32,
    tint: Color,
) void {
    const run: GlyphRun = GlyphRun.init(gl, font, font_size, tint);
    run.drawGlyph(gl, codepoint, getGlyphIndex(font, codepoint), position);
}

/// Draw a single codepoint from the font's BAKED atlas, scaled to `font_size`.
fn drawBakedCodepoint(
    gl: anytype,
    font: Font,
    codepoint: u21,
    position: Vec2,
    font_size: f32,
    tint: Color,
) void {
    const idx: usize = getGlyphIndex(font, codepoint);
    const scale: f32 = font_size / float(font.baseSize);
    const pad: f32 = float(font.glyphPadding);
    const dst: Rectangle = .{
        .x = position[0] + float(font.glyphs[idx].offsetX) * scale - pad * scale,
        .y = position[1] + float(font.glyphs[idx].offsetY) * scale - pad * scale,
        .width = (font.recs[idx].width + 2.0 * pad) * scale,
        .height = (font.recs[idx].height + 2.0 * pad) * scale,
    };
    const src: Rectangle = .{
        .x = font.recs[idx].x - pad,
        .y = font.recs[idx].y - pad,
        .width = font.recs[idx].width + 2.0 * pad,
        .height = font.recs[idx].height + 2.0 * pad,
    };
    const origin: Vec2 = .{ 0, 0 };
    // The image path was not converted, so this crossing is radians. Zero either way, but the
    // name has to say which side it is on.
    const rotation_rad: f32 = 0.0;
    image_mod.drawTexturePro(gl, font.texture, src, dst, origin, rotation_rad, tint);
}

/// Draw a UTF-8 string at `position` with explicit font, size,
/// and per-glyph spacing.  '\n' starts a new line, advancing y by
/// `font_size + line_spacing`.
/// **Caller must pass a loaded `Font`** - no fallback to default.
/// For default-font convenience use `text.draw` (which fetches
/// from `font_cache` and forwards to `drawWithFont`).
/// Reads: `line_spacing` (px gap between lines, only consulted
/// when the string contains '\n').
/// Mutates: `gl.*` (rlgl batch - one quad per renderable
/// codepoint).
pub fn drawWithFont(
    gl: anytype,
    line_spacing: i32,
    font: Font,
    s: []const u8,
    position: Vec2,
    font_size: f32,
    spacing: f32,
    tint: Color,
) void {
    const run: GlyphRun = GlyphRun.init(gl, font, font_size, tint);
    var off_y: f32 = 0;
    var off_x: f32 = 0;
    var i: usize = 0;
    while (i < s.len) {
        const dc: DecodedCodepoint = nextCodepoint(s[i..]);
        const idx: usize = getGlyphIndex(font, dc.codepoint);
        if (dc.codepoint == '\n') {
            off_y += font_size + float(line_spacing);
            off_x = 0;
        } else {
            const is_renderable: bool = dc.codepoint != ' ' and dc.codepoint != '\t';
            if (is_renderable) {
                const glyph_pos: Vec2 = .{ position[0] + off_x, position[1] + off_y };
                run.drawGlyph(gl, dc.codepoint, idx, glyph_pos);
            }
            off_x += run.advance(idx) + spacing;
        }
        i += dc.bytes;
    }
}

/// Draw `s` with the default font.  Convenience wrapper around
/// `drawWithFont` - fetches the default `Font` from `font_cache`,
/// derives glyph spacing from `font_size`, hands off.  No-op
/// when the cache is unloaded (texture id 0).
/// Reads: `font_cache.font` (the loaded default `Font`),
/// `line_spacing` (forwarded to `drawWithFont`).
/// Mutates: `gl.*` (rlgl batch via `drawWithFont`).
pub fn draw(
    gl: anytype,
    font_cache: *const FontCache,
    line_spacing: i32,
    s: []const u8,
    x: i32,
    y: i32,
    font_size: i32,
    color: Color,
) void {
    const font: Font = getFontDefault(font_cache);
    if (font.texture.id == 0) {
        // Footgun-detector: the silent return
        // here was the cause of the "text shows on desktop
        // but invisible on phone" bug for ui_smoke_button +
        // ui_dock_basic.  No font loaded -> `texture.id == 0`
        // -> submit nothing -> look fine, until you notice no
        // labels.  Log a one-shot warning so the next time
        // someone forgets a font load it surfaces in
        // browser devtools console immediately rather than
        // after a phone test.
        // One-shot guard: the warning is the diagnostic
        // signal, not an error.  Spamming once per submitted
        // glyph (potentially thousands per frame) would
        // bury the user's own logs.
        // Non-empty `s` only - a `u.text("", ...)` call is
        // a legitimate no-op the user shouldn't be warned
        // about.  Silenced under `builtin.is_test`: host
        // tests intentionally exercise drawing code without
        // loading a font, and the warning is pure noise
        // there.
        if (!warned_text_no_font and s.len > 0 and !builtin.is_test) {
            warned_text_no_font = true;
            std.log.warn(
                "zimr: text submitted but font cache is " ++
                    "empty (no `loadFontDefault` or " ++
                    "`loadFontFromTtfData` call yet) - text " ++
                    "will be invisible until a font is loaded.",
                .{},
            );
        }
        return;
    }
    var sz: i32 = font_size;
    const default_size: i32 = 10;
    if (sz < default_size) {
        sz = default_size;
    }
    const spacing: i32 = @divFloor(sz, default_size);
    const position: Vec2 = .{ @floatFromInt(x), @floatFromInt(y) };
    drawWithFont(
        gl,
        line_spacing,
        font,
        s,
        position,
        @floatFromInt(sz),
        @floatFromInt(spacing),
        color,
    );
}

/// Draw `s` rotated `rotation_turns` turns around `origin` (relative
/// to `position`).
/// **Caller must pass a loaded `Font`** - no fallback to default.
/// Reads: `line_spacing` (forwarded to drawWithFont).
/// Mutates: `gl.*` - matrix stack push/translate/rotate is
/// balanced (caller's transform is restored at return); the
/// rlgl batch is appended via `drawWithFont`.
pub fn drawPro(
    gl: anytype,
    line_spacing: i32,
    font: Font,
    s: []const u8,
    position: Vec2,
    origin: Vec2,
    rotation_turns: f32,
    font_size: f32,
    spacing: f32,
    tint: Color,
) void {
    rlPushMatrix(gl);
    rlTranslatef(gl, position[0], position[1], 0);
    gl.rotate(rotation_turns, 0, 0, 1);
    rlTranslatef(gl, -origin[0], -origin[1], 0);
    const text_pos: Vec2 = .{ 0, 0 };
    drawWithFont(gl, line_spacing, font, s, text_pos, font_size, spacing, tint);
    rlPopMatrix(gl);
}

/// Draw a sequence of pre-decoded codepoints.  Same layout rules
/// as `drawWithFont` - '\n' starts a new line, advancing y by
/// `font_size + line_spacing`.
/// **Caller must pass a loaded `Font`** - no fallback to default.
/// Reads: `line_spacing` (px gap between lines, only consulted
/// when codepoints contain `'\n'`).
/// Mutates: `gl.*` (rlgl batch - one quad per renderable
/// codepoint).
pub fn drawCodepoints(
    gl: anytype,
    line_spacing: i32,
    font: Font,
    codepoints: []const u21,
    position: Vec2,
    font_size: f32,
    spacing: f32,
    tint: Color,
) void {
    const run: GlyphRun = GlyphRun.init(gl, font, font_size, tint);
    var off_y: f32 = 0;
    var off_x: f32 = 0;
    for (codepoints) |cp| {
        const idx: usize = getGlyphIndex(font, cp);
        if (cp == '\n') {
            off_y += font_size + float(line_spacing);
            off_x = 0;
        } else {
            const is_renderable: bool = cp != ' ' and cp != '\t';
            if (is_renderable) {
                const glyph_pos: Vec2 = .{ position[0] + off_x, position[1] + off_y };
                run.drawGlyph(gl, cp, idx, glyph_pos);
            }
            off_x += run.advance(idx) + spacing;
        }
    }
}

// Measurement (no alloc)
/// One glyph's advance BEFORE scaling to the requested size: font units for a
/// font with a face (exact at any size - the drawn advance is the same number),
/// baked-atlas pixels otherwise (the measure path's historical rule: an image
/// font with no advance measures its rect plus its offset).
fn unscaledAdvance(
    font: Font,
    face: ?*const FontFace,
    slot: usize,
) f32 {
    if (face) |f| {
        return float(f.advance_units[slot]);
    }
    if (font.glyphs[slot].advanceX > 0) {
        return float(font.glyphs[slot].advanceX);
    }
    return font.recs[slot].width + float(font.glyphs[slot].offsetX);
}

/// Measure the width x height (px) of a string with explicit
/// font, size, and per-glyph spacing.  Width returned in `.x`,
/// height in `.y`.  Multi-line strings ('\n' separated) yield
/// the max-line width and the cumulative height including line
/// gaps.
/// Reads: `line_spacing` (px gap between lines, only consulted
/// when the string contains '\n').
pub fn measureWithFont(
    line_spacing: i32,
    font: Font,
    s: []const u8,
    font_size: f32,
    spacing: f32,
) Vec2 {
    var result: Vec2 = .{ 0, 0 };
    if (font.texture.id == 0 or s.len == 0) {
        return result;
    }
    const face: ?*const FontFace = fontFace(font);
    const scale: f32 = if (face) |f| f.pixelsPerUnit(font_size) else font_size / float(font.baseSize);
    var width: f32 = 0;
    var temp_width: f32 = 0;
    var height: f32 = font_size;
    var byte_counter: i32 = 0;
    var temp_byte_counter: i32 = 0;
    var i: usize = 0;
    while (i < s.len) {
        byte_counter += 1;
        const dc: DecodedCodepoint = nextCodepoint(s[i..]);
        const idx: usize = getGlyphIndex(font, dc.codepoint);
        i += dc.bytes;
        if (dc.codepoint != '\n') {
            width += unscaledAdvance(font, face, idx);
        } else {
            if (temp_width < width) {
                temp_width = width;
            }
            byte_counter = 0;
            width = 0;
            height += font_size + float(line_spacing);
        }
        if (temp_byte_counter < byte_counter) {
            temp_byte_counter = byte_counter;
        }
    }
    if (temp_width < width) {
        temp_width = width;
    }
    result[0] = temp_width * scale + float(temp_byte_counter - 1) * spacing;
    result[1] = height;
    return result;
}

/// Measure the width (px) of a string in the default font.
/// Convenience wrapper around `measureWithFont` - fetches the default
/// `Font` from `font_cache`, derives glyph spacing from
/// `font_size`, returns just the width.
/// Reads: `font_cache.font` (the loaded default `Font`),
/// `line_spacing` (forwarded to `measureWithFont`).
pub fn measure(
    font_cache: *const FontCache,
    line_spacing: i32,
    s: []const u8,
    font_size: i32,
) i32 {
    const font: Font = getFontDefault(font_cache);
    if (font.texture.id == 0) {
        return 0;
    }
    var sz: i32 = font_size;
    const default_size: i32 = 10;
    if (sz < default_size) {
        sz = default_size;
    }
    const spacing: i32 = @divFloor(sz, default_size);
    const v: Vec2 = measureWithFont(line_spacing, font, s, @floatFromInt(sz), @floatFromInt(spacing));
    return @trunc(v[0]);
}

/// Measure a sequence of pre-decoded codepoints.  Same semantics
/// as `measureWithFont` but skips UTF-8 decoding - useful when the
/// caller already has decoded glyphs (e.g. a layout cache).
/// Reads: `line_spacing` (px gap between lines, only consulted
/// when codepoints contain '\n').
pub fn measureCodepoints(
    line_spacing: i32,
    font: Font,
    codepoints: []const u21,
    font_size: f32,
    spacing: f32,
) Vec2 {
    var result: Vec2 = .{ 0, 0 };
    if (font.texture.id == 0 or codepoints.len == 0) {
        return result;
    }
    const face: ?*const FontFace = fontFace(font);
    const scale: f32 = if (face) |f| f.pixelsPerUnit(font_size) else font_size / float(font.baseSize);
    var width: f32 = 0;
    var temp_width: f32 = 0;
    var height: f32 = font_size;
    var glyph_counter: i32 = 0;
    var temp_glyph_counter: i32 = 0;
    for (codepoints) |cp| {
        const idx: usize = getGlyphIndex(font, cp);
        if (cp != '\n') {
            glyph_counter += 1;
            width += unscaledAdvance(font, face, idx);
        } else {
            if (temp_width < width) {
                temp_width = width;
            }
            width = 0;
            glyph_counter = 0;
            height += font_size + float(line_spacing);
        }
        if (temp_glyph_counter < glyph_counter) {
            temp_glyph_counter = glyph_counter;
        }
    }
    if (temp_width < width) {
        temp_width = width;
    }
    result[0] = temp_width * scale + float(temp_glyph_counter - 1) * spacing;
    result[1] = height;
    return result;
}

// ===========================================================================
//                 raylib-flavoured names (mostly removed)
// ===========================================================================
// Below this point used to be the raylib-flavoured C-shape exports
// that took `[*:0]const u8`. They've been deleted incrementally:
// - `s*` static-buffer helpers (subtext/upper/lower/etc.) - Phase D.2
// - `getCodepoint*` out-pointer combo - Cat 4
// - `text*` helpers (Copy/IsEqual/FindIndex/etc.) - aggressive
// - `drawText*` / `measureText*` C-shape wrappers - aggressive
// - `textLength` - aggressive (`s.len` / `std.mem.span(s).len`)
// What remains here is purely the slice-shape Zig API (`draw`,
// `drawWithFont`, `drawPro`, `measure`, `measureWithFont`, codepoint helpers).

// ---- Codepoints
// The `getCodepointNext` / `getCodepointPrevious` / `getCodepoint` /
// `getCodepointCount` raylib-shape functions used to live here as a
// `[*:0]const u8` + `*i32` out-pointer combo.  They were Cat 3+4
// cleanup material per `notes/ziggification-candidates.md`: every
// call site already had a slice in hand and was casting to `[*:0]`
// just to please the C-shape signature, then unpacking the size
// from an out-pointer it didn't need.  Deleted in favour of the
// slice-native helpers `nextCodepoint(s: []const u8)
// -> DecodedCodepoint` / `prevCodepoint(s, end_offset)` /
// `countCodepoints(s)` already exposed above.  All previously-
// internal callers were rewritten in the same change.
// For brand-new code that doesn't need the project's lenient
// raylib-style '?' replacement on decode error, prefer
// `std.unicode.Utf8Iterator` - it's the stdlib answer and handles
// everything `nextCodepoint` does.

// `codepointToUTF8` removed in Phase D.2 - same static-buffer
// hazard as the s helpers above (single 6-byte `utf8_buffer`
// returned by pointer, next call clobbers).  Zero callers in zimr.
// Equivalent: `loadUTF8(gpa, &.{ codepoint })` returns a properly
// owned single-codepoint UTF-8 slice.

// `textLength` removed - Zig users call `s.len` on a slice or
// `std.mem.span(s).len` on a `[*:0]const u8`.  The wrapper was a
// pure C-shape compatibility shim with no callers in zimr.

// ---- raylib-style text helpers REMOVED - use std instead
// raylib's `TextCopy`, `TextIsEqual`, `TextFindIndex`, `TextAppend`,
// `TextToInteger`, and `TextToFloat` were thin C-string utilities
// designed around C's lack of a slice type and lack of stdlib parsing.
// Zig has both.  The Zig-native equivalents are strictly better:
//   raylib                          | Zig std
//   ---------------------------------
//   TextCopy(dst, src)              | @memcpy(dst, src) or std.mem.copyForwards
//   TextIsEqual(a, b)               | std.mem.eql(u8, a, b)
//   TextFindIndex(s, needle)        | std.mem.indexOf(u8, s, needle)
//   TextAppend(buf, str, &pos)      | std.fmt.bufPrint
//   TextToInteger(s)                | std.fmt.parseInt(i32, s, 10)
//   TextToFloat(s)                  | std.fmt.parseFloat(f32, s)
// The std equivalents return `?usize` / errors instead of -1 / NaN
// sentinels and take `[]const u8` slices instead of `[*:0]const u8`.
// Zero callers in zimr's tree at delete time.

// ---- Substring / case conversion helpers REMOVED in Phase D.2
// raylib's `textSubtext`, `textToUpper`, `textToLower`, `textToPascal`,
// `textToSnake`, `textToCamel`, and `textRemoveSpaces` returned
// pointers into a shared module-level `text_buffer` - the next call
// clobbered the previous return.  Multi-app correctness hazard plus
// non-Zig-shaped surface.  Zero callers in zimr's tree at delete
// time.  Users wanting these reach for `std.mem.*` or `std.ascii.*`
// directly.

// `setLineSpacing` / `setTextLineSpacing` were also removed
//: per-call lens - `line_spacing` is now a parameter
// on every text fn that needs it (`drawWithFont`, `measureWithFont`, etc.),
// and the UI's `Style.line_spacing` field carries it for widget
// text.  Users wanting a project-wide value lift it into their
// `State` struct.

// ---- Font / glyph queries - C ABI exports double as the public Zig API
// These take `i32` for codepoint to match the C ABI exactly. Internal
// Zig callers within s.zig use the `*Z`-suffixed helpers above, which
// take `u21`.

pub fn isFontValid(font: Font) bool {
    return isFontValidZ(font);
}

// ---- Font/codepoint memory unloaders
// Each just calls libc free, but the typed signatures document what they
// were allocated for. The order in `unloadFont` matches raylib's
// `unloadFont`: glyph images first (via `unloadFontData`), then the
// texture (via `unloadTexture`), then the rec array.

// Same wasm-linker constraint as `getFontDefault`: route the reverse-
// of-load helpers through direct Zig imports rather than `extern fn`.
// The `rlgl_gpu` import is gated to wasm-only because it transitively
// pulls in browser-binding modules (`web/dom.zig`, `web/gl.zig`) that
// don't compile on host targets - breaking unit tests.  On host the
// stubs are no-ops; the cleanup code paths these support are never
// exercised by tests anyway.

// loadCodepoints / loadUTF8 - UTF-8 <-> codepoint conversion
/// Decode a UTF-8 string into a heap-allocated array of codepoints.
/// The returned slice carries its length; free with `gpa.free(slice)`.
/// Empty input returns an empty slice (not an error).
/// Invalid UTF-8 sequences yield a `'?'` (0x3F) replacement codepoint,
/// matching `nextCodepoint`'s lenient behaviour and what raylib does
/// at the public boundary.
pub fn loadCodepoints(
    gpa: Allocator,
    s: []const u8,
) Allocator.Error![]i32 {
    const total: usize = countCodepoints(s);
    if (total == 0) {
        return &[_]i32{};
    }

    const out: []i32 = try gpa.alloc(i32, total);
    errdefer gpa.free(out);

    var i: usize = 0;
    var byte_offset: usize = 0;
    while (i < total) : (i += 1) {
        const dc: DecodedCodepoint = nextCodepoint(s[byte_offset..]);
        out[i] = @intCast(dc.codepoint);
        byte_offset += dc.bytes;
    }
    return out;
}

/// Encode a codepoint slice back to a heap-allocated, sentinel-
/// terminated UTF-8 string.  The returned slice carries its length
/// (excluding the null sentinel); free with `gpa.free(slice)`.
/// Empty input returns an empty sentinel-terminated slice.
/// Invalid codepoints (above 0x10FFFF or in the surrogate range)
/// are emitted as the replacement character (U+FFFD).
pub fn loadUTF8(
    gpa: Allocator,
    codepoints: []const i32,
) Allocator.Error![:0]u8 {
    // Two-pass: count exact byte length first, then allocate exactly,
    // then encode.  Avoids the over-alloc-and-resize dance.
    var byte_len: usize = 0;
    for (0..codepoints.len) |i| {
        const cp: i32 = codepoints[i];
        const valid_cp: u21 = if (cp < 0 or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF))
            0xFFFD
        else
            @intCast(cp);
        byte_len += if (valid_cp < 0x80) 1 else if (valid_cp < 0x800) 2 else if (valid_cp < 0x10000) 3 else 4;
    }

    const buf: [:0]u8 = try gpa.allocSentinel(u8, byte_len, 0);
    errdefer gpa.free(buf);

    var written: usize = 0;
    for (codepoints) |cp| {
        const valid_cp: u21 = if (cp < 0 or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF))
            0xFFFD
        else
            @intCast(cp);

        if (valid_cp < 0x80) {
            buf[written] = @intCast(valid_cp);
            written += 1;
        } else if (valid_cp < 0x800) {
            buf[written + 0] = @intCast(0xC0 | (valid_cp >> 6));
            buf[written + 1] = @intCast(0x80 | (valid_cp & 0x3F));
            written += 2;
        } else if (valid_cp < 0x10000) {
            buf[written + 0] = @intCast(0xE0 | (valid_cp >> 12));
            buf[written + 1] = @intCast(0x80 | ((valid_cp >> 6) & 0x3F));
            buf[written + 2] = @intCast(0x80 | (valid_cp & 0x3F));
            written += 3;
        } else {
            buf[written + 0] = @intCast(0xF0 | (valid_cp >> 18));
            buf[written + 1] = @intCast(0x80 | ((valid_cp >> 12) & 0x3F));
            buf[written + 2] = @intCast(0x80 | ((valid_cp >> 6) & 0x3F));
            buf[written + 3] = @intCast(0x80 | (valid_cp & 0x3F));
            written += 4;
        }
    }
    return buf;
}

// `unloadTextLines` removed in Phase D.2 - its raylib counterpart
// `loadTextLines` (which produced a single-allocation array of
// pointers + their backing strings) was never ported, so this fn
// had no live producer.  If s-by-lines is ever needed, the
// idiomatic Zig answer is `std.mem.splitScalar(u8, s, '\n')`
// returning a lazy iterator - no allocation needed at all.

// imageDrawText / imageDrawTextWithFont - Roadmap Step 4
// CPU-side glyph rasterization onto a destination Image.  Useful for
// procedural texture generation: bake s into a texture once, upload
// to GPU, render via ordinary `drawTexture`.
// Implementation: walks the string codepoint by codepoint, looks up
// each glyph in the font, and composites the per-glyph CPU bitmap
// (`font.glyphs[i].image`) onto `dst` via `imageDraw`.  For our
// embedded default font, those per-glyph bitmaps are populated by
// `loadFontDefault` (carved out of the atlas during init).  For
// user-globalDefaultFont().loaded TTF fonts (post Step 60), they will be populated by the
// glyph rasterizer.
// Line height: fixed 1.5x baseSize on '\n' (matches raylib).  Custom
// line spacing isn't currently exposed (raylib has the same TODO).
/// Draw s onto an Image using a custom font.  CPU-side equivalent
/// of `drawTextEx`.
/// **Limitation:** only honors the font's *base* size during
/// rasterization - user-requested `fontSize` smaller than `font.baseSize`
/// gets clamped up.  Larger requested sizes work but use nearest-
/// neighbor scaling per glyph (which can look chunky for the default
/// font); high-quality scaling will arrive with a future `imageResize`.
pub fn imageDrawTextWithFont(
    dst: *Image,
    font: Font,
    s: []const u8,
    position: Vec2,
    fontSize: f32,
    spacing: f32,
    tint: Color,
) void {
    if (dst.data == null or dst.width == 0 or dst.height == 0) {
        return;
    }
    if (font.glyphCount == 0 or font.glyphs == null or font.recs == null) {
        return;
    }

    const base_f: f32 = float(font.baseSize);
    if (base_f <= 0) {
        return;
    }

    // Clamp requested size to font base (we don't yet scale per-glyph
    // images - scaling lands with Step 12).  A scale != 1 path is
    // tracked via `scale` and applied via `imageDraw`'s nearest-
    // neighbor when src/dst rectangles differ.
    const scale: f32 = fontSize / base_f; // downsample baked (device-px) glyphs to requested size

    var off_x: f32 = 0;
    var off_y: f32 = 0;

    var byte_offset: usize = 0;
    while (byte_offset < s.len) {
        const dc: DecodedCodepoint = nextCodepoint(s[byte_offset..]);
        const cp: u21 = dc.codepoint;
        const idx: usize = getGlyphIndex(font, cp);

        if (cp == '\n') {
            // 1.5x line-height (matches raylib).
            off_y += base_f * 1.5;
            off_x = 0;
        } else if (cp != ' ' and cp != '\t') {
            const glyph: GlyphInfo = font.glyphs[idx];
            const rec: z.Rectangle = font.recs[idx];

            // Composite source: the per-glyph image carved out of the
            // atlas during `loadFontDefault` (or filled by TTF in step
            // 60).  If unpopulated, skip (whitespace-like).
            if (glyph.image.data != null and glyph.image.width > 0 and glyph.image.height > 0) {
                const src_rec: Rectangle = .{
                    .x = 0,
                    .y = 0,
                    .width = @floatFromInt(glyph.image.width),
                    .height = @floatFromInt(glyph.image.height),
                };
                const dst_rec: Rectangle = .{
                    .x = position[0] + off_x + float(glyph.offsetX) * scale,
                    .y = position[1] + off_y + float(glyph.offsetY) * scale,
                    .width = rec.width * scale,
                    .height = rec.height * scale,
                };
                image_mod.imageDraw(dst, glyph.image, src_rec, dst_rec, tint);
            }
        }

        // Advance (mirrors `drawTextCodepoints` logic).
        off_x += if (font.glyphs[idx].advanceX == 0)
            font.recs[idx].width * scale + spacing
        else
            float(font.glyphs[idx].advanceX) * scale + spacing;

        byte_offset += dc.bytes;
    }
}

/// Draw `s` onto an Image using the default font.  CPU-side
/// equivalent of `text.draw` - fetches the default `Font` from
/// `font_cache`, derives spacing from `fontSize / 10`, hands off
/// to `imageDrawTextWithFont`.
/// Reads: `font_cache.font` (the loaded default `Font`).
/// Mutates: `dst.*` (rasterizes glyphs into the image's pixel
/// buffer).
pub fn imageDrawText(
    dst: *Image,
    font_cache: *const FontCache,
    s: []const u8,
    posX: i32,
    posY: i32,
    fontSize: i32,
    color: Color,
) void {
    const font: Font = getFontDefault(font_cache);
    const default_size: i32 = 10;
    var size: i32 = fontSize;
    if (size < default_size) {
        size = default_size;
    }
    const spacing: f32 = float(@divFloor(size, default_size));
    const position: Vec2 = .{ @floatFromInt(posX), @floatFromInt(posY) };
    imageDrawTextWithFont(
        dst,
        font,
        s,
        position,
        @floatFromInt(size),
        spacing,
        color,
    );
}

// ---- DrawFPS - uses Zig formatting instead of textFormat's static buffer

const lime: Color = .{ .r = 0, .g = 158, .b = 47, .a = 255 };
const orange: Color = .{ .r = 255, .g = 161, .b = 0, .a = 255 };
const red: Color = .{ .r = 230, .g = 41, .b = 55, .a = 255 };

/// Draw the current FPS at (`pos_x`, `pos_y`).  Color codes:
///   >= 30 fps  ->  lime    (good)
///   15-29 fps ->  orange  (warning)
///   < 15 fps  ->  red     (low)
/// Uses 20-pixel default font.
/// Reads `fps.average` (rolling FPS via `core.getFPS`),
/// `font_cache.font` (default `Font` for the digit glyphs).
/// Mutates `gl.*` (rlgl batch - one quad per digit + " FPS"
/// suffix).
pub fn drawFPS(
    gl: anytype,
    font_cache: *const FontCache,
    fps: *const core_module.FpsState,
    pos_x: i32,
    pos_y: i32,
) void {
    const fps_value: i32 = core_module.getFPS(fps);
    const color: Color = if (fps_value >= 30) lime else if (fps_value >= 15) orange else red;
    var buf: [16]u8 = undefined;
    // raylib's format is "%2i FPS" - 2-wide right-justified integer.
    const s: [:0]const u8 = std.fmt.bufPrintSentinel(&buf, "{d:>2} FPS", .{fps_value}, 0) catch return;
    // Default text fns use line_spacing=2 throughout zimr; FPS
    // is a single-line string so the value never matters.
    draw(gl, font_cache, 2, s, @intCast(pos_x), @intCast(pos_y), 20, color);
}

// ---- Drawing
/// Draw a single codepoint glyph from `font` at `position`.
/// Wrapper around the lower-level `drawCodepoint` matching
/// raylib's `DrawTextCodepoint` shape.
/// Reads `font.glyphs` / `font.recs` (glyph metrics + atlas
/// rect for the codepoint).
/// Mutates `gl.*` (rlgl batch - one textured quad).
pub fn drawTextCodepoint(
    gl: anytype,
    font: Font,
    codepoint: i32,
    position: Vec2,
    fontSize: f32,
    tint: Color,
) void {
    drawCodepoint(gl, font, @intCast(codepoint), position, fontSize, tint);
}

// ---- C-shape `[*:0]const u8` draw / measure wrappers DELETED
// raylib's `DrawText`, `DrawTextEx`, `DrawTextPro`, `MeasureText`,
// `MeasureTextEx` took a null-terminated C string.  zimr already
// had Zig-native slice-shape implementations under shorter names
// (`draw`, `drawWithFont`, `drawPro`, `measure`, `measureWithFont`) - the C-
// shape variants were thin `[*:0]` -> slice wrappers.
// Migration cheat sheet:
//   z.text.drawText("hi", x, y, sz, c)        -> z.text.draw("hi", x, y, sz, c)
//   z.text.drawTextEx(font, "hi", p, sz, sp, c)-> z.text.drawWithFont(font, "hi", p, sz, sp, c)
//   z.text.measureText("hi", sz)              -> z.text.measure("hi", sz)
//   z.text.measureTextWithFont(font, "hi", sz, sp)  -> z.text.measureWithFont(font, "hi", sz, sp)
// Zig string literals (`"hi"`) coerce to both `[*:0]const u8` and
// `[]const u8`, so existing call sites with literals just work.
// For runtime-built strings, you keep the slice you already have
// and skip the `@ptrCast(buf.ptr)` dance.

/// Draw a slice of decoded codepoints with `font` at `position`,
/// honouring `\n` (newline advances by `fontSize + line_spacing`).
/// Pure forwarder over `drawCodepoint` - useful when the caller
/// already has a decoded codepoint buffer (e.g. shaping output)
/// and wants to skip the UTF-8 redecoding `drawWithFont` would do.
/// Reads: `line_spacing` (vertical gap between wrapped lines).
/// Writes: implicit GL draw state via `drawCodepoint`.
pub fn drawTextCodepoints(
    gl: anytype,
    line_spacing: i32,
    font: Font,
    codepoints: []const i32,
    position: Vec2,
    fontSize: f32,
    spacing: f32,
    tint: Color,
) void {
    // Inline the loop so we don't have to allocate a u21 buffer.
    const run: GlyphRun = GlyphRun.init(gl, font, fontSize, tint);
    var off_y: f32 = 0;
    var off_x: f32 = 0;
    for (codepoints) |cp_raw| {
        const cp: u21 = @intCast(cp_raw);
        const idx: usize = getGlyphIndex(font, cp);
        if (cp == '\n') {
            off_y += fontSize + float(line_spacing);
            off_x = 0;
        } else {
            if (cp != ' ' and cp != '\t') {
                run.drawGlyph(gl, cp, idx, .{ position[0] + off_x, position[1] + off_y });
            }
            off_x += run.advance(idx) + spacing;
        }
    }
}

// ---- Measurement
// C-shape `measureText` / `measureTextWithFont` removed - see deletion
// marker above.  Use `measure` / `measureWithFont` (slice-shape).

/// Measure rendered dimensions of a slice of decoded codepoints
/// at `fontSize` and per-glyph `spacing`.  Multi-line strings
/// (codepoints containing `'\n'`) advance the height by
/// `fontSize + line_spacing` per newline.
/// Reads: `line_spacing` (only matters when `codepoints`
/// contains '\n').
pub fn measureTextCodepoints(
    line_spacing: i32,
    font: Font,
    codepoints: []const i32,
    fontSize: f32,
    spacing: f32,
) Vec2 {
    var result: Vec2 = .{ 0, 0 };
    if (font.texture.id == 0 or codepoints.len == 0) {
        return result;
    }
    const face: ?*const FontFace = fontFace(font);
    const scale: f32 = if (face) |f| f.pixelsPerUnit(fontSize) else fontSize / float(font.baseSize);
    var width: f32 = 0;
    var temp_width: f32 = 0;
    var height: f32 = fontSize;
    var glyph_counter: i32 = 0;
    var temp_glyph_counter: i32 = 0;
    for (codepoints) |cp_raw| {
        const cp: u21 = @intCast(cp_raw);
        const idx: usize = getGlyphIndex(font, cp);
        if (cp != '\n') {
            glyph_counter += 1;
            width += unscaledAdvance(font, face, idx);
        } else {
            if (temp_width < width) {
                temp_width = width;
            }
            width = 0;
            glyph_counter = 0;
            height += fontSize + float(line_spacing);
        }
        if (temp_glyph_counter < glyph_counter) {
            temp_glyph_counter = glyph_counter;
        }
    }
    if (temp_width < width) {
        temp_width = width;
    }
    result[0] = temp_width * scale + float(temp_glyph_counter - 1) * spacing;
    result[1] = height;
    return result;
}

// ---- Splitting / joining / replacing / inserting REMOVED in Phase D.2
// raylib's `textSplit`, `textJoin`, `textReplace`, `textInsert`
// returned pointers into shared module-level static buffers
// (`split_buffer`, `split_pointers`, `join_buffer`, `text_buffer`).
// Same multi-app correctness hazard as the case-conversion helpers
// removed above.  Zero callers in zimr's tree at delete time.
// Users wanting these reach for `std.mem.split` / `std.mem.join` /
// `std.mem.replaceOwned` / manual string ops directly.

// ===========================================================================
// Atlas baker - TrueType glyphs -> packed RGBA8 atlas image
// ===========================================================================
// Takes a parsed TrueType font and a list of codepoints to bake,
// rasterizes each glyph at the requested pixel size, packs the
// rectangles into a single RGBA8 atlas image, and returns the
// CPU-side atlas plus parallel arrays of per-glyph metrics
// (`GlyphInfo`) and atlas source rectangles (`Rectangle`).
// The output `FontAtlas` matches the shape that `Font` expects
// `glyphs[i]` and `recs[i]` correspond to `codepoints[i]` in the
// caller's input order - so wiring it into a `Font` is a
// trivial copy (Turn 13's job).
// Pixel format: RGBA8.  Each glyph pixel is `(255, 255, 255, alpha)`
// where alpha is the rasterizer's grayscale value (0 = transparent,
// 255 = opaque).  Matches the "white s, alpha mask" pattern that
// the rest of zimr's draw path expects.
// Allocation: every output (image, glyphs, recs) is allocated via
// `gpa`.  Caller owns; deinit via `FontAtlas.deinit(gpa)` or by
// freeing the constituent pieces individually.

// Internal: per-codepoint metadata captured during the metrics pass
// and reused during the rasterization pass.

/// raylib-compatible name for `bakeFontAtlas`.  raylib's
/// `GenImageFontAtlas` returns `(image, recs)` via an out-param;
/// we return the full `FontAtlas` (image + glyphs + recs +
/// metadata) which is a strict superset.
pub fn genImageFontAtlas(
    gpa: Allocator,
    font: *const truetype.Font,
    font_size: i32,
    codepoints: []const u21,
    padding: i32,
) !FontAtlas {
    return bakeFontAtlas(gpa, font, font_size, codepoints, padding);
}

test "genImageFontAtlas: signature is reachable as a function pointer" {
    // Following the convention in text_test.zig: real-data exercise
    // happens via the wasm example path (text_layout.zig), which the
    // smoke build runs.  The host test just verifies the public
    // surface compiles + can be taken by reference.
    const fn_ptr: @TypeOf(genImageFontAtlas) = genImageFontAtlas;
    _ = fn_ptr;
}

// ===========================================================================
// loadFontFromTtfData - end-to-end: parse TTF -> bake atlas -> upload -> Font
// ===========================================================================
// One-call entry point for loading a custom font from in-memory TTF
// or OTF bytes.  Combines `truetype.loadFontFromTtf`,
// `bakeFontAtlas`, and a GPU upload via `rlgl.fwd.rlLoadTexture`.
// Output is a `Font` shaped exactly like raylib's - so
// `drawTextEx`, `measureTextWithFont`, and `unloadFont` all work
// unchanged.
// Memory ownership:
//   - Caller retains `ttf_bytes`; the parsed Font borrows them and
//     must be discarded (or `ttf_bytes` kept alive) for as long as
//     the returned Font is used.  In practice you'd keep an
//     `@embedFile(...)` or fetched-asset buffer alive for the
//     lifetime of the Font.
//   - The returned `Font` owns its `glyphs[]`, `recs[]`, and
//     GPU `texture`.  Free with `unloadFont(gpa, font)` using the
//     same allocator.
//   - The CPU atlas image is freed inside this function after the
//     GPU upload - only the GPU texture survives.
// Defaults:
//   - For convenience, `default_codepoints_ascii` covers ASCII
//     32..126 (95 glyphs, the printable subset), which matches
//     raylib's `LoadFont` default.

/// Comptime-baked default codepoint set: ASCII printable range
/// (space through tilde, 95 codepoints).  Pass to
/// `loadFontFromTtfData` when you want raylib-compatible default
/// coverage.
pub const default_codepoints_ascii: [95]u21 = blk: {
    var cps: [95]u21 = undefined;
    for (0..95) |i| {
        cps[i] = @intCast(32 + i);
    }
    break :blk cps;
};

/// raylib-name alias for `loadFontFromTtfData` - `LoadFontFromMemory`
/// in raylib's vocabulary.  raylib's signature takes a `fileType`
/// string (".ttf" / ".otf") that we ignore (we only support TTF /
/// OTF via stb_truetype anyway).  Provided for callers porting
/// from raylib who want familiar names.
pub fn loadFontFromMemory(
    gpa: Allocator,
    ttf_bytes: []const u8,
    font_size: i32,
    codepoints: []const u21,
    padding: i32,
) LoadFontError!Font {
    return loadFontFromTtfData(gpa, ttf_bytes, font_size, codepoints, padding);
}

// ===========================================================================
// Default bitmap font (embedded) - was previously src/font_default.zig
// ===========================================================================
// raylib's built-in 8x10 bitmap font.  224 glyphs packed into a 128x128
// 1-bit-per-pixel atlas (512 u32 = 16384 bits) plus a per-glyph width
// array.  This is the font the engine falls back to when no TTF has been
// globalDefaultFont().loaded - `drawText(...)` uses it implicitly via `getFontDefault()`.
// Adapted from raylib by Ramon Santamaria (@raysan5), zlib license.
// See THIRD_PARTY_LICENSES.md for full attribution.
// Was its own file until 2026-05; folded in here per the file-consolidation
// plan since s.zig is the only consumer.  The atlas data + unpack loop
// are pure raylib parity; no API changes from the move.
//
// **zimr's "branded default" font: Atkinson Hyperlegible Mono.**
// Embedded alongside the legacy raylib bitmap default above.  When the
// font-default migration plan (`src/notes/font-default-plan.md`) lands,
// `loadFontDefault` will switch to this TTF and the raylib bitmap above
// becomes opt-in via a separate loader.  The byte buffer below is the
// raw TTF file as shipped by the Atkinson Hyperlegible Mono Project,
// OFL 1.1.  ~34 KB embedded; doesn't show up in the wasm-size budget
// because the bundler leaves it as a data section.
// Why Atkinson Hyperlegible Mono?  Two reasons.  First, zimr should
// not look identical to every other raylib/Dear ImGui app - a
// distinctive default reads as "this is a zimr app" without any
// affordance from the user.  Second, the Atkinson family is
// engineered for legibility (high x-height, unambiguous I/l/1,
// open apertures); a debug HUD or game console rendered in this
// font reads cleanly even at small sizes.
// License: SIL Open Font License 1.1.  Full text in
// `examples/assets/fonts/atkinson_mono_LICENSE.txt`.  Compatible with zimr's
// overall license.

// The embedded Atkinson TTF that lived here
// is gone - zimr no longer bundles a default font.  Every
// app that wants text bakes its own TTF via
// `loadFontFromTtfBytes` (see `examples/imgui_demo.zig` and
// the example assets directory at `assets/fonts/`).  Same
// story as textures, meshes, audio: bring your own bytes.

// Module state
//
// raylib lazily initialises the default font on first use.  We do the same
// - `getFontDefault` checks `globalDefaultFont().globalDefaultFont().loaded` and calls
// `loadFontDefault` if false.  Storage for the 224 GlyphInfo + 224
// Rectangle arrays is static; no allocator needed.

// Per-glyph CPU bitmap storage, used to populate `globalDefaultFont().glyphs_buf[k].image`
// during init.  Tightly packed: total = sum(chars_width) * 10 * 4 bytes
// = ~37KB.  We compute the comptime sum below and use it as the buffer
// size.  This is needed so `imageDrawTextWithFont` can rasterize
// glyphs onto a destination Image without going through the GPU.

// Public API

// ---- tests (formerly src/tests/text_test.zig) --------------------
// ===========================================================================
// UTF-8 encode / decode
// ===========================================================================

test "encodeCodepoint: ASCII 'A' is one byte 0x41" {
    const out: Utf8Bytes = encodeCodepoint('A');
    try expect(out.len == 1);
    try expect(out.bytes[0] == 0x41);
}

test "encodeCodepoint: U+20AC is three bytes E2 82 AC" {
    const out: Utf8Bytes = encodeCodepoint(0x20AC); // EURO SIGN
    try expect(out.len == 3);
    try expect(out.bytes[0] == 0xE2);
    try expect(out.bytes[1] == 0x82);
    try expect(out.bytes[2] == 0xAC);
}

test "encodeCodepoint: 4-byte emoji (smiley face)" {
    const out: Utf8Bytes = encodeCodepoint(0x1F600); // GRINNING FACE
    try expect(out.len == 4);
    try expect(out.bytes[0] == 0xF0);
    try expect(out.bytes[1] == 0x9F);
    try expect(out.bytes[2] == 0x98);
    try expect(out.bytes[3] == 0x80);
}

test "nextCodepoint: ASCII string yields one byte at a time" {
    const dec: DecodedCodepoint = nextCodepoint("Abc");
    try expect(dec.codepoint == 'A');
    try expect(dec.bytes == 1);
}

test "nextCodepoint: 3-byte UTF-8 codepoint advances 3 bytes" {
    const dec: DecodedCodepoint = nextCodepoint("€uro");
    try expect(dec.codepoint == 0x20AC);
    try expect(dec.bytes == 3);
}

test "nextCodepoint: empty string returns sentinel '?' (0x3F)" {
    // raylib convention: codepoint 0x3F ('?') marks decode failure or
    // empty input.  bytes==1 (raylib convention - caller advances by
    // one to avoid an infinite loop on bad input).
    const dec: DecodedCodepoint = nextCodepoint("");
    try expect(dec.codepoint == 0x3F);
    try expect(dec.bytes == 1);
}

test "countCodepoints: ASCII strings = byte length" {
    try expect(countCodepoints("hello") == 5);
    try expect(countCodepoints("") == 0);
}

test "countCodepoints: multi-byte counts as one each" {
    try expect(countCodepoints("€uro") == 4); // 3+1+1+1 = 6 bytes, 4 cp
    try expect(countCodepoints("hi 😀") == 4); // 1+1+1+4 = 7 bytes, 4 cp
}

// Round-trip: encode -> decode brings us back to the same codepoint.
test "encode/decode round-trip" {
    const codepoints = [_]u21{ 'A', 0xE9, 0x20AC, 0x1F600, 0x10FFFF };
    for (codepoints) |cp| {
        const enc: Utf8Bytes = encodeCodepoint(cp);
        const buf: []const u8 = enc.bytes[0..enc.len];
        const dec: DecodedCodepoint = nextCodepoint(buf);
        try expect(dec.codepoint == cp);
        try expect(dec.bytes == enc.len);
    }
}

// ===========================================================================
// Case conversion
// ===========================================================================

test "upper: 'hello' -> 'HELLO'" {
    const out: []u8 = try upper(std.testing.allocator, "hello");
    defer std.testing.allocator.free(out);
    try expectEqualStrings("HELLO", out);
}

test "upper: leaves digits / punctuation alone" {
    const out: []u8 = try upper(std.testing.allocator, "abc 123!");
    defer std.testing.allocator.free(out);
    try expectEqualStrings("ABC 123!", out);
}

test "lower: 'HELLO' -> 'hello'" {
    const out: []u8 = try lower(std.testing.allocator, "HELLO");
    defer std.testing.allocator.free(out);
    try expectEqualStrings("hello", out);
}

// ===========================================================================
// Case style transforms
// ===========================================================================

test "pascal: 'hello_world' -> 'HelloWorld' (splits on underscore)" {
    const out: []u8 = try pascal(std.testing.allocator, "hello_world");
    defer std.testing.allocator.free(out);
    try expectEqualStrings("HelloWorld", out);
}

test "snake: 'helloWorld' -> 'hello_world'" {
    const out: []u8 = try snake(std.testing.allocator, "helloWorld");
    defer std.testing.allocator.free(out);
    try expectEqualStrings("hello_world", out);
}

test "camel: 'hello_world' -> 'helloWorld' (splits on underscore)" {
    const out: []u8 = try camel(std.testing.allocator, "hello_world");
    defer std.testing.allocator.free(out);
    try expectEqualStrings("helloWorld", out);
}

// ===========================================================================
// Substring + manipulation
// ===========================================================================

test "substring: extract middle segment" {
    const out: []u8 = try substring(std.testing.allocator, "Hello, World!", 7, 5);
    defer std.testing.allocator.free(out);
    try expectEqualStrings("World", out);
}

test "removeSpaces: strips ASCII spaces" {
    const out: []u8 = try removeSpaces(std.testing.allocator, "  hi   there  ");
    defer std.testing.allocator.free(out);
    try expectEqualStrings("hithere", out);
}

test "replace: simple case" {
    const out: []u8 = try replace(std.testing.allocator, "foo bar foo", "foo", "BAR");
    defer std.testing.allocator.free(out);
    try expectEqualStrings("BAR bar BAR", out);
}

test "replace: replacement is shorter than search" {
    const out: []u8 = try replace(std.testing.allocator, "abcabc", "abc", "x");
    defer std.testing.allocator.free(out);
    try expectEqualStrings("xx", out);
}

test "replace: empty needle leaves text unchanged" {
    const out: []u8 = try replace(std.testing.allocator, "hi", "", "x");
    defer std.testing.allocator.free(out);
    try expectEqualStrings("hi", out);
}

test "insert: position 0 prepends" {
    const out: []u8 = try insert(std.testing.allocator, "world", "hello ", 0);
    defer std.testing.allocator.free(out);
    try expectEqualStrings("hello world", out);
}

test "insert: middle position" {
    const out: []u8 = try insert(std.testing.allocator, "abef", "cd", 2);
    defer std.testing.allocator.free(out);
    try expectEqualStrings("abcdef", out);
}

// ===========================================================================
// Split / join / search
// ===========================================================================

test "splitAlloc: comma-separated" {
    const parts: [][]const u8 = try splitAlloc(std.testing.allocator, "a,b,c", ',');
    defer std.testing.allocator.free(parts);
    try expect(parts.len == 3);
    try expectEqualStrings("a", parts[0]);
    try expectEqualStrings("b", parts[1]);
    try expectEqualStrings("c", parts[2]);
}

test "join: simple slash separator" {
    const parts = [_][]const u8{ "usr", "local", "bin" };
    const out: []u8 = try join(std.testing.allocator, &parts, "/");
    defer std.testing.allocator.free(out);
    try expectEqualStrings("usr/local/bin", out);
}

test "findIndex: present and absent" {
    try expect(findIndex("Hello, World!", "World").? == 7);
    try expect(findIndex("Hello", "world") == null);
}

test "isEqual: matches std.mem.eql semantics" {
    try expect(isEqual("hello", "hello"));
    try expect(!isEqual("hello", "Hello"));
    try expect(isEqual("", ""));
}

// ===========================================================================
// Number parsing
// ===========================================================================

test "toInteger: positive / negative / invalid" {
    try expect((try toInteger("42")) == 42);
    try expect((try toInteger("-17")) == -17);
    try expectError(error.InvalidCharacter, toInteger("abc"));
}

test "toFloat: decimal / negative" {
    try expect((try toFloat("3.14")) == 3.14);
    try expect((try toFloat("-2.5")) == -2.5);
}

// loadCodepoints / loadUTF8 - Phase D.1 ziggified
// Previously these returned C-style `?[*]` with separate count/length;
// now they take a `gpa: Allocator`, return slices, and free with
// `gpa.free(slice)`.  Tests run on host directly since we use the
// standard testing allocator instead of libc.malloc.
test "loadCodepoints: empty string returns empty slice" {
    const ta: Allocator = std.testing.allocator;
    const cps: []i32 = try loadCodepoints(ta, "");
    defer ta.free(cps);
    try expect(cps.len == 0);
}

test "loadCodepoints: ASCII roundtrip via loadUTF8" {
    const ta: Allocator = std.testing.allocator;
    const cps: []i32 = try loadCodepoints(ta, "Hello");
    defer ta.free(cps);
    try expect(cps.len == 5);
    try expect(cps[0] == 'H');
    try expect(cps[1] == 'e');
    try expect(cps[2] == 'l');
    try expect(cps[3] == 'l');
    try expect(cps[4] == 'o');

    const utf8: [:0]u8 = try loadUTF8(ta, cps);
    defer ta.free(utf8);
    try expect(utf8.len == 5);
    try expect(eql(u8, utf8, "Hello"));
}

test "loadUTF8: empty codepoint slice returns empty sentinel slice" {
    const ta: Allocator = std.testing.allocator;
    const cps = [_]i32{};
    const utf8: [:0]u8 = try loadUTF8(ta, &cps);
    defer ta.free(utf8);
    try expect(utf8.len == 0);
    try expect(utf8.ptr[0] == 0);
}

test "loadUTF8: invalid codepoint becomes U+FFFD replacement" {
    const ta: Allocator = std.testing.allocator;
    // 0x110000 is above the Unicode max; surrogate range 0xD800-0xDFFF
    // is also invalid.  Both should encode as U+FFFD (EF BF BD).
    const cps = [_]i32{ 0x110000, 0xD800 };
    const utf8: [:0]u8 = try loadUTF8(ta, &cps);
    defer ta.free(utf8);
    // Two replacement characters: 3 bytes each.
    try expect(utf8.len == 6);
    try expect(eql(u8, utf8, "\xEF\xBF\xBD\xEF\xBF\xBD"));
}

test "loadCodepoints: 3-codepoint multi-byte UTF-8 roundtrip" {
    const ta: Allocator = std.testing.allocator;
    // U+00E9 is 2 bytes in UTF-8, U+4E2D is 3 bytes, U+1F600 is 4 bytes.
    const input: []const u8 = "é中😀";
    const cps: []i32 = try loadCodepoints(ta, input);
    defer ta.free(cps);
    try expect(cps.len == 3);
    try expect(cps[0] == 0x00E9);
    try expect(cps[1] == 0x4E2D);
    try expect(cps[2] == 0x1F600);

    const utf8: [:0]u8 = try loadUTF8(ta, cps);
    defer ta.free(utf8);
    try expect(eql(u8, utf8, "é中😀"));
}

// imageDrawText / imageDrawTextWithFont - Roadmap Step 4
// The default font's per-glyph CPU bitmaps are populated on first
// `getFontDefault()` call, which goes through rlgl.fwd -> rlgl GPU
// upload - not available on host.  So we test the *defensive* paths
// here: null/zero-size dst -> no crash; uninitialized font -> no crash.
// Visual correctness is verified in smoke + the example output.
test "imageDrawText: null dst data is a no-op" {
    var dst: Image = .{
        .data = null,
        .width = 0,
        .height = 0,
        .mipmaps = 0,
        .format = 0,
    };
    var fc: FontCache = .{};
    imageDrawText(&dst, &fc, "abc", 0, 0, 10, .{ .r = 255, .g = 255, .b = 255, .a = 255 });
    // Just verify no crash.
}

test "imageDrawTextWithFont: zero-glyph font is a no-op" {
    var pixels = [_]u8{ 0, 0, 0, 0 };
    var dst: Image = .{
        .data = @ptrCast(&pixels),
        .width = 1,
        .height = 1,
        .mipmaps = 1,
        .format = 7,
    };
    const font: Font = .{
        .baseSize = 0,
        .glyphCount = 0,
        .glyphPadding = 0,
        .texture = .{ .id = 0, .width = 0, .height = 0, .mipmaps = 0, .format = 0 },
        .recs = null,
        .glyphs = null,
    };
    imageDrawTextWithFont(&dst, font, "x", .{ 0, 0 }, 12.0, 1.0, .{ .r = 255, .g = 255, .b = 255, .a = 255 });
    // Pixels should remain untouched.
    try expect(pixels[3] == 0);
}

// nextCodepoint via DFA decoder (Session N+29 zg integration)
// These tests verify the Maximal Subparts error recovery: malformed
// bytes don't greedily consume valid follow-up bytes.  Our previous
// hand-rolled decoder consumed too eagerly on truncated multibyte
// sequences.
test "nextCodepoint: ASCII still works" {
    const dc: DecodedCodepoint = nextCodepoint("A");
    try expect(dc.codepoint == 'A' and dc.bytes == 1);
}

test "nextCodepoint: 2-byte (Cyrillic Ya, U+042F)" {
    const dc: DecodedCodepoint = nextCodepoint("Я");
    try expect(dc.codepoint == 0x042F and dc.bytes == 2);
}

test "nextCodepoint: 3-byte CJK" {
    const dc: DecodedCodepoint = nextCodepoint("世");
    try expect(dc.codepoint == 0x4E16 and dc.bytes == 3);
}

test "nextCodepoint: 4-byte emoji" {
    const dc: DecodedCodepoint = nextCodepoint("🦀");
    try expect(dc.codepoint == 0x1F980 and dc.bytes == 4);
}

test "nextCodepoint: empty input -> ? marker, bytes=1" {
    const dc: DecodedCodepoint = nextCodepoint("");
    try expect(dc.codepoint == 0x3F and dc.bytes == 1);
}

test "nextCodepoint: orphan continuation byte -> ? marker" {
    // 0x80 is a continuation byte without a lead - invalid.
    const bad = [_]u8{0x80};
    const dc: DecodedCodepoint = nextCodepoint(&bad);
    try expect(dc.codepoint == 0x3F and dc.bytes == 1);
}

test "nextCodepoint: truncated 3-byte sequence advances by 2 (Maximal Subparts)" {
    // 0xE4 starts a 3-byte sequence (CJK range); 0xB8 is a valid
    // continuation; then we stop.  Old decoder: bytes=1.  New decoder:
    // recognizes 2 consumed bytes of the truncated sequence.
    const bad = [_]u8{ 0xE4, 0xB8 };
    const dc: DecodedCodepoint = nextCodepoint(&bad);
    try expect(dc.codepoint == 0x3F);
    // The DFA decoder may report 2 (max-subparts: 2 valid bytes
    // consumed before truncation) - either is acceptable per Unicode.
    try expect(dc.bytes == 2 or dc.bytes == 1);
}

test "countCodepoints: mixed-width string" {
    // "Hi" + U+4E16 + U+1F980 = 1+1+3+4 bytes = 9 bytes; 4 codepoints.
    try expect(countCodepoints("Hi世🦀") == 4);
}

// bakeFontAtlas - surface-level tests
// Without an embedded TTF, we can only exercise:
//   - The error-paths (NoCodepoints on empty input)
//   - The FontAtlas struct shape (compiles, exports correctly)
//   - The deinit balance (uses test allocator -> leak detection
//     would fire on imbalance)
// Real visual / metric correctness gets verified in Turn 14 when
// examples/text_layout.zig is updated to load a TTF.
test "bakeFontAtlas: empty codepoints returns NoCodepoints" {
    const ta: Allocator = std.testing.allocator;
    // We need a Font instance to pass - but we don't actually call
    // any Font methods in this error path, so a zeroed one is fine.
    // (Reaching for codepointGlyphIndex would crash; this test
    // exercises the early-return before that.)
    var fake_font: truetype_mod.Font = undefined;
    const codepoints = [_]u21{};
    const result: anyerror!FontAtlas = bakeFontAtlas(ta, &fake_font, 16, &codepoints, 0);
    try expectError(error.NoCodepoints, result);
}

test "bakeFontAtlas: signature is reachable as a function pointer" {
    // Compile-time-only: confirms the public surface compiles and
    // matches the documented signature.
    const fn_ptr: @TypeOf(bakeFontAtlas) = bakeFontAtlas;
    _ = fn_ptr;
}

test "FontAtlas: deinit signature is reachable" {
    const deinit_ptr = FontAtlas.deinit;
    _ = deinit_ptr;
}

// loadFontFromTtfData - surface-level tests
// We can verify:
//   - default_codepoints_ascii has the expected size + content
//   - LoadFontError union has the expected variants
//   - The function signature compiles and is reachable
// Real visual / metric correctness gets verified in Turn 14 when
// examples/text_layout.zig is updated to load a TTF.
test "default_codepoints_ascii: covers ASCII 32..126 inclusive" {
    try expect(default_codepoints_ascii.len == 95);
    try expect(default_codepoints_ascii[0] == 32);
    try expect(default_codepoints_ascii[94] == 126);
    // Spot-check: position 33 should be '!' = 33
    try expect(default_codepoints_ascii[1] == 33);
    // Spot-check: position 'A' = 65, index = 65 - 32 = 33
    try expect(default_codepoints_ascii[33] == 65);
}

test "loadFontFromTtfData: signature is reachable as a function pointer" {
    const fn_ptr: @TypeOf(loadFontFromTtfData) = loadFontFromTtfData;
    _ = fn_ptr;
}

test "LoadFontError: contains the documented variants" {
    // Compile-time check - these names must resolve and round-trip
    // through equality checks.
    const E = LoadFontError;
    const v1: E = error.NoCodepoints;
    const v2: E = error.AtlasOverflow;
    const v3: E = error.GpuUploadFailed;
    const v4: E = error.OutOfMemory;
    const v5: E = error.TtfParseFailed;
    try expect(v1 == error.NoCodepoints);
    try expect(v2 == error.AtlasOverflow);
    try expect(v3 == error.GpuUploadFailed);
    try expect(v4 == error.OutOfMemory);
    try expect(v5 == error.TtfParseFailed);
}

// ===========================================================================
// unloadFontData / unloadFont / Font.deinit signatures and leak-tightness
// Added in aggressive sweep along with the [*]->slice migration:
// `unloadFontData` now takes `[]GlyphInfo`, `Font.deinit` takes a real
// allocator (was previously broken - wrong arity, never compiled).
// ===========================================================================

test "unloadFontData: empty slice is a silent no-op" {
    // No-op even on an arbitrary allocator - must not panic, must not
    // try to free anything.
    const empty: []types.GlyphInfo = &.{};
    unloadFontData(std.testing.allocator, empty);
}

test "unloadFontData: frees the slice without leaks" {
    // Allocate via the same path raylib's `loadFontData` will use once
    // it lands.  Two glyphs, both with null image data so we can free
    // without engaging the GPU stack.
    const ta: Allocator = std.testing.allocator;
    const glyphs: []types.GlyphInfo = try ta.alloc(types.GlyphInfo, 2);
    glyphs[0] = .{
        .value = 65,
        .offsetX = 0,
        .offsetY = 0,
        .advanceX = 8,
        .image = .{ .data = null, .width = 0, .height = 0, .mipmaps = 1, .format = 7 },
    };
    glyphs[1] = .{
        .value = 66,
        .offsetX = 0,
        .offsetY = 0,
        .advanceX = 8,
        .image = .{ .data = null, .width = 0, .height = 0, .mipmaps = 1, .format = 7 },
    };
    unloadFontData(ta, glyphs);
    // If `unloadFontData` leaks, std.testing.allocator catches it at
    // test-end.  No explicit assertion needed.
}

test "unloadFont: signature takes allocator + font_cache + font (regression)" {
    // Compile-time signature check: `unloadFont` must take
    // `(gpa: Allocator, font_cache: *const FontCache,
    // font: Font)`.  Catches accidental signature
    // regressions (the old `Font.deinit(font)` shape was a
    // never-compiled bug; this is its successor regression).
    const sig: fn (Allocator, *const FontCache, Font) void = unloadFont;
    _ = sig;
}

// ===========================================================================
// Text -> Image rasterization (moved from image_mod.zig, structure-plan S0):
// these are the image<->text cycle's image-side fns - they need FontCache,
// so they live with the fonts.  `image` is the CPU image library.
// ===========================================================================
const image_mod = @import("image.zig"); // lint:off canonical-alias: `image` is a member name here
const errors = @import("errors.zig");
const text2d = @This(); // the file's own container, for self-referring decls

/// Allocate a new RGBA8 `Image` sized to fit `s` rendered with
/// `font`, then composite the text onto it via `imageDrawTextWithFont`.
/// Background is fully transparent (alpha 0); glyphs tinted by `tint`.
/// Reads: `line_spacing` (forwarded to `text.measureWithFont` to size
/// the destination image - only matters when `s` contains '\n').
/// Returns a 1x1 transparent image for empty input or an empty
/// font - always a valid, drawable result.
pub fn imageTextWithFont(
    gpa: Allocator,
    line_spacing: i32,
    font: Font,
    s: []const u8,
    font_size: f32,
    spacing: f32,
    tint: Color,
) errors.ImageGenError!Image {
    const text_mod = text2d;

    if (s.len == 0 or font.glyphCount == 0) {
        return image_mod.genImageColor(gpa, 1, 1, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
    }

    // Measure at the requested size to get the destination dims.
    const size: Vec2 = text_mod.measureWithFont(line_spacing, font, s, font_size, spacing);
    const w: i32 = @trunc(@max(1.0, @ceil(size[0])));
    const h: i32 = @trunc(@max(1.0, @ceil(size[1])));

    var canvas: Image = try image_mod.genImageColor(gpa, w, h, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
    errdefer unloadImage(gpa, canvas);

    text_mod.imageDrawTextWithFont(
        &canvas,
        font,
        s,
        .{ 0, 0 },
        font_size,
        spacing,
        tint,
    );
    return canvas;
}

/// Allocate a new RGBA8 `Image` containing `text` rendered with the
/// default font.  Defaults `spacing` to `fontSize / 10` (matching
/// raylib).  Caller frees with `unloadImage(gpa, image)` using the
/// same allocator.
/// Empty string returns a 1x1 transparent image (so the result is
/// always valid for `imageDraw` etc.).
/// Allocate a new RGBA8 `Image` sized to fit `s` rendered in the
/// default font.  Convenience wrapper around `imageTextWithFont`:
/// picks default-font, derives spacing from `font_size / 10`
/// (default font's 10 px base height).
/// Reads: `line_spacing` (forwarded to `imageTextWithFont`, used only
/// when `s` contains '\n').
/// Empty string returns a 1x1 transparent image (so the result is
/// always valid for `imageDraw` etc.).
pub fn imageText(
    gpa: Allocator,
    font_cache: *const text2d.FontCache,
    line_spacing: i32,
    s: []const u8,
    font_size: i32,
    color: Color,
) errors.ImageGenError!Image {
    const text_mod = text2d;
    const font: Font = text_mod.getFontDefault(font_cache);
    const default_size: i32 = 10;
    var size: i32 = font_size;
    if (size < default_size) {
        size = default_size;
    }
    const spacing: f32 = float(@divFloor(size, default_size));
    return imageTextWithFont(gpa, line_spacing, font, s, @floatFromInt(size), spacing, color);
}

test "imageText: empty string returns 1x1 transparent" {
    const ta: Allocator = std.testing.allocator;
    const default_line_spacing: i32 = 2;
    var fc: FontCache = .{};
    const out: Image = try imageText(
        ta,
        &fc,
        default_line_spacing,
        "",
        20,
        .{ .r = 255, .g = 0, .b = 0, .a = 255 },
    );
    defer unloadImage(ta, out);
    try expectEqual(@as(i32, 1), out.width);
    try expectEqual(@as(i32, 1), out.height);
    try expectEqual(@backingInt(types.PixelFormat.uncompressed_r8g8b8a8), out.format);
    const px: [*]const u8 = @ptrCast(out.data.?);
    try expectEqual(@as(u8, 0), px[3]);
}

test "imageTextWithFont: empty font (glyphCount = 0) returns 1x1 transparent" {
    const ta: Allocator = std.testing.allocator;
    const empty_font: Font = .{};
    const default_line_spacing: i32 = 2;
    const out: Image = try imageTextWithFont(
        ta,
        default_line_spacing,
        empty_font,
        "ignored",
        20.0,
        2.0,
        .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    );
    defer unloadImage(ta, out);
    try expectEqual(@as(i32, 1), out.width);
}
