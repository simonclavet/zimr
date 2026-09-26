// examples/ui_animation_gallery.zig
//
// Live demo of `u.animated` (one-shot tween with selectable
// easing curve) and `u.spring` (critically-damped physical
// spring tracking a target).
//
// Layout:
//   - Six tween rows, one per easing curve.  Each row shows a
//     moving dot that ping-pongs between two anchor positions on
//     a 2-second cycle.  All six tweens share a phase clock so
//     callers can see the curves visually compared.
//   - One spring row at the bottom: drag the slider to set a
//     target; the spring's dot chases.  Adjusting the slider
//     mid-flight shows interruptibility.
//   - One stiffness/damping pair lets the viewer tune the
//     spring's feel.
//
// All animation state lives in `ext_storage` via `getOrPutState`,
// keyed off label strings.  No app-owned animation bookkeeping.
//
// Build standalone:
//   zig build install -Dfocus=ui_animation_gallery
//   python3 scripts/build_standalone.py ui_animation_gallery

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const ui = z.ui_real;

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,

    // App-owned phase ticker - drives the ping-pong target for
    // the tween rows.  Not strictly needed (the tweens themselves
    // restart on `to` change), but it's how a real app would
    // produce the "bounce between two anchors" effect.
    cycle_t: f32 = 0,

    // User-tunable spring target + parameters.
    spring_target: f32 = 100,
    spring_stiffness: f32 = 200,
    spring_damping: f32 = 1.0,
};

const row_height: f32 = 36;
const track_inset: f32 = 12;
const dot_radius: f32 = 8;

const EasingRow = struct {
    label: []const u8,
    easing: ui.Easing,
};

const easing_rows = [_]EasingRow{
    .{ .label = "linear", .easing = .linear },
    .{ .label = "ease_in", .easing = .ease_in },
    .{ .label = "ease_out", .easing = .ease_out },
    .{ .label = "ease_in_out", .easing = .ease_in_out },
    .{ .label = "back", .easing = .back },
    .{ .label = "elastic", .easing = .elastic },
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, @embedFile("atkinson_mono_ttf"), 22);
    s.* = .{ .font = font, .ui_host = z.UiHost.init(gpa, font) };
}

fn drawTweenRow(
    u: ui.Ui,
    row: EasingRow,
    phase_to_right: bool,
) void {
    // Reserve a row's worth of space.  Label on the left, track
    // on the right.
    const it: ui.Ui.ItemCtx = u.beginItem(row.label, .{
        .size = .{ 440, row_height },
    }) orelse return;
    defer u.endItem(it);

    // Label inside the reserved rect.
    u.getForegroundDrawList().addText(row.label, .{ it.rect.x + 4, it.rect.y + 8 }, 14, Color.fromWire(0xFFD0D0D0));

    // Track starts after the label area (90 px) and ends at the
    // right edge with a small inset.
    const track_x0: f32 = it.rect.x + 100;
    const track_x1: f32 = it.rect.x + it.rect.width - track_inset;
    const track_y: f32 = it.rect.y + it.rect.height / 2;
    u.getForegroundDrawList().addLine(
        .{ track_x0, track_y },
        .{ track_x1, track_y },
        Color.fromWire(0xFF404858),
        2,
    );

    // Tween the dot's normalized position [0..1].
    const target: f32 = if (phase_to_right) 1.0 else 0.0;
    const t: f32 = u.animated(row.label, .{
        .from = 1.0 - target,
        .to = target,
        .duration = 1.0,
        .easing = row.easing,
    });

    const dot_x: f32 = track_x0 + (track_x1 - track_x0) * t;
    u.getForegroundDrawList().addCircleFilled(.{ dot_x, track_y }, dot_radius, Color.fromWire(0xFF6DB0E0));
}

fn drawSpringRow(
    u: ui.Ui,
    target: f32,
    stiffness: f32,
    damping: f32,
) void {
    const it: ui.Ui.ItemCtx = u.beginItem("spring_row", .{
        .size = .{ 440, row_height * 2 },
    }) orelse return;
    defer u.endItem(it);

    // Track spans the row, with a slight inset on each side.
    const track_x0: f32 = it.rect.x + track_inset;
    const track_x1: f32 = it.rect.x + it.rect.width - track_inset;
    const track_y: f32 = it.rect.y + it.rect.height / 2;
    u.getForegroundDrawList().addLine(
        .{ track_x0, track_y },
        .{ track_x1, track_y },
        Color.fromWire(0xFF404858),
        2,
    );

    // Target marker - a thin vertical line at the slider value.
    const target_x: f32 = track_x0 + target;
    u.getForegroundDrawList().addLine(
        .{ target_x, track_y - 14 },
        .{ target_x, track_y + 14 },
        Color.fromWire(0xFFA0A0A0),
        1,
    );

    // Spring's actual current value chasing the target.
    const v: f32 = u.spring("spring_demo", .{
        .target = target,
        .stiffness = stiffness,
        .damping = damping,
    });
    const dot_x: f32 = track_x0 + v;
    u.getForegroundDrawList().addCircleFilled(.{ dot_x, track_y }, dot_radius, Color.fromWire(0xFFE07B5C));
}

fn update(f: *z.Frame, s: *State) void {
    z.clearViewport(f, .{ .r = 18, .g = 22, .b = 32, .a = 255 });

    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    // Advance the shared phase ticker.  Tweens ping-pong between
    // two anchors on a 2-second cycle.
    const cycle_sec: f32 = 2.0;
    s.cycle_t += u.ctx.input.delta_time;
    if (s.cycle_t >= cycle_sec) {
        s.cycle_t = 0;
    }
    const phase_to_right: bool = s.cycle_t < (cycle_sec / 2.0);

    if (u.window("Animations", .{
        .initial_pos = .{ 8, 8 },
        .initial_size = .{ 464, 700 },
    })) |w| {
        defer w.close();

        u.text("Tweens - six easing curves", .{});
        u.separator();

        // Each row renders its own track + dot.  The dot's
        // x-position comes from `u.animated`; the to-value flips
        // every cycle_sec/2 seconds so the dot ping-pongs.
        for (easing_rows) |row| {
            drawTweenRow(u, row, phase_to_right);
        }

        u.separator();
        u.text("Spring - drag the slider, watch it chase", .{});

        _ = u.slider("target", &s.spring_target, .{ .min = 0, .max = 380 });
        _ = u.slider("stiffness", &s.spring_stiffness, .{ .min = 20, .max = 800 });
        _ = u.slider("damping", &s.spring_damping, .{ .min = 0.2, .max = 2.5 });

        drawSpringRow(u, s.spring_target, s.spring_stiffness, s.spring_damping);
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - animation gallery",
            .width = 480,
            .height = 720,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
