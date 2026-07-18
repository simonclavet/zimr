// examples/ellipse_collision.zig - two ellipses, point-and-ellipse predicates.
// Two ellipses (A: 120×70, B: 90×140 by default).  A "Controls"
// panel chooses which ellipse follows the cursor and lets you
// resize both axes of each ellipse live; the other ellipse stays
// where you last released it.  Ellipses turn red when their
// boundaries intersect - separately, the HUD reports whether the
// cursor itself is inside the *non-controlled* ellipse.
// Two original predicates ported from raylib's example:
//   pointInEllipse(p, c, rx, ry)
//       = (((p − c)[0] / rx)² + ((p − c)[1] / ry)²) ≤ 1
//   ellipsesIntersect(c1, rx1, ry1, c2, rx2, ry2)
//       Walk the line from c1 to c2, compute the radial distance
//       from each ellipse's centre to its boundary in the
//       direction θ of that line, and check whether the sum of
//       the two radial distances is ≥ |c2 − c1|.  Exact for axis-
//       aligned ellipses; conservative for rotated ones (which
//       we don't have here).
// Ported from raylib's `shapes_ellipse_collision.c`; A/B keys
// promoted to imgui radio buttons + the radii became sliders so
// the boundary-formula's behaviour can be probed continuously.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const roboto_mono_ttf = @embedFile("roboto_mono_ttf");
const Vec2 = zm.Vec2;
const atan2 = zm.atan2;
const c = Color;

const screen_w: i32 = 800;
const screen_h: i32 = 450;

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,

    /// Centre + radii of ellipse A (red/blue).
    a_center: Vec2 = .{ @as(f32, screen_w) / 4.0, @as(f32, screen_h) / 2.0 },
    a_rx: f32 = 120.0,
    a_ry: f32 = 70.0,

    /// Centre + radii of ellipse B (red/green).  Tall + narrow,
    /// to make the radial-boundary maths visibly asymmetric.
    b_center: Vec2 = .{ @as(f32, screen_w) * 3.0 / 4.0, @as(f32, screen_h) / 2.0 },
    b_rx: f32 = 90.0,
    b_ry: f32 = 140.0,

    /// 0 = A follows the cursor; 1 = B does.  Bound to the radio
    /// pair in the UI panel.
    controlled: i32 = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, roboto_mono_ttf, 28);
    s.* = .{ .ui_host = z.UiHost.init(gpa, font), .font = font };
}

/// Is `p` inside the axis-aligned ellipse centred at `c` with
/// half-extents (rx, ry)?  Standard normalised-distance test.
fn pointInEllipse(
    p: Vec2,
    center: Vec2,
    rx: f32,
    ry: f32,
) bool {
    const dx: f32 = (p[0] - center[0]) / rx;
    const dy: f32 = (p[1] - center[1]) / ry;
    return (dx * dx + dy * dy) <= 1.0;
}

/// Do two axis-aligned ellipses overlap?  Walk the line connecting
/// the centres; in that direction, each ellipse has a known radial
/// extent from its centre to its boundary.  They overlap iff the
/// sum of those two extents is ≥ the distance between centres.
fn ellipsesIntersect(
    c1: Vec2,
    rx1: f32,
    ry1: f32,
    c2: Vec2,
    rx2: f32,
    ry2: f32,
) bool {
    const dx: f32 = c2[0] - c1[0];
    const dy: f32 = c2[1] - c1[1];
    const dist: f32 = @sqrt(dx * dx + dy * dy);
    if (dist == 0.0) {
        return true;
    } // concentric

    // Angle from c1 toward c2, used to evaluate the ellipses'
    // radial-boundary functions in that direction.
    const theta: f32 = atan2(dy, dx);
    const cos_t: f32 = @cos(theta);
    const sin_t: f32 = @sin(theta);

    // r(theta) = (rx * ry) / sqrt((ry·cos)² + (rx·sin)²)
    // i.e. the distance from the ellipse's centre to its boundary
    // along the ray at angle theta.
    const r1_num: f32 = rx1 * ry1;
    const r1_den_sq: f32 = (ry1 * cos_t) * (ry1 * cos_t) + (rx1 * sin_t) * (rx1 * sin_t);
    const r1: f32 = r1_num / @sqrt(r1_den_sq);

    const r2_num: f32 = rx2 * ry2;
    const r2_den_sq: f32 = (ry2 * cos_t) * (ry2 * cos_t) + (rx2 * sin_t) * (rx2 * sin_t);
    const r2: f32 = r2_num / @sqrt(r2_den_sq);

    return dist <= (r1 + r2);
}

