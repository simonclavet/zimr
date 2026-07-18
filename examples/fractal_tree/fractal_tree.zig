//! fractal_tree — a recursive L-system tree swaying in the wind. Each branch splits
//! into two thinner, shorter children; recursion to a fixed depth grows the canopy, with
//! blossoms at the tips. A per-depth, per-position sinusoidal sway makes a ripple travel up
//! the tree so the whole thing bends and shimmers. Pure recursion + drawLine.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const float = zm.float;

const roboto_mono_ttf = @embedFile("roboto_mono_ttf");
const c = Color;
const max_depth: usize = 9;

const State = struct {
    font: z.Font,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{ .font = try z.loadFont(f, gpa, roboto_mono_ttf, 24) };
}

/// Draw one branch from (x,y) at `angle` (0 = straight up), then recurse into two children.
fn branch(
    gl: anytype,
    x: f32,
    y: f32,
    angle: f32,
    len: f32,
    thick: f32,
    depth: usize,
    t: f32,
) void {
    // Sway grows toward the thin tips and travels up the tree as a phase-shifted wave.
    const up: f32 = float(max_depth - depth);
    const sway: f32 = (0.02 + 0.016 * up) * @sin(t * 1.3 + up * 0.7 + x * 0.008);
    const a: f32 = angle + sway;
    const ex: f32 = x + @sin(a) * len;
    const ey: f32 = y - @cos(a) * len;

    // Bark brown at the trunk fading to leaf green at the twigs.
    const f0: f32 = float(depth) / float(max_depth); // 1 at trunk, 0 at tip
    const r8: u8 = @round(90.0 + 60.0 * f0);
    const g8: u8 = @round(170.0 - 70.0 * f0);
    const b8: u8 = @round(70.0 - 12.0 * f0);
    gl.line(.{ x, y }, .{ ex, ey }, .{ .color = c.init(r8, g8, b8, 255), .thickness = @max(thick, 1.0) });

    if (depth == 0) {
        const blossom: Color = z.colorFromHSV(@mod(320.0 + ex * 0.12, 360.0), 0.45, 1.0);
        gl.circle(.{ ex, ey }, 3.0, .{ .color = blossom, .segments = 16 });
        return;
    }
    branch(gl, ex, ey, a - 0.40, len * 0.76, thick * 0.72, depth - 1, t);
    branch(gl, ex, ey, a + 0.50, len * 0.76, thick * 0.72, depth - 1, t);
}

fn update(f: *z.Frame, s: *State) void {
    const t: f32 = f.time.time;
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();

    z.clearViewport(f, c.init(12, 14, 22, 255));
    branch(f.gl, w * 0.5, h * 0.97, 0.0, h * 0.20, 11.0, max_depth, t);
    f.gl.text(
        .{ 12, 12 },
        "fractal tree: recursive L-system, wind sway",
        .{ .size = 14, .color = c.init(210, 214, 224, 220), .font = &s.font },
    );
    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - fractal tree",
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
