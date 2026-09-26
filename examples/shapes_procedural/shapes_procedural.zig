// examples/shapes_procedural.zig - two procedural 2D drawing samples in one app.
// MERGES raylib's `shapes_mouse_trail` and `shapes_recursive_tree` behind a UI
// mode switch. They're both "draw a lot of primitives from a simple rule", they
// share the same scaffolding, and folding them together means one wasm and one
// device check instead of two - the build cost of a UI example is ~10s, so this
// is real savings, not tidiness.
//
//   TRAIL - a ring of recent pointer positions, drawn as circles that shrink and
//           fade with age. Drag anywhere below the panel.
//   TREE  - a binary branch system grown ITERATIVELY (raylib's sample is called
//           "recursive" but expands a queue, which is what keeps it bounded).
//           Each branch spawns two children at +/-theta, each shorter by `decay`,
//           until they're too short to matter. Angle / length / decay are live
//           sliders, so the whole parameter space is explorable by thumb.
//
// Leak-clean (`.memory = .managed`): the UiHost is deinit'd; the atlas is
// engine-owned.

const std = @import("std");
const Allocator = std.mem.Allocator;

const z = @import("zimr");
const zm = @import("zm");

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const Color = zm.Color;
const c = Color;
const Vec2 = zm.Vec2;
const float = zm.float;
const pi = zm.pi;

const trail_len: usize = 40;
const max_branches: usize = 2048;
const min_branch_len: f32 = 2.0;

const Mode = enum { trail, tree };

/// One segment of the tree. `angle` is measured from straight-up, so a child is
/// just parent.angle +/- theta - no matrix stack needed.
const Branch = struct {
    start: Vec2,
    end: Vec2,
    angle: f32,
    length: f32,
};

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,
    ui_font: z.Font,
    mode: Mode = .trail,

    // trail
    trail: [trail_len]Vec2 = @splat(.{ 0, 0 }),
    seeded: bool = false,

    // tree (live-tunable)
    angle_deg: f32 = 32.0,
    length: f32 = 90.0,
    decay: f32 = 0.72,
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const ui_font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24);
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 18);
    s.* = .{ .ui_host = z.UiHost.init(gpa, ui_font), .font = font, .ui_font = ui_font };
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    z.unloadFont(gpa, s.ui_font);
    s.ui_host.deinit();
}

/// Push the newest pointer position onto the front and age everything else.
fn pushTrail(s: *State, p: Vec2) void {
    var i: usize = trail_len - 1;
    while (i > 0) : (i -= 1) {
        s.trail[i] = s.trail[i - 1];
    }
    s.trail[0] = p;
}

fn drawTrail(gl: *z.WgpuGl, s: *const State) void {
    // Oldest first, so newer (bigger, brighter) circles land on top.
    var i: usize = trail_len;
    while (i > 0) {
        i -= 1;
        const ratio: f32 = float(trail_len - i) / float(trail_len);
        const radius: f32 = 16.0 * ratio;
        if (radius < 0.5) {
            continue;
        }
        const a: u8 = @trunc(255.0 * (ratio * 0.6 + 0.15));
        gl.circle(s.trail[i], radius, .{ .color = .{ .r = 102, .g = 191, .b = 255, .a = a } });
    }
    gl.circle(s.trail[0], 8, .{ .color = c.raywhite });
}

/// Grow the tree breadth-first into a fixed buffer. Bounded two ways - a branch
/// stops when it gets too short, and the buffer can't overflow - so a wild
/// slider setting can't hang the frame.
fn drawTree(gl: *z.WgpuGl, s: *const State, root: Vec2) usize {
    var branches: [max_branches]Branch = undefined;
    var count: usize = 0;

    branches[0] = .{
        .start = root,
        .end = .{ root[0], root[1] - s.length },
        .angle = 0,
        .length = s.length,
    };
    count = 1;

    const theta: f32 = s.angle_deg * pi / 180.0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const b: Branch = branches[i];

        // Thickness + color track branch length: thick brown trunk near the
        // root, thin green twigs at the tips.
        const t: f32 = @min(b.length / s.length, 1.0);
        const thickness: f32 = @max(1.0, 7.0 * t);
        const col: Color = .{
            .r = @trunc(90.0 + 70.0 * t),
            .g = @trunc(170.0 - 80.0 * t),
            .b = @trunc(70.0 - 40.0 * t),
            .a = 255,
        };
        gl.line(b.start, b.end, .{ .color = col, .thickness = thickness });

        const next_len: f32 = b.length * s.decay;
        if (next_len < min_branch_len or count + 2 > max_branches) {
            continue;
        }
        for ([2]f32{ theta, -theta }) |d| {
            const a: f32 = b.angle + d;
            branches[count] = .{
                .start = b.end,
                .end = .{ b.end[0] + next_len * @sin(a), b.end[1] - next_len * @cos(a) },
                .angle = a,
                .length = next_len,
            };
            count += 1;
        }
    }
    return count;
}

fn update(f: *z.Frame, s: *State) void {
    const fw: f32 = f.window.widthf();
    const fh: f32 = f.window.heightf();

    z.clearViewport(f, .{ .r = 18, .g = 20, .b = 28, .a = 255 });

    const u: z.ui_real.Ui = s.ui_host.begin(f);

    // Only feed the trail from pointer positions OUTSIDE the panel, or tapping a
    // button would whip the trail up to the UI.
    if (s.mode == .trail and !u.wantCaptureMouse()) {
        const p: Vec2 = z.getMousePosition(f.input);
        if (!s.seeded) {
            s.trail = @splat(p); // avoid a comet streaking in from (0,0) on frame 1
            s.seeded = true;
        }
        pushTrail(s, p);
    }

    var branch_count: usize = 0;
    switch (s.mode) {
        .trail => drawTrail(f.gl, s),
        .tree => branch_count = drawTree(f.gl, s, .{ fw * 0.5, fh - 40.0 }),
    }

    u.setNextWindowPos(.{ 8, 8 }, .{});
    u.setNextWindowSize(.{ fw - 16.0, 250 }, .{});
    if (u.window("Procedural shapes", .{})) |w| {
        defer w.close();
        if (u.button("Mouse trail", .{})) {
            s.mode = .trail;
            s.seeded = false;
        }
        u.sameLine(.{});
        if (u.button("Recursive tree", .{})) {
            s.mode = .tree;
        }
        u.separator();
        switch (s.mode) {
            .trail => {
                u.text("Drag below the panel.", .{});
                u.text("Circles shrink + fade with age.", .{});
            },
            .tree => {
                _ = u.slider("angle", &s.angle_deg, .{ .min = 5, .max = 60 });
                _ = u.slider("length", &s.length, .{ .min = 30, .max = 140 });
                _ = u.slider("decay", &s.decay, .{ .min = 0.50, .max = 0.80 });
                u.text("branches: {d}", .{branch_count});
            },
        }
    }

    s.ui_host.render(f);
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - shapes - procedural (trail + tree)",
            .width = 800,
            .height = 450,
            .scale_mode = .responsive,
            .depth_format = null,
            .clear = .{ .r = 18.0 / 255.0, .g = 20.0 / 255.0, .b = 28.0 / 255.0, .a = 1.0 },
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
    .memory = .managed,
};
