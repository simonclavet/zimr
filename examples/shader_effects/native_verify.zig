//! native_verify - render every 2D effect NATIVELY through the same
//! `shaderMain`s the gallery compiles to WGSL, over a synthetic test
//! pattern, into one contact sheet (`effects_verify.png`): source,
//! grade, waves, outline, palette, left to right.
//!
//! Each panel is a fullscreen quad through `deferred_shading_vs` with
//! the effect FS sampling the pattern via a TextureRef - the CPU twin
//! of the gallery's GPU pass.  Cheap assertions per effect catch the
//! "shipped a blob" class of bug before a device ever sees it.
//! `zig build shader-effects-verify`.

const std = @import("std");
const z = @import("zimr");
const zm = @import("zm");
const Allocator = std.mem.Allocator;
const float = zm.float;

const quad_vs = z.deferred_shaders.shading_vs;
const fx = z.effect_shaders;

const src_w: usize = 220;
const src_h: usize = 160;
const panels: usize = 6;

/// Synthetic source: three colored disks + a white bar on TRANSPARENT
/// background (the outline effect needs alpha edges to bite).
fn buildPattern() [src_w * src_h][4]u8 {
    var img: [src_w * src_h][4]u8 = @splat(.{ 0, 0, 0, 0 });
    const disks = [3]struct { cx: f32, cy: f32, r: f32, rgb: [3]u8 }{
        .{ .cx = 60, .cy = 70, .r = 38, .rgb = .{ 255, 120, 90 } },
        .{ .cx = 130, .cy = 95, .r = 30, .rgb = .{ 110, 200, 255 } },
        .{ .cx = 170, .cy = 50, .r = 22, .rgb = .{ 150, 235, 120 } },
    };
    for (0..src_h) |y| {
        for (0..src_w) |x| {
            const px: *[4]u8 = &img[y * src_w + x];
            for (disks) |d| {
                const dx: f32 = float(x) - d.cx;
                const dy: f32 = float(y) - d.cy;
                if (dx * dx + dy * dy < d.r * d.r) {
                    px.* = .{ d.rgb[0], d.rgb[1], d.rgb[2], 255 };
                }
            }
            // The bar: hard horizontal edges for the wave to bend.
            if (y > 120 and y < 134 and x > 20 and x < 200) {
                px.* = .{ 245, 245, 250, 255 };
            }
        }
    }
    return img;
}

const quad_positions = [_][2]f32{
    .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 },
    .{ -1, -1 }, .{ 1, 1 },  .{ -1, 1 },
};
const quad_indices = [_]u32{ 0, 1, 2, 3, 4, 5 };

/// Run one effect FS over the pattern; returns the filtered panel.
fn runEffect(
    comptime FsModule: type,
    fs_io: FsModule.Io,
) [src_w * src_h][4]u8 {
    var outs: [6]quad_vs.Out = undefined;
    var vio: quad_vs.Io = undefined;
    for (quad_positions, &outs) |p, *o| {
        vio.vertex_ndc_pos = .{ p[0], p[1] };
        o.* = quad_vs.shaderMain(vio);
    }
    const connect: fn (quad_vs.Out, *FsModule.Io) void = z.shader.autoConnect(quad_vs.Out, FsModule.Io);
    return z.raster_shader.rasterizeToImage(
        quad_vs,
        FsModule,
        src_w,
        src_h,
        &outs,
        &quad_indices,
        fs_io,
        connect,
        .{ .front_face = .none, .depth_test = false },
        .{ 0, 0, 0, 0 }, // transparent clear - panels composite like the app
    );
}

fn countDiff(a: []const [4]u8, b: []const [4]u8) u32 {
    var n: u32 = 0;
    for (a, b) |pa, pb| {
        if (pa[0] != pb[0] or pa[1] != pb[1] or pa[2] != pb[2] or pa[3] != pb[3]) {
            n += 1;
        }
    }
    return n;
}

