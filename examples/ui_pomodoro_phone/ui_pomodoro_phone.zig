//! ui_pomodoro_phone — a 25-minute pomodoro timer with an animated progress
//! ring, ported to WebGPU. Phone-shaped (420x760), big touch targets. Shows off
//! the shared `ui.zig` on the wgpu UiHost: a `beginCanvas` ring drawn with the
//! draw-list (addCircle track + addArc sweep + centred addText), `u.animated`
//! tweening the ring colour from calm green to warning red over the final minute,
//! and full-window no-chrome layout.
//!
//! Ported from the GL `ui_pomodoro_phone`. The GL `UiContext` (+ shapes_texture +
//! font_cache) becomes `z.UiHost`; the widget body is unchanged (same real
//! ui.zig). The one structural addition the wgpu path needs: an explicit
//! `beginDrawing`/`clearBackground` BEFORE `ui_host.begin` (the UI renders into
//! the open draw frame), paired with `endDrawing`.
const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const Color = zm.Color;
const clamp = zm.clamp;
const pi = zm.pi;
const ui = z.ui_real;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const session_seconds: f32 = 25 * 60; // classic 25-min pomodoro
const warning_seconds: f32 = 60; // last minute -> red

const Phase = enum {
    idle, // not yet started this session
    running,
    paused,
    done, // session complete; needs reset
};

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,

    phase: Phase = .idle,
    elapsed: f32 = 0, // seconds, [0..session_seconds]
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn init(gpa: Allocator, f: *z.Frame, s: *State) !void {
    // Larger atlas for the big timer readout; UI labels downscale from it.
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 56);
    s.* = .{ .font = font, .ui_host = z.UiHost.init(gpa, font) };
}

/// Linearly interpolate two RGBA colour structs — drives the ring colour
/// transition from the easing-curve output.
fn lerpColor(
    a: Color,
    b: Color,
    t: f32,
) Color {
    const tc: f32 = clamp(t, 0, 1);
    const af: Vec = .{
        @floatFromInt(a.r), @floatFromInt(a.g),
        @floatFromInt(a.b), @floatFromInt(a.a),
    };
    const bf: Vec = .{
        @floatFromInt(b.r), @floatFromInt(b.g),
        @floatFromInt(b.b), @floatFromInt(b.a),
    };
    const mix: Vec = af + (bf - af) * @as(Vec, @splat(tc));
    return .{
        .r = @trunc(mix[0]),
        .g = @trunc(mix[1]),
        .b = @trunc(mix[2]),
        .a = @trunc(mix[3]),
    };
}

fn formatMinSec(buf: []u8, total_sec: f32) []const u8 {
    // u32 (not i32) so `{d:0>2}` doesn't print a leading '+' sign. Clamped to
    // zero via @max so a negative input is harmless.
    const sec_total: u32 = @trunc(@max(0, @ceil(total_sec)));
    const mins: u32 = sec_total / 60;
    const secs: u32 = sec_total % 60;
    return bufPrint(buf, "{d:0>2}:{d:0>2}", .{ mins, secs }) catch buf[0..0];
}