/// Submit the imgui panel and return whether the UI captured the
/// mouse this frame.
fn drawUiPanel(f: *z.Frame, s: *State) bool {
    const u: z.ui_real.Ui = s.ui_host.begin(f);

    if (u.window("Controls", .{})) |w| {
        defer w.close();

        u.text("Cursor drives the chosen ellipse", .{});
        u.separator();

        _ = u.radioButton("Ellipse A", &s.controlled, 0);
        u.sameLine(.{});
        _ = u.radioButton("Ellipse B", &s.controlled, 1);

        u.separator();

        u.text("Ellipse A radii", .{});
        _ = u.slider("##a_rx", &s.a_rx, .{ .min = 10, .max = 300, .fmt = "rx {d:.0}" });
        _ = u.slider("##a_ry", &s.a_ry, .{ .min = 10, .max = 200, .fmt = "ry {d:.0}" });

        u.separator();

        u.text("Ellipse B radii", .{});
        _ = u.slider("##b_rx", &s.b_rx, .{ .min = 10, .max = 300, .fmt = "rx {d:.0}" });
        _ = u.slider("##b_ry", &s.b_ry, .{ .min = 10, .max = 200, .fmt = "ry {d:.0}" });
    }

    return u.wantCaptureMouse();
}

fn update(f: *z.Frame, state: *State) void {
    // ---- UI first so we know if mouse is captured ------------------------
    const ui_capture_mouse: bool = drawUiPanel(f, state);

    // ---- Canvas mouse drive -----------------------------------------------
    const mp: Vec2 = z.getMousePosition(f.input);
    const mouse: Vec2 = .{ mp[0], mp[1] };
    if (!ui_capture_mouse) {
        if (state.controlled == 0) {
            state.a_center = mouse;
        } else {
            state.b_center = mouse;
        }
    }

    const collide: bool = ellipsesIntersect(
        state.a_center,
        state.a_rx,
        state.a_ry,
        state.b_center,
        state.b_rx,
        state.b_ry,
    );
    const mouse_in_a: bool = pointInEllipse(mouse, state.a_center, state.a_rx, state.a_ry);
    const mouse_in_b: bool = pointInEllipse(mouse, state.b_center, state.b_rx, state.b_ry);

    // ---- Render -----------------------------------------------------------

    z.clearViewport(f, c.raywhite);

    const color_a: Color = if (collide) c.red else c.blue;
    const color_b: Color = if (collide) c.red else c.green;

    f.gl.ellipse(state.a_center, state.a_rx, state.a_ry, .{ .color = color_a });
    f.gl.ellipse(state.b_center, state.b_rx, state.b_ry, .{ .color = color_b });
    f.gl.ellipseLines(state.a_center, state.a_rx, state.a_ry, .{ .color = c.white });
    f.gl.ellipseLines(state.b_center, state.b_rx, state.b_ry, .{ .color = c.white });

    // Centre dots - visual anchors so the user sees where the
    // ellipse's geometric centre is.
    f.gl.circle(state.a_center, 4, .{ .color = c.white, .segments = 16 });
    f.gl.circle(state.b_center, 4, .{ .color = c.white, .segments = 16 });

    if (collide) {
        f.gl.text(
            .{ screen_w / 2 - 120, 40 },
            "ELLIPSES COLLIDE",
            .{ .size = 28, .color = c.red, .font = &state.font },
        );
    } else {
        f.gl.text(
            .{ screen_w / 2 - 80, 40 },
            "NO COLLISION",
            .{ .size = 28, .color = c.darkgray, .font = &state.font },
        );
    }

    // "Mouse inside the non-controlled ellipse" is the
    // genuinely interesting predicate - controlled ellipse always
    // contains the cursor, so checking that side is uninteresting.
    if (mouse_in_a and state.controlled != 0) {
        f.gl.text(
            .{ 20, screen_h - 30 },
            "Mouse inside ellipse A",
            .{ .size = 20, .color = c.blue, .font = &state.font },
        );
    }
    if (mouse_in_b and state.controlled != 1) {
        f.gl.text(
            .{ 20, screen_h - 30 },
            "Mouse inside ellipse B",
            .{ .size = 20, .color = c.green, .font = &state.font },
        );
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
            .title = "zimr - ellipse collision",
            .width = screen_w,
            .height = screen_h,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
