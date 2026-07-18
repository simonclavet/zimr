// examples/random_values.zig - a fresh pseudo-random value every 2 seconds.
// Port of raylib's `examples/core/core_random_values.c` (★1, ~48 LOC).
// raylib seeds a GLOBAL RNG and calls GetRandomValue; zimr keeps no global
// state, so the PRNG lives in the example's `State` (std.Random.DefaultPrng)
// and is advanced from there. A frame counter regenerates the value on a
// 2-second cadence (120 frames at the 60 fps fixed step).
//
// What this exercises:
//   - Owning a `std.Random.DefaultPrng` in State and pulling ranged ints
//     with `rng.random().intRangeAtMost(i32, lo, hi)` (raylib's -8..5).
//   - Formatting a runtime int into text with `std.fmt.bufPrint`, then
//     drawing it with the unified `f.gl.text` sink.
//
// Leak-clean (`.memory = .managed`): only the font is allocated and it is
// engine-owned (freed by resetRegistry), so `deinit` is a no-op.

const std = @import("std");
const Allocator = std.mem.Allocator;

const z = @import("zimr");
const zm = @import("zm");
const bufPrint = std.fmt.bufPrint;

const roboto_mono_ttf = @embedFile("roboto_mono_ttf");

const Color = zm.Color;
const c = Color;

const screen_w: i32 = 800;
const screen_h: i32 = 450;
const regen_frames: usize = 120; // ~2 s at the 60 fps fixed step

const State = struct {
    font: z.Font,
    rng: std.Random.DefaultPrng,
    value: i32 = 0,
    frame_count: usize = 0,
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, roboto_mono_ttf, 20);
    var rng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0x5EED_1234);
    const value: i32 = rng.random().intRangeAtMost(i32, -8, 5);
    s.* = .{ .font = font, .rng = rng, .value = value };
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn update(f: *z.Frame, s: *State) void {
    s.frame_count += 1;
    if (s.frame_count >= regen_frames) {
        s.value = s.rng.random().intRangeAtMost(i32, -8, 5);
        s.frame_count = 0;
    }

    z.clearViewport(f, c.raywhite); // runtime opened the pass; clearViewport draws INTO it (not beginDrawing)

    f.gl.text(
        .{ 130, 100 },
        "Every 2 seconds a new random value is generated:",
        .{ .size = 20, .color = c.maroon, .font = &s.font },
    );

    var buf: [16]u8 = undefined;
    const txt: []const u8 = bufPrint(&buf, "{d}", .{s.value}) catch "?";
    f.gl.text(.{ 360, 180 }, txt, .{ .size = 80, .color = c.maroon, .font = &s.font });

    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - core - generate random values",
            .width = screen_w,
            .height = screen_h,
            .scale_mode = .fit, // fixed 800x450 design space, letterboxed (default is .responsive = actual device size)
            .clear = .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 },
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
    .memory = .managed,
};