fn update(f: *z.Frame, s: *State) void {
    // Descriptor app: the runner/launcher owns begin/clear/end. The fullscreen
    // panel below covers everything, so no separate background fill is needed.
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    // ---- Tick the timer while running -----------------------
    if (s.phase == .running) {
        s.elapsed += f.time.delta_time;
        if (s.elapsed >= session_seconds) {
            s.elapsed = session_seconds;
            s.phase = .done;
        }
    }
    const remaining: f32 = @max(0, session_seconds - s.elapsed);
    const progress: f32 = if (session_seconds > 0)
        clamp(s.elapsed / session_seconds, 0, 1)
    else
        0;

    // Fullscreen window, no chrome — phone-style.
    const fw: f32 = f.window.widthf();
    const fh: f32 = f.window.heightf();
    u.setNextWindowPos(.{ 0, 0 }, .{});
    u.setNextWindowSize(.{ fw, fh }, .{});
    if (u.window("pomodoro", .{
        .flags = .{
            .no_title_bar = true,
            .no_resize = true,
            .no_move = true,
            .no_collapse = true,
        },
    })) |w| {
        defer w.close();

        u.text("Focus Session", .{});
        u.spacing();

        // ---- Progress ring (canvas) -------------------------
        const ring_size: f32 = @min(fw - 40, fh - 320);
        const ring_dim: Vec2 = .{ ring_size, ring_size };
        if (u.beginCanvas("ring", ring_dim, .{})) |c| {
            defer u.endCanvas(c);
            const cx: f32 = c.rect.x + c.rect.width * 0.5;
            const cy: f32 = c.rect.y + c.rect.height * 0.5;
            const r_outer: f32 = ring_size * 0.45;
            const thickness: f32 = ring_size * 0.05;

            // Track (background ring).
            c.drawList().addCircle(.{ cx, cy }, r_outer, Color.fromWire(0xFF2A2D38), thickness);

            // Active arc — sweep from 12-o'clock proportional to progress.
            // addArc uses standard math angles (CCW positive, 0 = +X), so start
            // at -pi/2 (top) and grow in +angle. Clamp to ~10 deg so even a few
            // seconds of a 25-min session gives immediate visual feedback
            // (cosmetic only — the numeric readout is always exact).
            const tau: f32 = zm.tau;
            const min_visible_sweep: f32 = tau / 36.0; // 10 deg
            const sweep: f32 = if (progress > 0)
                @max(tau * progress, min_visible_sweep)
            else
                0;
            const a0: f32 = -pi * 0.5;
            const a1: f32 = a0 + sweep;

            // Ring colour tweens calm green -> warning red over 2s once the
            // final minute starts. `u.animated` restarts when `to` changes.
            const want_warn: f32 = if (remaining <= warning_seconds and s.phase == .running) 1.0 else 0.0;
            const warn_t: f32 = u.animated("ring_warn", .{
                .from = 0,
                .to = want_warn,
                .duration = 2.0,
                .easing = .ease_out,
            });
            const col_calm: Color = .{ .r = 90, .g = 180, .b = 110, .a = 255 };
            const col_warn: Color = .{ .r = 220, .g = 80, .b = 80, .a = 255 };
            const ring_col: Color = lerpColor(col_calm, col_warn, warn_t);

            if (sweep > 0) {
                c.drawList().addArc(.{ cx, cy }, r_outer, a0, a1, ring_col, thickness * 1.4);
            }

            // Timer text centred by hand (addText takes a top-left position).
            var buf: [16]u8 = undefined;
            const txt: []const u8 = formatMinSec(&buf, remaining);
            const text_size: Vec2 = u.calcTextSize(txt);
            const tx: f32 = cx - text_size[0] * 0.5;
            const ty: f32 = cy - text_size[1] * 0.5;
            c.drawList().addText(txt, .{ tx, ty }, 56, ring_col);
        }

        u.spacing();
        u.spacing();

        // ---- Buttons ----------------------------------------
        const btn_label: []const u8 = switch (s.phase) {
            .idle => "Start",
            .running => "Pause",
            .paused => "Resume",
            .done => "Done",
        };
        if (u.button(btn_label, .{ .size = .{ fw - 40, 64 } })) {
            switch (s.phase) {
                .idle, .paused => s.phase = .running,
                .running => s.phase = .paused,
                .done => {}, // wait for Reset
            }
        }
        u.spacing();
        if (u.button("Reset", .{ .size = .{ fw - 40, 56 } })) {
            s.phase = .idle;
            s.elapsed = 0;
        }

        u.spacing();
        switch (s.phase) {
            .idle => u.text("Tap Start to begin.", .{}),
            .running => u.text("Focusing...", .{}),
            .paused => u.text("Paused.", .{}),
            .done => u.text("Done!  Tap Reset for another round.", .{}),
        }
    }
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{ .window = .{
        .title = "zimr - WebGPU - Pomodoro (phone)",
        .width = 420,
        .height = 760,
        .scale_mode = .responsive,
        .depth_format = null,
    } },
    .init = init,
    .deinit = deinit,
    .update = update,
};
