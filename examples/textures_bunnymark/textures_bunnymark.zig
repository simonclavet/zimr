//! textures_bunnymark - port of raylib [textures] example.
//! Hold the mouse to spawn bunnies; each drifts and bounces off the edges.
//! A stress test: thousands of drawTexture calls per frame.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const Vec2 = zm.Vec2;

const bunny_png = @embedFile("raybunny.png");
const max_bunnies: usize = 50000;
const spawn_per_frame: usize = 100;

const Bunny = struct {
    x: f32,
    y: f32,
    sx: f32,
    sy: f32,
    color: zm.Color,
};

const State = struct {
    tex: z.WgpuTexture,
    bunnies: []Bunny,
    count: usize = 0,
    rng: std.Random.DefaultPrng,
};

fn deinit(gpa: Allocator, s: *State) void {
    gpa.free(s.bunnies);
    s.tex.deinit();
}

fn uploadPng(gpa: Allocator, gl: *z.WgpuGl, png: []const u8) !z.WgpuTexture {
    const img: z.Image = try z.loadImageFromMemory(gpa, png);
    const tex: z.WgpuTexture = z.loadTextureFromImage(gl, img);
    if (img.data) |d| {
        const n: usize = @as(usize, @intCast(img.width)) * @as(usize, @intCast(img.height)) * 4;
        gpa.free(@as([*]u8, @ptrCast(d))[0..n]);
    }
    return tex;
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{
        .tex = try uploadPng(gpa, f.gl, bunny_png),
        .bunnies = try gpa.alloc(Bunny, max_bunnies),
        .rng = std.Random.DefaultPrng.init(0x9e3779b97f4a7c15),
    };
    // Seed a few hundred so the scene is alive before the first click.
    const rnd: std.Random = s.rng.random();
    while (s.count < 500) : (s.count += 1) {
        s.bunnies[s.count] = .{
            .x = 400,
            .y = 225,
            .sx = (rnd.float(f32) - 0.5) * 8.0,
            .sy = (rnd.float(f32) - 0.5) * 8.0,
            .color = .{
                .r = rnd.intRangeAtMost(u8, 50, 240),
                .g = rnd.intRangeAtMost(u8, 60, 200),
                .b = rnd.intRangeAtMost(u8, 80, 220),
                .a = 255,
            },
        };
    }
}

fn update(f: *z.Frame, s: *State) void {
    const rnd: std.Random = s.rng.random();
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    const bw: f32 = float(s.tex.width);
    const bh: f32 = float(s.tex.height);

    if (z.isMouseButtonDown(f.input, .left)) {
        const mp: Vec2 = z.getMousePosition(f.input);
        var k: usize = 0;
        while (k < spawn_per_frame and s.count < max_bunnies) : (k += 1) {
            s.bunnies[s.count] = .{
                .x = mp[0],
                .y = mp[1],
                .sx = (rnd.float(f32) - 0.5) * 8.0,
                .sy = (rnd.float(f32) - 0.5) * 8.0,
                .color = .{
                    .r = rnd.intRangeAtMost(u8, 50, 240),
                    .g = rnd.intRangeAtMost(u8, 60, 200),
                    .b = rnd.intRangeAtMost(u8, 80, 220),
                    .a = 255,
                },
            };
            s.count += 1;
        }
    }

    for (s.bunnies[0..s.count]) |*b| {
        b.x += b.sx;
        b.y += b.sy;
        if ((b.x + bw * 0.5) > w or (b.x + bw * 0.5) < 0) {
            b.sx *= -1;
        }
        if ((b.y + bh * 0.5) > h or (b.y + bh * 0.5) < 0) {
            b.sy *= -1;
        }
    }

    z.beginDrawing(f.gl);
    z.clearViewport(f, .{ .r = 245, .g = 245, .b = 245, .a = 255 });
    for (s.bunnies[0..s.count]) |b| {
        f.gl.texture(.{ .x = b.x, .y = b.y, .width = bw, .height = bh }, s.tex, .{ .tint = b.color });
    }
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{ .window = .{
        .title = "zimr - WebGPU - textures bunnymark",
        .width = 800,
        .height = 450,
        .scale_mode = .responsive,
    } },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
    .manages_own_frame = true,
};
