//! starfield — a fly-through-space starfield ported to WebGPU. Stars stream
//! outward from the screen centre as motion streaks (the "warp speed" look): each is a
//! point seeded in a 3D box, projected with a 1/z perspective divide, and drawn as a
//! short line from where it was a moment ago to where it is now. Closer stars are
//! brighter and thicker. Self-running (no input), viewport-relative under `.responsive`
//! so it fills the canvas at any aspect.
const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const clamp = zm.clamp;

const roboto_mono_ttf = @embedFile("roboto_mono_ttf");
const c = Color;

const num_stars: usize = 700;
const speed: f32 = 0.55;
const trail_age: f32 = 0.06; // bigger = longer streaks

const Star = struct { x: f32, y: f32, z: f32 };

const State = struct {
    font: z.Font,
    stars: [num_stars]Star = undefined,
    rng: std.Random.DefaultPrng,
    frame_count: usize = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn randf(
    rand: std.Random,
    low: f32,
    high: f32,
) f32 {
    return low + rand.float(f32) * (high - low);
}

fn respawn(
    star: *Star,
    rand: std.Random,
    hw: f32,
    hh: f32,
) void {
    star.x = randf(rand, -hw, hw);
    star.y = randf(rand, -hh, hh);
    star.z = 1.0;
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, roboto_mono_ttf, 24);
    s.* = .{ .font = font, .rng = std.Random.DefaultPrng.init(0x57a4f00d) };
    const rand: std.Random = s.rng.random();
    const hw: f32 = @max(1.0, f.window.widthf() * 0.5);
    const hh: f32 = @max(1.0, f.window.heightf() * 0.5);
    for (&s.stars) |*star| {
        respawn(star, rand, hw, hh);
        star.z = randf(rand, 0.1, 1.0); // spread the initial depths
    }
}

fn update(f: *z.Frame, s: *State) void {
    s.frame_count += 1;
    const dt: f32 = f.time.delta_time;
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    const hw: f32 = w * 0.5;
    const hh: f32 = h * 0.5;
    const rand: std.Random = s.rng.random();

    z.clearViewport(f, c.init(6, 8, 16, 255));

    for (&s.stars) |*star| {
        star.z -= dt * speed;
        if (star.z < 0.02) {
            respawn(star, rand, hw, hh);
        }
        const sx: f32 = hw + star.x / star.z;
        const sy: f32 = hh + star.y / star.z;
        if (sx < 0 or sy < 0 or sx > w or sy > h) {
            respawn(star, rand, hw, hh);
            continue;
        }
        const t: f32 = clamp(star.z + trail_age, 0.02, 1.0);
        const px: f32 = hw + star.x / t;
        const py: f32 = hh + star.y / t;
        const bright: f32 = clamp(1.0 - star.z, 0.0, 1.0);
        const cr: u8 = @round(180.0 + 75.0 * bright);
        const cg: u8 = @round(200.0 + 55.0 * bright);
        const col: Color = c.init(cr, cg, 255, 255);
        f.gl.line(.{ px, py }, .{ sx, sy }, .{ .color = col, .thickness = 1.0 + bright * 2.0 });
    }

    var buf: [32]u8 = undefined;
    const fps: i32 = if (dt > 0.0) @trunc(1.0 / dt) else 0;
    const label: []const u8 = bufPrint(&buf, "{d} FPS", .{fps}) catch "?";
    f.gl.text(.{ 12, 12 }, label, .{ .size = 18, .color = c.init(140, 230, 140, 255), .font = &s.font });

    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - starfield",
            .width = 800,
            .height = 450,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
