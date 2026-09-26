//! lint:alias glyph_atlas
//! src/glyph_atlas.zig - the CPU half of the glyph cache: which rasterized glyph
//! lives where, and the shelf packer that places new ones.
//!
//! WHY IT EXISTS. A baked font atlas freezes every glyph at one pixel size, picked
//! when the font loads. Text drawn at any other on-screen size is then RESAMPLED
//! from it: magnified (blurry once a window grows, goes fullscreen, or a `.fit`
//! app scales up) or minified (soft, grey small text). A browser never does that:
//! it lays text out in CSS px and rasterizes each glyph at the DEVICE-pixel size
//! it actually lands at. zimr now does the same - `text2d`'s dynamic path
//! rasterizes a glyph the first time it is drawn at a given device size and keeps
//! it here, so every later draw at that size is a 1:1 copy.
//!
//! One atlas serves every font (entries are keyed by `FontFace.id`), so text runs
//! batch across fonts and the memory is bounded once for the whole app. The GPU
//! pages live with the renderer that owns this struct (`Renderer2D`); this file
//! holds no GPU state, which is what makes it unit-testable on the host.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

/// Side of one atlas page, in texels. 1024^2 RGBA8 is 4 MB of GPU memory.
pub const page_size: u32 = 1024;
/// Pages the atlas may fill before it starts over (see `GlyphAtlas.beginFrame`).
/// Four pages hold ASCII at dozens of sizes; running out takes text that keeps
/// changing size every frame, and then starting over is the right answer anyway.
pub const page_max: u32 = 4;
/// Transparent texels around every glyph, so filtering at a glyph's edge (a
/// scaled or rotated draw) reads nothing, never its neighbour.
pub const border: u32 = 1;

/// One cached glyph: a glyph of one face, rasterized at one size and one
/// horizontal sub-pixel offset.
pub const Key = struct {
    /// `text2d.FontFace.id` - a counter, never reused.
    face_id: u32,
    /// Index into the font's glyph arrays (`Font.glyphs`).
    slot: u32,
    /// Rasterized size in QUARTER device pixels.
    size_quarters: u32,
    /// Horizontal sub-pixel offset the outline was shifted by before
    /// rasterizing, in quarter pixels (0..3).
    phase: u32,
};

/// Where a cached glyph's bitmap is, and how it sits on the pen.
pub const Entry = struct {
    page: u32 = 0,
    /// The bitmap in its page, border excluded. Zero-sized for a glyph with no
    /// ink (a space): cached anyway, so it is not re-rasterized every draw.
    x: u32 = 0,
    y: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    /// Bitmap top-left relative to the pen on the baseline, in device pixels.
    offset_x: i32 = 0,
    offset_y: i32 = 0,
};

/// A bordered rectangle `reserve` handed out: its page and top-left texel.
pub const Slot = struct { page: u32, x: u32, y: u32 };

/// A row of glyphs: every glyph on it fits its height and fills most of it.
const Shelf = struct { page: u32, y: u32, height: u32, x_next: u32 };

pub const GlyphAtlas = struct {
    entries: std.AutoHashMapUnmanaged(Key, Entry) = .empty,
    shelves: ArrayList(Shelf) = .empty,
    /// Pages holding glyphs. New shelves open on the last one.
    pages_used: u32 = 0,
    /// First free row on the last page.
    page_y_next: u32 = 0,
    /// A glyph did not fit. The atlas cannot start over mid-frame - quads
    /// recorded earlier this frame still point into it - so `beginFrame` does.
    reset_requested: bool = false,
    /// Rasterization scratch (8-bit coverage, then the bordered RGBA upload),
    /// reused glyph after glyph.
    coverage: ArrayList(u8) = .empty,
    upload: ArrayList(u8) = .empty,

    pub fn deinit(atlas: *GlyphAtlas, gpa: Allocator) void {
        atlas.entries.deinit(gpa);
        atlas.shelves.deinit(gpa);
        atlas.coverage.deinit(gpa);
        atlas.upload.deinit(gpa);
        atlas.* = .{};
    }

    /// Call at the top of every frame, before any text is drawn. Starts the
    /// atlas over if the previous frame ran out of room. The GPU pages are kept
    /// (the owner reuses them); every glyph written afterwards overwrites its
    /// whole bordered rectangle, so nothing stale can show.
    pub fn beginFrame(atlas: *GlyphAtlas) void {
        if (!atlas.reset_requested) {
            return;
        }
        atlas.entries.clearRetainingCapacity();
        atlas.shelves.clearRetainingCapacity();
        atlas.pages_used = 0;
        atlas.page_y_next = 0;
        atlas.reset_requested = false;
    }

    pub fn find(atlas: *const GlyphAtlas, key: Key) ?Entry {
        return atlas.entries.get(key);
    }

    pub fn remember(
        atlas: *GlyphAtlas,
        gpa: Allocator,
        key: Key,
        entry: Entry,
    ) Allocator.Error!void {
        try atlas.entries.put(gpa, key, entry);
    }

    /// Find room for a `width` x `height` bitmap plus its border. Returns the
    /// bordered slot, or null when every page is full - and then asks for a
    /// reset at the next `beginFrame`.
    pub fn reserve(
        atlas: *GlyphAtlas,
        gpa: Allocator,
        width: u32,
        height: u32,
    ) ?Slot {
        const slot_width: u32 = width + 2 * border;
        const slot_height: u32 = height + 2 * border;
        const fits_on_a_page: bool = slot_width <= page_size and slot_height <= page_size;
        if (!fits_on_a_page) {
            return null;
        }
        for (atlas.shelves.items) |*shelf| {
            const shelf_is_tall_enough: bool = slot_height <= shelf.height;
            // A short glyph in a much taller shelf wastes the rest of that row's
            // height for as long as the atlas lives.
            const glyph_fills_shelf: bool = slot_height * 4 >= shelf.height * 3;
            const row_has_room: bool = shelf.x_next + slot_width <= page_size;
            if (shelf_is_tall_enough and glyph_fills_shelf and row_has_room) {
                const slot: Slot = .{ .page = shelf.page, .x = shelf.x_next, .y = shelf.y };
                shelf.x_next += slot_width;
                return slot;
            }
        }
        // A new shelf, a little taller than this glyph so the glyphs of about
        // its height (the rest of a font at one size) can share it.
        const shelf_height: u32 = @min(slot_height + slot_height / 8, page_size);
        const last_page_has_room: bool = atlas.pages_used > 0 and
            atlas.page_y_next + shelf_height <= page_size;
        if (!last_page_has_room) {
            const all_pages_used: bool = atlas.pages_used >= page_max;
            if (all_pages_used) {
                atlas.reset_requested = true;
                return null;
            }
            atlas.pages_used += 1;
            atlas.page_y_next = 0;
        }
        const page: u32 = atlas.pages_used - 1;
        atlas.shelves.append(gpa, .{
            .page = page,
            .y = atlas.page_y_next,
            .height = shelf_height,
            .x_next = slot_width,
        }) catch return null;
        const slot: Slot = .{ .page = page, .x = 0, .y = atlas.page_y_next };
        atlas.page_y_next += shelf_height;
        return slot;
    }
};

