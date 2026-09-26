//! native_verify - render the cel_shading example's ACTUAL look on the
//! CPU, no GPU required.
//!
//! Both passes run the same `shaderMain`s the wasm app compiles to WGSL:
//! the inverted hull (`outline_hull_vs` + `depth_fs`, back faces only)
//! and the toon pass (`gbuffer_vs` + `cel_fs`, front faces only) - two
//! `rasterizeToTarget` draws into one buffer, exactly the GPU pass
//! shape.  Dumps `cel_verify.png` for eyeballing and asserts the three
//! tonal populations exist: paper-bright background, full-brightness top
//! band, and ink.  `zig build cel-shading-verify`.

const std = @import("std");
const z = @import("zimr");
const zm = @import("zm");
const proxy = @import("bunny_proxy");
const Allocator = std.mem.Allocator;
const Mat = zm.Mat;
const Vec = zm.Vec;
const float = zm.float;
const lookAtRh = zm.lookAtRh;
const mulMat = zm.mulMat;
const perspectiveFovRh = zm.perspectiveFovRh;
const scaling = zm.scaling;
const translation = zm.translation;
const vec = zm.vec;

const toon_vs = z.deferred_shaders.gbuffer_vs;
const toon_fs = z.toon_shaders.cel_fs;
const hull_vs = z.toon_shaders.outline_hull_vs;
const ink_fs = z.shadow_shaders.depth_fs;

const img_w: usize = 480;
const img_h: usize = 360;

const bunny_albedo: [4]f32 = .{ 0.95, 0.62, 0.35, 1 };
const ink_color: [4]f32 = .{ 0.05, 0.05, 0.06, 1 };
const bands: f32 = 4.0;
const ink_world: f32 = 0.015;

pub fn main() !void {
    const gpa: Allocator = std.heap.page_allocator;
    var io_threaded: std.Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();
    const io: std.Io = io_threaded.io();

    // ---- proxy bunny, measured + framed like the app ----
    var mn: [3]f32 = .{ 1.0e30, 1.0e30, 1.0e30 };
    var mx: [3]f32 = .{ -1.0e30, -1.0e30, -1.0e30 };
    for (proxy.positions) |p| {
        var a: usize = 0;
        while (a < 3) : (a += 1) {
            mn[a] = @min(mn[a], p[a]);
            mx[a] = @max(mx[a], p[a]);
        }
    }
    const scale: f32 = 2.2 / @max(mx[1] - mn[1], 1.0e-4);
    const center_it: Mat = translation(-(mn[0] + mx[0]) * 0.5, -mn[1], -(mn[2] + mx[2]) * 0.5);
    const model: Mat = mulMat(scaling(scale, scale, scale), center_it);

    const cam_eye: Vec = vec(3.2, 2.6, 4.2);
    const view: Mat = lookAtRh(cam_eye, vec(0, 1.0, 0), vec(0, 1, 0));
    const projection: Mat = perspectiveFovRh(0.8, float(img_w) / float(img_h), 0.1, 100.0);
    const mvp: Mat = mulMat(mulMat(projection, view), model);

    // Sun roughly camera-side (the photogenic frame - most bands visible).
    const sun: [3]f32 = .{ 0.55, 1.0, 0.75 };

    // ---- vertex loops through the real shaders ----
    var toon_outs: [proxy.vertex_count]toon_vs.Out = undefined;
    var hull_outs: [proxy.vertex_count]hull_vs.Out = undefined;
    {
        var vio: toon_vs.Io = undefined;
        vio.u = .{ .mvp = mvp, .model = model, .normal_matrix = zm.identity() };
        for (proxy.positions, proxy.normals, &toon_outs) |p, n, *out| {
            vio.vertex_position = .{ p[0], p[1], p[2] };
            vio.vertex_normal = .{ n[0], n[1], n[2] };
            out.* = toon_vs.shaderMain(vio);
        }
    }
    {
        var hio: hull_vs.Io = undefined;
        hio.u = .{ .mvp = mvp, .ink_color = ink_color, .params = .{ ink_world / scale, 0, 0, 0 } };
        for (proxy.positions, proxy.normals, &hull_outs) |p, n, *out| {
            hio.vertex_position = .{ p[0], p[1], p[2] };
            hio.vertex_normal = .{ n[0], n[1], n[2] };
            out.* = hull_vs.shaderMain(hio);
        }
    }
    var indices: [proxy.indices.len]u32 = undefined;
    for (proxy.indices, &indices) |i16v, *i32v| {
        i32v.* = i16v;
    }

    // ---- the pass: clear paper, ink hull (back faces), toon (front) ----
    var img: [img_w * img_h][4]u8 = @splat(.{ 245, 245, 246, 255 });
    var depth: [img_w * img_h]f32 = @splat(1.0);

    const connect_ink: fn (hull_vs.Out, *ink_fs.Io) void = z.shader.autoConnect(hull_vs.Out, ink_fs.Io);
    const ink_io: ink_fs.Io = undefined;
    z.raster_shader.rasterizeToTarget(
        hull_vs,
        ink_fs,
        img_w,
        img_h,
        &hull_outs,
        &indices,
        ink_io,
        connect_ink,
        .{ .front_face = .cw, .depth_test = true }, // BACK faces only - the hull trick
        &img,
        &depth,
    );

    const connect_toon: fn (toon_vs.Out, *toon_fs.Io) void = z.shader.autoConnect(toon_vs.Out, toon_fs.Io);
    var toon_io: toon_fs.Io = undefined;
    toon_io.u = .{
        .base_color = bunny_albedo,
        .light_dir = .{ sun[0], sun[1], sun[2], 0 },
        .params = .{ bands, 0, 0, 0 },
    };
    z.raster_shader.rasterizeToTarget(
        toon_vs,
        toon_fs,
        img_w,
        img_h,
        &toon_outs,
        &indices,
        toon_io,
        connect_toon,
        .{ .front_face = .ccw, .depth_test = true },
        &img,
        &depth,
    );

    // ---- tonal census: paper / top band / ink must all exist ----
    var paper: u32 = 0;
    var bright_band: u32 = 0;
    var ink_px: u32 = 0;
    for (img) |px| {
        const lum: f32 = 0.299 * float(px[0]) + 0.587 * float(px[1]) + 0.114 * float(px[2]);
        if (lum > 240) {
            paper += 1;
        } else if (lum > 130 and lum < 200) {
            bright_band += 1; // full-brightness orange ~ lum 170
        } else if (lum < 25) {
            ink_px += 1;
        }
    }
    std.debug.print("cel_verify: paper {d} px, top-band {d} px, ink {d} px (all must be >0)\n", .{
        paper,
        bright_band,
        ink_px,
    });

    const png: []u8 = try z.codecs.png.encode(gpa, @ptrCast(&img), img_w, img_h);
    defer gpa.free(png);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "cel_verify.png", .data = png });
    std.debug.print("  wrote cel_verify.png\n", .{});

    if (paper == 0 or bright_band == 0 or ink_px == 0) {
        return error.CelLookWrong;
    }
    std.debug.print("  OK\n", .{});
}
