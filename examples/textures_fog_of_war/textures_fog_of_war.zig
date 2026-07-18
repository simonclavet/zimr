//! textures_fog_of_war — port of raylib [textures] example.
//! A 25x15 tile map with fog of war. Fog state lives in a tiny 25x15 texture
//! (one texel per tile: opaque black = unseen, 80% black = explored, clear =
//! visible) uploaded each frame and drawn stretched over the map. Bilinear
//! filtering turns the blocky per-tile fog into smooth soft edges. Arrow keys
//! or touch move the player, revealing nearby tiles.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const Color = zm.Color;
const c = Color;
const Vec2 = zm.Vec2;

const tiles_x: usize = 25;
const tiles_y: usize = 15;
const tile_size: f32 = 32;
const player_size: f32 = 16;
const visibility: i32 = 2;
const roboto_mono_ttf = @embedFile("roboto_mono_ttf");

const State = struct {
    tile_ids: []u8,
    tile_fog: []u8,
    fog_pixels: []u8,
    fog_tex: z.WgpuTexture,
    player: Vec2 = .{ 180, 130 },
    tile_x: i32 = 0,
    tile_y: i32 = 0,
    prng: std.Random.DefaultPrng,
    font: z.Font,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    gpa.free(s.tile_ids);
    gpa.free(s.tile_fog);
    gpa.free(s.fog_pixels);
    s.fog_tex.deinit();
}

fn fogAlpha(state: u8) u8 {
    return switch (state) {
        0 => 255,
        2 => 204,
        else => 0,
    };
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const n: usize = tiles_x * tiles_y;
    const tile_ids: []u8 = try gpa.alloc(u8, n);
    const tile_fog: []u8 = try gpa.alloc(u8, n);
    const fog_pixels: []u8 = try gpa.alloc(u8, n * 4);
    @memset(tile_fog, 0);
    var prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0xF0607);
    const rng: std.Random = prng.random();
    for (0..n) |i| {
        tile_ids[i] = rng.intRangeAtMost(u8, 0, 1);
        fog_pixels[i * 4 + 0] = 0;
        fog_pixels[i * 4 + 1] = 0;
        fog_pixels[i * 4 + 2] = 0;
        fog_pixels[i * 4 + 3] = 255;
    }
    const fog_tex: z.WgpuTexture = z.WgpuTexture.createFromPixels(f.gpu.device, f.gpu.queue, .{
        .pixels = fog_pixels,
        .width = tiles_x,
        .height = tiles_y,
        .mag_filter_linear = true,
        .min_filter_linear = true,
        .label = "fog",
    });
    s.* = .{
        .tile_ids = tile_ids,
        .tile_fog = tile_fog,
        .fog_pixels = fog_pixels,
        .fog_tex = fog_tex,
        .prng = prng,
        .font = try z.loadFont(f, gpa, roboto_mono_ttf, 20),
    };
}

fn update(f: *z.Frame, s: *State) void {
    const map_w: f32 = float(tiles_x) * tile_size;
    const map_h: f32 = float(tiles_y) * tile_size;

    if (z.isKeyDown(f.input, .right)) {
        s.player[0] += 5;
    }
    if (z.isKeyDown(f.input, .left)) {
        s.player[0] -= 5;
    }
    if (z.isKeyDown(f.input, .down)) {
        s.player[1] += 5;
    }
    if (z.isKeyDown(f.input, .up)) {
        s.player[1] -= 5;
    }
    if (z.isMouseButtonDown(f.input, .left)) {
        const m: Vec2 = z.getMousePosition(f.input);
        const dx: f32 = m[0] - (s.player[0] + player_size / 2);
        const dy: f32 = m[1] - (s.player[1] + player_size / 2);
        const dist: f32 = @sqrt(dx * dx + dy * dy);
        if (dist > 5) {
            s.player[0] += (dx / dist) * 5;
            s.player[1] += (dy / dist) * 5;
        }
    }
    s.player[0] = std.math.clamp(s.player[0], 0, map_w - player_size);
    s.player[1] = std.math.clamp(s.player[1], 0, map_h - player_size);

    for (s.tile_fog) |*t| {
        if (t.* == 1) {
            t.* = 2;
        }
    }
    s.tile_x = @intFromFloat((s.player[0] + tile_size / 2) / tile_size);
    s.tile_y = @intFromFloat((s.player[1] + tile_size / 2) / tile_size);
    var y: i32 = s.tile_y - visibility;
    while (y < s.tile_y + visibility) : (y += 1) {
        var x: i32 = s.tile_x - visibility;
        while (x < s.tile_x + visibility) : (x += 1) {
            if (x >= 0 and x < tiles_x and y >= 0 and y < tiles_y) {
                s.tile_fog[@intCast(y * @as(i32, tiles_x) + x)] = 1;
            }
        }
    }

    for (0..tiles_x * tiles_y) |i| {
        s.fog_pixels[i * 4 + 3] = fogAlpha(s.tile_fog[i]);
    }
    s.fog_tex.updatePixels(f.gpu.queue, s.fog_pixels);

    z.beginDrawing(f.gl);
    z.clearViewport(f, c.raywhite);

    for (0..tiles_y) |ty| {
        for (0..tiles_x) |tx| {
            const px: f32 = float(tx) * tile_size;
            const py: f32 = float(ty) * tile_size;
            const col: Color = if (s.tile_ids[ty * tiles_x + tx] == 0) c.blue else c.blue.fade(0.9);
            f.gl.rect(.{ .x = px, .y = py, .width = tile_size, .height = tile_size }, .{ .color = col });
            f.gl.rect(
                .{ .x = px, .y = py, .width = tile_size, .height = tile_size },
                .{ .color = c.darkblue.fade(0.5), .outline = 1.0 },
            );
        }
    }
    f.gl.rect(
        .{ .x = s.player[0], .y = s.player[1], .width = player_size, .height = player_size },
        .{ .color = c.red },
    );
    f.gl.texture(.{ .x = 0, .y = 0, .width = map_w, .height = map_h }, s.fog_tex, .{ .tint = c.white });

    f.gl.text(
        .{ 10, map_h - 28 },
        "ARROW KEYS or TOUCH to move",
        .{ .size = 18, .color = c.raywhite, .font = &s.font },
    );
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{ .window = .{
        .title = "zimr - WebGPU - textures fog of war",
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