/// Two slots overlap (texel rectangles on the same page).
fn slotsOverlap(
    a: Slot,
    a_size: [2]u32,
    b: Slot,
    b_size: [2]u32,
) bool {
    const same_page: bool = a.page == b.page;
    const x_overlap: bool = a.x < b.x + b_size[0] and b.x < a.x + a_size[0];
    const y_overlap: bool = a.y < b.y + b_size[1] and b.y < a.y + a_size[1];
    return same_page and x_overlap and y_overlap;
}

test "reserve: slots never overlap and stay on the page" {
    const gpa: Allocator = std.testing.allocator;
    var atlas: GlyphAtlas = .{};
    defer atlas.deinit(gpa);
    var slots: [300]Slot = undefined;
    var sizes: [300][2]u32 = undefined;
    // Glyph-like sizes: a font at a few sizes, tall and short glyphs mixed.
    for (&slots, &sizes, 0..) |*slot, *size, i| {
        const width: u32 = 4 + @as(u32, @intCast((i * 7) % 23));
        const height: u32 = 6 + @as(u32, @intCast((i * 11) % 31));
        slot.* = atlas.reserve(gpa, width, height).?;
        size.* = .{ width + 2 * border, height + 2 * border };
        try expect(slot.x + size[0] <= page_size);
        try expect(slot.y + size[1] <= page_size);
    }
    for (slots, sizes, 0..) |a, a_size, i| {
        for (slots[i + 1 ..], sizes[i + 1 ..]) |b, b_size| {
            try expect(!slotsOverlap(a, a_size, b, b_size));
        }
    }
}

test "reserve: a full atlas refuses, requests a reset, and beginFrame performs it" {
    const gpa: Allocator = std.testing.allocator;
    var atlas: GlyphAtlas = .{};
    defer atlas.deinit(gpa);
    // Half-page glyphs: a page holds only a few, so a handful fills the atlas.
    const half: u32 = page_size / 2 - 2 * border;
    var placed: u32 = 0;
    while (atlas.reserve(gpa, half, half)) |_| {
        placed += 1;
    }
    try expect(placed >= page_max);
    try expect(atlas.reset_requested);
    try expectEqual(page_max, atlas.pages_used);

    try atlas.remember(gpa, .{ .face_id = 1, .slot = 0, .size_quarters = 64, .phase = 0 }, .{});
    atlas.beginFrame();
    try expect(!atlas.reset_requested);
    try expectEqual(@as(u32, 0), atlas.pages_used);
    try expect(atlas.find(.{ .face_id = 1, .slot = 0, .size_quarters = 64, .phase = 0 }) == null);
    try expect(atlas.reserve(gpa, half, half) != null);
}

test "reserve: a glyph larger than a page is refused without a reset" {
    const gpa: Allocator = std.testing.allocator;
    var atlas: GlyphAtlas = .{};
    defer atlas.deinit(gpa);
    try expect(atlas.reserve(gpa, page_size, 10) == null);
    try expect(!atlas.reset_requested);
}

test "find/remember: entries are keyed by face, slot, size and phase" {
    const gpa: Allocator = std.testing.allocator;
    var atlas: GlyphAtlas = .{};
    defer atlas.deinit(gpa);
    const key: Key = .{ .face_id = 3, .slot = 12, .size_quarters = 64, .phase = 2 };
    try atlas.remember(gpa, key, .{ .page = 1, .x = 5, .y = 6, .width = 7, .height = 8 });
    try expectEqual(@as(u32, 5), atlas.find(key).?.x);
    const other_phase: Key = .{ .face_id = 3, .slot = 12, .size_quarters = 64, .phase = 1 };
    try expect(atlas.find(other_phase) == null);
    const other_face: Key = .{ .face_id = 4, .slot = 12, .size_quarters = 64, .phase = 2 };
    try expect(atlas.find(other_face) == null);
}
