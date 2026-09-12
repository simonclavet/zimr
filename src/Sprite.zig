//! lint:alias Sprite
//! Sprite — a portable, pixel-owning 2D image handle drawable on ANY backend
//! (immediate GPU, retained DrawList, or CPU Canvas). It owns a copy of the CPU
//! pixels; each backend caches its own residency (a GPU bind group, or nothing
//! for Canvas) keyed by the monotonic `.id`. This is the seam that lets one
//! `fn draw(sink: anytype)` scene sample the same texture on every backend.
//! See notes/drawing_api.md.

const std = @import("std");
const types = @import("types.zig");
const image_mod = @import("image.zig"); // lint:off canonical-alias: `image` is a member name here

const Image = types.Image;
const Allocator = std.mem.Allocator;

// Monotonic id source for per-backend residency caches; 0 is reserved as "none".
var next_id: u64 = 1; // lint:off module-var: monotonic Sprite id source for residency caches

const Sprite = @This();

/// Unique across the process; backends key their residency cache on this.
id: u64,
/// Owned CPU pixels (a deep copy of the source image).
image: Image,

/// Build a Sprite owning a copy of `src`'s pixels. Free with `deinit`. The
/// source `Image` may be freed immediately after.
pub fn fromImage(gpa: Allocator, src: Image) !Sprite {
    const owned: Image = try image_mod.imageCopy(gpa, src);
    const id: u64 = next_id;
    next_id += 1;
    return .{ .id = id, .image = owned };
}

pub fn deinit(self: *Sprite, gpa: Allocator) void {
    image_mod.unloadImage(gpa, self.image);
    self.* = undefined;
}

pub fn width(self: Sprite) i32 {
    return self.image.width;
}

pub fn height(self: Sprite) i32 {
    return self.image.height;
}
