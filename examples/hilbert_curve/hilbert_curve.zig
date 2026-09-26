// examples/hilbert_curve.zig - animated space-filling curve.
// The Hilbert curve is a continuous 1D path that tiles 2D space
// in a recursively self-similar U-shape.  At order N it visits
// exactly 4^N points on a 2^N x 2^N grid; at order 5 we get 1024
// points connected by 1023 line segments.
// Each segment is coloured by its position along the curve via
// HSV -> RGB, so the colour wheel sweeps once across the full
// path.  The animation reveals the recursive structure: as the
// stroke advances you watch the curve fill each quadrant in turn,
// then bridge between them.
// Controls live in the floating "Hilbert" panel: order (2-6),
// stroke thickness, animation speed, and Restart.
// Ported from raylib's `shapes_hilbert_curve.c`; raygui sliders
// promoted to zimr imgui sliders and the [ / ] keys retired.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Vec2 = zm.Vec2;
const Color = zm.Color;
const float = zm.float;
const int = zm.int;
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
const c = Color;

const screen_w: i32 = 800;
const screen_h: i32 = 450;

const min_order: i32 = 2;
const max_order: i32 = 6;

const State = struct {
    scratch: std.heap.ArenaAllocator,
    gpa: Allocator,
    ui_host: z.UiHost,
    font: z.Font,

    /// Recursion depth.  Stroke count = 4^order.  Bound to a
    /// slider; we detect changes against `cached_order` to
    /// rebuild the path lazily.
    order: i32 = 4,
    cached_order: i32 = -1,

    /// Current path - len = 4^order = 1 << (2 * order).  Owned by
    /// the State; freed by deinit, replaced when order changes.
    path: []Vec2,
    /// How far along the path the animation has drawn so far.
    /// Increments by `speed` per frame until it reaches path.len.
    counter: f32 = 0,

    /// Stroke thickness (px).  Slider 0.5 - 8.
    thickness: f32 = 2.0,

    /// Animation speed in strokes/frame.  At 60 fps, speed=1 means
    /// one segment per frame (the raylib default).  speed=4 is
    /// faster for visibly comparing different orders.
    speed: f32 = 1.0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    gpa.free(s.path);
    s.scratch.deinit();
    s.ui_host.deinit();
}

/// The standard iterative Hilbert-step computation.  Walks the
/// base-4 digits of `index` from least to most significant; each
/// digit either keeps, transposes, reflects, or rotates the
/// running point.  See e.g. Sedgewick's "Algorithms" section 7.3.
fn computeHilbertStep(order: i32, index_in: i32) Vec2 {
    // Base U-shape: bottom-left -> top-left -> top-right -> bottom-right.
    const base: [4]Vec2 = .{
        .{ 0, 0 },
        .{ 0, 1 },
        .{ 1, 1 },
        .{ 1, 0 },
    };

    var index: i32 = index_in;
    var hilbert_index: i32 = index & 3;
    var vect: Vec2 = base[@intCast(hilbert_index)];

    var j: i32 = 1;
    while (j < order) : (j += 1) {
        index = index >> 2;
        hilbert_index = index & 3;
        const len_v: f32 = float(@as(i32, 1) << @as(u5, @intCast(j)));

        switch (hilbert_index) {
            // Bottom-left quadrant: swap x and y.
            0 => {
                const tmp: f32 = vect[0];
                vect[0] = vect[1];
                vect[1] = tmp;
            },
            // Top-left quadrant: shift up.
            1 => {
                vect[1] += len_v;
            },
            // Top-right quadrant: shift up + right.
            2 => {
                vect[0] += len_v;
                vect[1] += len_v;
            },
            // Bottom-right quadrant: rotate 180 deg within sub-grid.
            3 => {
                const tmp: f32 = len_v - 1 - vect[0];
                vect[0] = 2 * len_v - 1 - vect[1];
                vect[1] = tmp;
            },
            else => unreachable,
        }
    }
    return vect;
}

/// Allocate a fresh Hilbert path at the given order.  Caller
/// frees the previous one before swapping.
fn buildHilbertPath(
    gpa: Allocator,
    order: i32,
    size: f32,
) ![]Vec2 {
    const n_axis: usize = @as(usize, 1) << @as(u5, @intCast(order));
    const stroke_count: usize = n_axis * n_axis;
    const len: f32 = size / float(n_axis);
    const path: []Vec2 = try gpa.alloc(Vec2, stroke_count);
    for (path, 0..) |*p, i| {
        const step: Vec2 = computeHilbertStep(order, @intCast(i));
        p.* = .{ step[0] * len + len / 2.0, step[1] * len + len / 2.0 };
    }
    return path;
}

fn initState(
    gpa: Allocator,
    f: *z.Frame,
    s: *State,
) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 28);
    s.* = .{
        .scratch = std.heap.ArenaAllocator.init(gpa),
        .gpa = gpa,
        .ui_host = z.UiHost.init(gpa, font),
        .font = font,
        .path = &.{},
    };
    s.path = try buildHilbertPath(gpa, s.order, @as(f32, screen_h));
    s.cached_order = s.order;
}

fn drawUiPanel(f: *z.Frame, s: *State) void {
    const u: z.ui_real.Ui = s.ui_host.begin(f);

    if (u.window("Hilbert", .{})) |w| {
        defer w.close();

        _ = u.slider("Order", &s.order, .{ .min = min_order, .max = max_order, .fmt = "{d}" });
        _ = u.slider("Thickness", &s.thickness, .{ .min = 0.5, .max = 8, .fmt = "{d:.1}" });
        _ = u.slider("Speed", &s.speed, .{ .min = 0.25, .max = 20, .fmt = "{d:.2}" });

        u.separator();

        u.text("Strokes: {d} / {d}", .{
            int(usize, s.counter),
            s.path.len,
        });

        if (u.button("Restart", .{})) {
            s.counter = 0;
        }
    }
}

fn update(f: *z.Frame, state: *State) void {
    _ = state.scratch.reset(.retain_capacity);
    z.clearViewport(f, c.raywhite);

    drawUiPanel(f, state);

    // Rebuild the path if the slider changed `order` this frame.
    if (state.order != state.cached_order) {
        state.gpa.free(state.path);
        state.path = buildHilbertPath(state.gpa, state.order, @as(f32, screen_h)) catch
            return;
        state.cached_order = state.order;
        state.counter = 0;
    }

    // Tick `speed` segments per frame until we reach the end.
    if (state.counter < float(state.path.len)) {
        state.counter += state.speed;
    }
    const visible: usize = @min(
        int(usize, state.counter),
        state.path.len,
    );

    // ---- Render ------------------------------------------------------------

    // Each stroke's hue rolls 0 deg -> 360 deg across the full path.
    const stroke_total: f32 = float(state.path.len);
    var i: usize = 1;
    while (i <= visible and i < state.path.len) : (i += 1) {
        const hue = (float(i) / stroke_total) * 360.0;
        const stroke_color: Color = z.colorFromHSV(hue, 1.0, 1.0);
        f.gl.line(state.path[i], state.path[i - 1], .{ .color = stroke_color, .thickness = state.thickness });
    }

    state.ui_host.render(f);
    z.endDrawing(f.gl);
}

/// User-owned framework integration point.  See `examples/basic.zig`
/// for the canonical comment block; this declaration is the
/// AppBridge pattern's required convention.
/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - hilbert curve",
            .width = screen_w,
            .height = screen_h,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
