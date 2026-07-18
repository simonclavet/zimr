//! native_verify — render the hybrid example's raymarched scene on the
//! CPU through the same `shaderMain` the wasm compiles to WGSL, dump
//! `hybrid_verify.png`, and assert the three visual populations exist:
//! sky, checkerboard floor (two distinct grays), and hot metaball
//! pixels.  `zig build hybrid-render-verify`.
//!
//! (The CPU rasterizer reads the FS's `final_color` and ignores its
//! `frag_depth` — depth agreement with raster geometry is exercised on
//! the GPU; this harness verifies the marcher LOOKS right first.)

const std = @import("std");
const z = @import("zimr");
const zm = @import("zm");
const Allocator = std.mem.Allocator;
const Vec = zm.Vec;
const cross = zm.cross;
const lookAtRh = zm.lookAtRh;
const mulMat = zm.mulMat;
const perspectiveFovRh = zm.perspectiveFovRh;
const float = zm.float;
const normalize = zm.normalize;
const vec = zm.vec;

const quad_vs = z.deferred_shaders.shading_vs;
const march_fs = z.hybrid_raymarch_shader;

const img_w: usize = 320;
const img_h: usize = 220;
const fov_y: f32 = 0.9;

const quad_positions = [_][2]f32{
    .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 },
    .{ -1, -1 }, .{ 1, 1 },  .{ -1, 1 },
};
const quad_indices = [_]u32{ 0, 1, 2, 3, 4, 5 };

pub fn main() !void {
    const gpa: Allocator = std.heap.page_allocator;
    var io_threaded: std.Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();
    const io: std.Io = io_threaded.io();

    // The example's camera at a frozen, photogenic instant.
    const t: f32 = 1.4;
    const cam_eye: Vec = vec(4.6, 3.2, 4.6);
    const cam_target: Vec = vec(0, 1.0, 0);
    const aspect: f32 = float(img_w) / float(img_h);
    const view: zm.Mat = lookAtRh(cam_eye, cam_target, vec(0, 1, 0));
    const proj: zm.Mat = perspectiveFovRh(fov_y, aspect, 0.1, 100.0);
    const vp: zm.Mat = mulMat(proj, view);
    const fwd: Vec = normalize(cam_target - cam_eye);
    const right: Vec = normalize(cross(fwd, vec(0, 1, 0)));
    const up: Vec = normalize(cross(right, fwd));

    var outs: [6]quad_vs.Out = undefined;
    var vio: quad_vs.Io = undefined;
    for (quad_positions, &outs) |p, *o| {
        vio.vertex_ndc_pos = .{ p[0], p[1] };
        o.* = quad_vs.shaderMain(vio);
    }

    var fio: march_fs.Io = undefined;
    fio.u = .{
        .vp = vp,
        .view_pos = .{ cam_eye[0], cam_eye[1], cam_eye[2], 0 },
        .cam_right = .{ right[0], right[1], right[2], 0 },
        .cam_up = .{ up[0], up[1], up[2], 0 },
        .cam_fwd = .{ fwd[0], fwd[1], fwd[2], @tan(fov_y * 0.5) },
        .params = .{ aspect, t, 0, 0 },
    };
    const connect: fn (quad_vs.Out, *march_fs.Io) void = z.shader.autoConnect(quad_vs.Out, march_fs.Io);
    const img: [img_w * img_h][4]u8 = z.raster_shader.rasterizeToImage(
        quad_vs,
        march_fs,
        img_w,
        img_h,
        &outs,
        &quad_indices,
        fio,
        connect,
        .{ .front_face = .none, .depth_test = false },
        .{ 0, 0, 0, 255 },
    );

    // ---- census: sky / two floor grays / hot blob pixels ----
    var sky: u32 = 0;
    var floor_light: u32 = 0;
    var floor_dark: u32 = 0;
    var blob: u32 = 0;
    for (img) |px| {
        const r: i32 = px[0];
        const g: i32 = px[1];
        const b: i32 = px[2];
        // Order matters: the floor carries a slight blue tint (b = r+7),
        // so the near-gray tests must run BEFORE the sky test or the
        // sky bucket eats the whole floor (ask us how we know).
        if (r > 150 and r > g + 40 and g > b) {
            blob += 1; // molten orange: r >> g > b
        } else if (@abs(r - g) < 12 and b - r < 20 and r > 140) {
            floor_light += 1; // light checker square (near-gray)
        } else if (@abs(r - g) < 12 and b - r < 20 and r > 60 and r < 130) {
            floor_dark += 1; // dark checker square
        } else if (b > r + 20 and b > 90) {
            sky += 1; // STRONGLY blue gradient
        }
    }
    std.debug.print(
        "hybrid_verify: sky {d}, floor light {d}, floor dark {d}, blob {d} (all must be >0)\n",
        .{ sky, floor_light, floor_dark, blob },
    );

    const png: []u8 = try z.codecs.png.encode(gpa, std.mem.sliceAsBytes(img[0..]), img_w, img_h);
    defer gpa.free(png);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "hybrid_verify.png", .data = png });
    std.debug.print("  wrote hybrid_verify.png\n", .{});

    if (sky == 0 or floor_light == 0 or floor_dark == 0 or blob == 0) {
        return error.HybridLookWrong;
    }
    std.debug.print("  OK\n", .{});
}