pub fn main() !void {
    const gpa: Allocator = std.heap.page_allocator;
    var io_threaded: std.Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();
    const io: std.Io = io_threaded.io();

    const pattern: [src_w * src_h][4]u8 = buildPattern();
    // NOTE: every externs module declares its OWN structurally-identical
    // TextureRef type, so each effect gets an anonymous literal (they
    // coerce); a shared typed const would not cross-assign.
    const src_bytes: []const u8 = std.mem.sliceAsBytes(pattern[0..]);

    // ---- grade: strong contrast + saturation, must differ from source ----
    var grade_io: fx.grade_fs.Io = undefined;
    grade_io.u = .{ .params = .{ 0.5, 0.0, 0.6, 0 } };
    grade_io._texture0 = .{ .pixels = src_bytes, .width = src_w, .height = src_h };
    const grade: [src_w * src_h][4]u8 = runEffect(fx.grade_fs, grade_io);

    // ---- waves: frozen mid-swing, edges must be displaced ----
    var wave_io: fx.wave_fs.Io = undefined;
    wave_io.u = .{
        .drive = .{ 1.7, 25, 25, 0 },
        .motion = .{ 5, 5, 8, 8 },
        .size = .{ float(src_w), float(src_h), 0, 0 },
    };
    wave_io._texture0 = .{ .pixels = src_bytes, .width = src_w, .height = src_h };
    const waves: [src_w * src_h][4]u8 = runEffect(fx.wave_fs, wave_io);

    // ---- outline: orange ink must appear around the alpha silhouettes ----
    var outline_io: fx.outline_fs.Io = undefined;
    outline_io.u = .{
        .outline_color = .{ 1.0, 0.42, 0.1, 1 },
        .params = .{ 3, float(src_w), float(src_h), 0 },
    };
    outline_io._texture0 = .{ .pixels = src_bytes, .width = src_w, .height = src_h };
    const outline: [src_w * src_h][4]u8 = runEffect(fx.outline_fs, outline_io);

    // ---- palette: every opaque pixel must BE a palette entry ----
    const table: [8][4]f32 = .{
        .{ 0.06, 0.22, 0.06, 1 }, .{ 0.19, 0.38, 0.19, 1 },
        .{ 0.30, 0.51, 0.30, 1 }, .{ 0.42, 0.65, 0.30, 1 },
        .{ 0.55, 0.75, 0.35, 1 }, .{ 0.67, 0.84, 0.45, 1 },
        .{ 0.78, 0.91, 0.56, 1 }, .{ 0.88, 0.97, 0.68, 1 },
    };
    var pal_io: fx.palette_fs.Io = undefined;
    pal_io.u = .{ .palette = undefined, .params = .{ 8, 0, 0, 0 } };
    for (table, &pal_io.u.palette) |src, *dst| {
        dst.* = src;
    }
    pal_io._texture0 = .{ .pixels = src_bytes, .width = src_w, .height = src_h };
    const palette: [src_w * src_h][4]u8 = runEffect(fx.palette_fs, pal_io);

    // ---- spotlight: center of the hero spot keeps its color, the far
    //      corner goes dark ----
    var spot_io: fx.spotlight_fs.Io = undefined;
    spot_io.u = .{
        .spots = .{
            .{ 60, 70, 14, 42 }, // hero: parked on the red disk
            .{ 130, 95, 8, 26 },
            .{ 170, 50, 8, 26 },
        },
        .params = .{ 0.12, float(src_w), float(src_h), 0 },
    };
    spot_io._texture0 = .{ .pixels = src_bytes, .width = src_w, .height = src_h };
    const spotlight: [src_w * src_h][4]u8 = runEffect(fx.spotlight_fs, spot_io);

    // ---- assertions ----
    const grade_diff: u32 = countDiff(pattern[0..], grade[0..]);
    const wave_diff: u32 = countDiff(pattern[0..], waves[0..]);
    var ink_px: u32 = 0;
    for (outline) |px| {
        if (px[0] > 200 and px[1] > 70 and px[1] < 160 and px[2] < 80) {
            ink_px += 1;
        }
    }
    // Spot center (inside disk 0's inner circle) must keep the disk's
    // red; the bar's far end (x=190,y=127 - outside all spots) must be
    // darkened to ~12% of its source brightness.
    const center_px: [4]u8 = spotlight[70 * src_w + 60];
    const far_src: [4]u8 = pattern[127 * src_w + 190];
    const far_px: [4]u8 = spotlight[127 * src_w + 190];
    const spot_center_ok: bool = center_px[0] > 220;
    const spot_dark_ok: bool = far_px[0] < @divTrunc(@as(u16, far_src[0]) * 25, 100);

    var pal_bad: u32 = 0;
    for (palette) |px| {
        if (px[3] < 10) {
            continue; // transparent bg passes through
        }
        var matched: bool = false;
        for (table) |entry| {
            const er: i32 = @trunc(entry[0] * 255.0);
            const eg: i32 = @trunc(entry[1] * 255.0);
            const eb: i32 = @trunc(entry[2] * 255.0);
            const dr: i32 = @as(i32, px[0]) - er;
            const dg: i32 = @as(i32, px[1]) - eg;
            const db: i32 = @as(i32, px[2]) - eb;
            if (dr * dr + dg * dg + db * db < 32) {
                matched = true;
            }
        }
        if (!matched) {
            pal_bad += 1;
        }
    }
    std.debug.print(
        "effects_verify: grade diff {d} px, wave diff {d} px, outline ink {d} px, " ++
            "palette off-table {d} px, spot center ok {}, spot dark ok {}\n",
        .{ grade_diff, wave_diff, ink_px, pal_bad, spot_center_ok, spot_dark_ok },
    );

    // ---- contact sheet: source | grade | waves | outline | palette ----
    const sheet_w: usize = src_w * panels;
    const sheet: []([4]u8) = try gpa.alloc([4]u8, sheet_w * src_h);
    defer gpa.free(sheet);
    const panels_data = [panels]*const [src_w * src_h][4]u8{
        &pattern, &grade, &waves, &outline, &palette, &spotlight,
    };
    for (0..src_h) |y| {
        for (panels_data, 0..) |panel, pi| {
            for (0..src_w) |x| {
                sheet[y * sheet_w + pi * src_w + x] = panel[y * src_w + x];
            }
        }
    }
    const png: []u8 = try z.codecs.png.encode(gpa, std.mem.sliceAsBytes(sheet), sheet_w, src_h);
    defer gpa.free(png);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "effects_verify.png", .data = png });
    std.debug.print("  wrote effects_verify.png\n", .{});

    if (grade_diff == 0 or wave_diff == 0 or ink_px == 0 or pal_bad > 50 or
        !spot_center_ok or !spot_dark_ok)
    {
        return error.EffectsLookWrong;
    }
    std.debug.print("  OK\n", .{});
}
