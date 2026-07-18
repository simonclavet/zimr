//! billboards — port of the GL `billboards`, on the new textured-3D path.
//! A ring of soft glowing sprites (a procedurally-generated radial-alpha texture)
//! drawn as camera-facing billboards via `drawBillboard`, plus a few solid cubes
//! and a grid. As the camera orbits, the billboards always face it (flat to the
//! view) while the cubes show their 3D faces — the billboard effect. The sprite
//! has an alpha falloff, so this also exercises the textured pipeline's alpha
//! blending. Billboards are drawn last (after the opaque cubes) for correct
//! alpha compositing; depth-test still lets the cubes occlude them.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const float = zm.float;
const Camera3D = zm.Camera3D;
const Vec = zm.Vec;
const clamp = zm.clamp;
const pi = zm.pi;
const pointVec = zm.pointVec;
const vec = zm.vec;

const co = @import("example_common");
const c = z.colors;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const State = struct {
    sprite: z.WgpuTexture,
    font: z.Font,
    angle: f32 = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.sprite.deinit(); // texture + view + sampler + bind group
}

/// Generate a 64×64 soft round sprite: bright centre fading to transparent edge.
fn makeSprite(gpa: Allocator) !z.Image {
    const n: usize = 64;
    const img: z.Image = try z.genImageColor(gpa, @intCast(n), @intCast(n), .{ .r = 0, .g = 0, .b = 0, .a = 0 });
    const px: [*]u8 = @ptrCast(img.data.?);
    const center: f32 = float(n) * 0.5 - 0.5;
    for (0..n) |y| {
        for (0..n) |x| {
            const dx: f32 = float(x) - center;
            const dy: f32 = float(y) - center;
            const d: f32 = @sqrt(dx * dx + dy * dy) / center;
            const a: f32 = clamp(1.0 - d * 1.6, 0.0, 1.0);
            const fall: f32 = a * a; // soft, contained glow
            const i: usize = (y * n + x) * 4;
            px[i + 0] = 130;
            px[i + 1] = 210;
            px[i + 2] = 255;
            px[i + 3] = @trunc(fall * 255.0);
        }
    }
    return img;
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const img: z.Image = try makeSprite(gpa);
    const tex: z.WgpuTexture = z.loadTextureFromImage(f.gl, img);
    z.unloadImage(gpa, img);
    s.* = .{ .sprite = tex, .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24) };
}

fn cross3arr(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

fn norm3(v: [3]f32) [3]f32 {
    const l: f32 = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    if (l <= 1e-6) {
        return .{ 0, 0, 0 };
    }
    return .{ v[0] / l, v[1] / l, v[2] / l };
}

const ring = [_]struct { x: f32, z: f32, col: Color }{
    .{ .x = 0, .z = 0, .col = c.sky_300 },
    .{ .x = 3, .z = 0, .col = c.amber_300 },
    .{ .x = -3, .z = 0, .col = c.rose_400 },
    .{ .x = 0, .z = 3, .col = c.emerald_400 },
    .{ .x = 0, .z = -3, .col = c.violet_400 },
};

fn update(f: *z.Frame, s: *State) void {
    s.angle += f.time.delta_time * 18.0;

    z.clearViewport(f, .{ .r = 10, .g = 12, .b = 18, .a = 255 });

    const rad: f32 = s.angle * pi / 180.0;
    const cam: Camera3D = .{
        .position = pointVec(@cos(rad) * 8.0, 4.0, @sin(rad) * 8.0),
        .target = pointVec(0, 1, 0),
        .up = vec(0, 1, 0),
        .fovy_deg = 50,
        .projection = 0,
    };

    // Camera basis for billboards (right/up that always face the camera).
    const cp: Vec = cam.position;
    const ct: Vec = cam.target;
    const fwd: [3]f32 = norm3(.{ ct[0] - cp[0], ct[1] - cp[1], ct[2] - cp[2] });
    const right: [3]f32 = norm3(cross3arr(fwd, .{ 0, 1, 0 }));
    const bup: [3]f32 = cross3arr(right, fwd);

    z.beginMode3D(f.gl, cam);
    z.drawGrid(f.gl, 16, 1.0);

    // Solid cubes as ground markers (3D faces, for contrast with the billboards).
    z.drawCube(f.gl, pointVec(2, 0.4, 2), .{ .size = vec(0.8, 0.8, 0.8), .color = c.slate_500 });
    z.drawCube(f.gl, pointVec(-2, 0.4, -2), .{ .size = vec(0.8, 0.8, 0.8), .color = c.slate_500 });
    z.drawCube(f.gl, pointVec(-2, 0.4, 2), .{ .size = vec(0.8, 0.8, 0.8), .color = c.slate_600 });

    // Camera-facing glowing billboards, drawn back-to-front: alpha billboards
    // write depth, so a nearer one drawn first would clip farther ones to its
    // quad. Sorting farthest-first (we draw last, after the opaque cubes) makes
    // the transparent overlaps composite correctly.
    var order: [ring.len]usize = undefined;
    var dist: [ring.len]f32 = undefined;
    for (ring, 0..) |b, i| {
        const dx: f32 = b.x - cp[0];
        const dy: f32 = 1.4 - cp[1];
        const dz: f32 = b.z - cp[2];
        dist[i] = dx * dx + dy * dy + dz * dz;
        order[i] = i;
    }
    // Insertion sort by descending distance (n = 5).
    var a: usize = 1;
    while (a < ring.len) : (a += 1) {
        const key: usize = order[a];
        var b2: usize = a;
        while (b2 > 0 and dist[order[b2 - 1]] < dist[key]) : (b2 -= 1) {
            order[b2] = order[b2 - 1];
        }
        order[b2] = key;
    }
    for (order) |i| {
        const p: Vec = pointVec(ring[i].x, 1.4, ring[i].z);
        z.drawBillboard(f.gl, s.sprite, right, bup, p, 1.6, 1.6, ring[i].col);
    }

    z.endMode3D(f.gl);

    co.caption(f.gl, s.font, "drawBillboard - alpha sprites always facing the camera; cubes show 3D faces");
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - billboards",
            .width = 960,
            .height = 540,
            .scale_mode = .responsive,
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
