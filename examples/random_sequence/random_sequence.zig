// examples/random_sequence.zig - a shuffled, non-repeating integer sequence.
// Port of raylib's `examples/core/core_random_sequence.c` (★1, ~70 LOC).
// raylib's LoadRandomSequence(count, min, max) returns `count` unique values;
// here it is a Fisher-Yates shuffle of 0..count-1 done in-place over an array
// the example owns (no global RNG, matching zimr's no-global-state rule). The
// permutation is drawn as a rainbow bar chart, each bar's height set by its
// value; SPACE reshuffles.
//
// What this exercises:
//   - A self-contained shuffle over a `std.Random` pulled from State.
//   - Ranged index draws with `intRangeLessThan`, and `z.colorFromHSV`
//     for the per-bar hue.
//   - Rising-edge key handling via `z.isKeyPressed(f.input, .space)`.
//
// Leak-clean (`.memory = .managed`): only the font is allocated and it is
// engine-owned (freed by resetRegistry), so `deinit` is a no-op.

const std = @import("std");
const Allocator = std.mem.Allocator;

const z = @import("zimr");
const zm = @import("zm");

const roboto_mono_ttf = @embedFile("roboto_mono_ttf");

const Color = zm.Color;
const c = Color;
const float = zm.float;

const screen_w: i32 = 800;
const screen_h: i32 = 450;
const count: usize = 20;
const margin: f32 = 40.0;

const State = struct {
    font: z.Font,
    rng: std.Random.DefaultPrng,
    sequence: [count]i32 = undefined,
};

/// In-place Fisher-Yates shuffle of 0..len-1 -> a uniform permutation.
fn fillSequence(rand: std.Random, seq: []i32) void {
    for (seq, 0..) |*v, i| {
        v.* = @intCast(i);
    }
    var i: usize = seq.len;
    while (i > 1) {
        i -= 1;
        const j: usize = rand.intRangeLessThan(usize, 0, i + 1);
        const tmp: i32 = seq[i];
        seq[i] = seq[j];
        seq[j] = tmp;
    }
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, roboto_mono_ttf, 20);
    s.* = .{ .font = font, .rng = std.Random.DefaultPrng.init(0x5E9_ABCD) };
    fillSequence(s.rng.random(), s.sequence[0..]);
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn update(f: *z.Frame, s: *State) void {
    if (z.isKeyPressed(f.input, .space)) {
        fillSequence(s.rng.random(), s.sequence[0..]);
    }

    z.clearViewport(f, c.raywhite); // runtime opened the pass; clearViewport draws INTO it (not beginDrawing)

    const usable_w: f32 = float(screen_w) - 2.0 * margin;
    const bar_w: f32 = usable_w / float(count);
    const max_h: f32 = float(screen_h) - 2.0 * margin - 40.0;
    const base_y: f32 = float(screen_h) - margin;

    for (s.sequence, 0..) |value, i| {
        const t: f32 = float(value + 1) / float(count);
        const h: f32 = t * max_h;
        const x: f32 = margin + float(i) * bar_w;
        const col: Color = z.colorFromHSV(float(value) / float(count) * 360.0, 0.75, 0.9);
        f.gl.rect(.{ .x = x, .y = base_y - h, .width = bar_w - 2.0, .height = h }, .{ .color = col });
    }

    f.gl.text(
        .{ margin, margin },
        "Each bar is a unique value 0..19 - a shuffled sequence, no repeats.",
        .{ .size = 20, .color = c.darkgray, .font = &s.font },
    );
    f.gl.text(
        .{ margin, margin + 26.0 },
        "Press SPACE to generate a new random sequence",
        .{ .size = 20, .color = c.maroon, .font = &s.font },
    );

    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - core - random sequence",
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
