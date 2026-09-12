//! native_verify — the shadow-map side-by-side's NATIVE gate.
//!
//! Builds `scene.bakeCorner` twice from the SAME function:
//!   1. at COMPTIME (the const below) — building this exe IS the corner's
//!      compile-time-budget gate, and exactly what the wasm app embeds;
//!   2. at RUNTIME in `main` — instant, and byte-compared against (1), a
//!      differential that pins the compiler's evaluation of the whole
//!      two-pass render to the runtime evaluation of the same code.
//!
//! It then sanity-checks the images (a real shadow map was written; the lit
//! image contains both lit and shadowed regions) and dumps them as PNGs for
//! eyeball verification: `zig build shadowmap-sw-verify`.

const std = @import("std");
const z = @import("zimr");
const zm = @import("zm");
const scene = @import("scene.zig");
const bunny_proxy = @import("bunny_proxy");
const Allocator = std.mem.Allocator;
const float = zm.float;

const sm_res: usize = 8;
const img_w: usize = 8;
const img_h: usize = 8;

/// The comptime bake — the same dimensions the wasm app's corner uses.
const baked: scene.CornerBake(sm_res, img_w, img_h) = blk: {
    @setEvalBranchQuota(2_000_000_000);
    break :blk scene.bakeCorner(sm_res, img_w, img_h);
};

fn luminance(c0: u8, c1: u8, c2: u8) f32 {
    return 0.299 * float(c0) + 0.587 * float(c1) + 0.114 * float(c2);
}

pub fn main() !void {
    const gpa: Allocator = std.heap.page_allocator;
    var io_threaded: std.Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();
    const io: std.Io = io_threaded.io();

    // ---- runtime evaluation of the SAME bake function ----
    const live: scene.CornerBake(sm_res, img_w, img_h) = scene.bakeCorner(sm_res, img_w, img_h);

    // ---- differential: comptime vs runtime, byte for byte ----
    var sm_diff: usize = 0;
    for (baked.shadow_map, live.shadow_map) |a, b| {
        if (a != b) {
            sm_diff += 1;
        }
    }
    var img_diff: usize = 0;
    for (baked.image, live.image) |a, b| {
        if (a != b) {
            img_diff += 1;
        }
    }

    // ---- image sanity: geometry reached the map; shadows + light exist ----
    var min_red: u8 = 255;
    var i: usize = 0;
    while (i < sm_res * sm_res) : (i += 1) {
        if (baked.shadow_map[i * 4] < min_red) {
            min_red = baked.shadow_map[i * 4];
        }
    }
    var shadow_px: u32 = 0;
    var lit_px: u32 = 0;
    var j: usize = 0;
    while (j < img_w * img_h) : (j += 1) {
        const l: f32 = luminance(baked.image[j * 4], baked.image[j * 4 + 1], baked.image[j * 4 + 2]);
        if (l >= 25 and l <= 85) {
            shadow_px += 1;
        }
        if (l >= 120 and l <= 215) {
            lit_px += 1;
        }
    }

    std.debug.print("shadowmap_sw corner: comptime bake vs runtime render of scene.bakeCorner\n", .{});
    std.debug.print("  proxy {d} verts / {d} tris; shadow map {d}x{d}; image {d}x{d}\n", .{
        bunny_proxy.vertex_count,
        bunny_proxy.indices.len / 3,
        sm_res,
        sm_res,
        img_w,
        img_h,
    });
    std.debug.print("  differential: shadow-map bytes differing {d}, image bytes differing {d}\n", .{
        sm_diff,
        img_diff,
    });
    std.debug.print("  shadow-map min red {d} (want <240); lit-band {d} px, shadow-band {d} px (want >0)\n", .{
        min_red,
        lit_px,
        shadow_px,
    });

    const lit_png: []u8 = try z.codecs.png.encode(gpa, &baked.image, img_w, img_h);
    defer gpa.free(lit_png);
    const sm_png: []u8 = try z.codecs.png.encode(gpa, &baked.shadow_map, sm_res, sm_res);
    defer gpa.free(sm_png);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "corner_lit.png", .data = lit_png });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "corner_shadowmap.png", .data = sm_png });
    std.debug.print("  wrote corner_lit.png + corner_shadowmap.png\n", .{});

    if (sm_diff != 0 or img_diff != 0) {
        return error.ComptimeRuntimeMismatch;
    }
    if (min_red >= 240 or shadow_px == 0 or lit_px == 0) {
        return error.CornerLooksWrong;
    }
    std.debug.print("  OK\n", .{});
}
