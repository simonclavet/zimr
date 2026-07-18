//! gallery_all — the multi-app LAUNCHER (P3). A descriptor-only app whose
//! State holds a z.Launcher hosting four independent child apps in a 2x2 grid,
//! each with its OWN leak-checking allocator. Tap a cell to reset that child
//! (deinit -> leak-check -> re-init). Three cells use reflow placement (the
//! child sees the cell size); the fourth (orbit) uses scale_to_fit (a 300x300
//! design letterboxed into its cell) to exercise the scaled path.
//!
//! The four children are tiny INLINE descriptor apps with DIFFERENT State types
//! (proving type-erasure) and ZERO allocations (so reset's leak-check passes
//! silently — a clean reset). Real, font/GPU-allocating examples (starfield, the
//! UI ones) drop into cells the same way once they have an unloadFont/teardown
//! path; the launcher's leak check is what will flag a missing one.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Vec2 = zm.Vec2;
const Color = zm.Color;
const float = zm.float;
const pi = zm.pi;
const c = Color;

// ===========================================================================
// Four inline toy apps. Each: a State, init (no alloc), deinit (no-op), update.
// ===========================================================================

const Bouncer = struct { x: f32, y: f32, vx: f32, vy: f32 };
fn bouncerInit(gpa: Allocator, f: *z.Frame, s: *Bouncer) !void {
    _ = gpa;
    _ = f;
    s.* = .{ .x = 50, .y = 40, .vx = 150, .vy = 115 };
}
fn bouncerDeinit(gpa: Allocator, s: *Bouncer) void {
    _ = gpa;
    _ = s;
}
fn bouncerUpdate(f: *z.Frame, s: *Bouncer) void {
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    const dt: f32 = f.time.delta_time;
    const r: f32 = 14;
    s.x += s.vx * dt;
    s.y += s.vy * dt;
    if (s.x < r) {
        s.x = r;
        s.vx = -s.vx;
    }
    if (s.x > w - r) {
        s.x = w - r;
        s.vx = -s.vx;
    }
    if (s.y < r) {
        s.y = r;
        s.vy = -s.vy;
    }
    if (s.y > h - r) {
        s.y = h - r;
        s.vy = -s.vy;
    }
    f.gl.rect(.{ .x = 0, .y = 0, .width = w, .height = h }, .{ .color = c.init(20, 24, 34, 255) });
    f.gl.circle(.{ s.x, s.y }, r, .{ .color = z.colors.sky_300, .segments = 16 });
}
const bouncer_app: z.AppSpec(Bouncer) = .{
    .config = .{},
    .init = bouncerInit,
    .deinit = bouncerDeinit,
    .update = bouncerUpdate,
};

const Pulse = struct { t: f32 };
fn pulseInit(gpa: Allocator, f: *z.Frame, s: *Pulse) !void {
    _ = gpa;
    _ = f;
    s.* = .{ .t = 0 };
}
fn pulseDeinit(gpa: Allocator, s: *Pulse) void {
    _ = gpa;
    _ = s;
}
inline fn lerpU8(a: u8, b: u8, t: f32) u8 {
    const af: f32 = float(a);
    const bf: f32 = float(b);
    return @trunc(af + t * (bf - af));
}

fn pulseUpdate(f: *z.Frame, s: *Pulse) void {
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    s.t += f.time.delta_time;
    const phase: f32 = 0.5 + 0.5 * @sin(s.t * 1.5);
    const a: Color = z.colors.violet_500;
    const b: Color = z.colors.pink_500;
    const bg: Color = .{
        .r = lerpU8(a.r, b.r, phase),
        .g = lerpU8(a.g, b.g, phase),
        .b = lerpU8(a.b, b.b, phase),
        .a = 255,
    };
    f.gl.rect(.{ .x = 0, .y = 0, .width = w, .height = h }, .{ .color = bg });
    const radius: f32 = (@min(w, h) * 0.18) * (0.6 + 0.4 * phase);
    f.gl.circle(.{ w * 0.5, h * 0.5 }, radius, .{ .color = z.colors.slate_50, .segments = 16 });
}
const pulse_app: z.AppSpec(Pulse) = .{
    .config = .{},
    .init = pulseInit,
    .deinit = pulseDeinit,
    .update = pulseUpdate,
};

const Spinner = struct { angle: f32 };
fn spinnerInit(gpa: Allocator, f: *z.Frame, s: *Spinner) !void {
    _ = gpa;
    _ = f;
    s.* = .{ .angle = 0 };
}
fn spinnerDeinit(gpa: Allocator, s: *Spinner) void {
    _ = gpa;
    _ = s;
}
fn spinnerUpdate(f: *z.Frame, s: *Spinner) void {
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    s.angle += f.time.delta_time * 1.2;
    f.gl.rect(.{ .x = 0, .y = 0, .width = w, .height = h }, .{ .color = c.init(28, 22, 14, 255) });
    const cx: f32 = w * 0.5;
    const cy: f32 = h * 0.5;
    const r: f32 = @min(w, h) * 0.3;
    const two_pi: f32 = pi * 2;
    var verts: [3]Vec2 = undefined;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const ang: f32 = s.angle + float(i) * (two_pi / 3);
        verts[i] = .{ cx + r * @cos(ang), cy + r * @sin(ang) };
    }
    f.gl.triangle(verts[0], verts[1], verts[2], .{ .color = z.colors.amber_400 });
    f.gl.triangleLines(verts[0], verts[1], verts[2], .{ .color = z.colors.amber_200 });
}
const spinner_app: z.AppSpec(Spinner) = .{
    .config = .{},
    .init = spinnerInit,
    .deinit = spinnerDeinit,
    .update = spinnerUpdate,
};

// Orbit: drawn in a FIXED 300x300 design space, letterboxed into its cell via
// scale_to_fit — so it shows the scaled placement path.
const orbit_design: f32 = 300;
const Orbit = struct { t: f32 };
fn orbitInit(gpa: Allocator, f: *z.Frame, s: *Orbit) !void {
    _ = gpa;
    _ = f;
    s.* = .{ .t = 0 };
}
fn orbitDeinit(gpa: Allocator, s: *Orbit) void {
    _ = gpa;
    _ = s;
}
fn orbitUpdate(f: *z.Frame, s: *Orbit) void {
    const w: f32 = f.window.widthf(); // == orbit_design under scale_to_fit
    const h: f32 = f.window.heightf();
    s.t += f.time.delta_time;
    f.gl.rect(.{ .x = 0, .y = 0, .width = w, .height = h }, .{ .color = c.init(10, 20, 18, 255) });
    const cx: f32 = w * 0.5;
    const cy: f32 = h * 0.5;
    const orbit_r: f32 = @min(w, h) * 0.36;
    const px: f32 = cx + orbit_r * @cos(s.t * 1.3);
    const py: f32 = cy + orbit_r * @sin(s.t * 1.3);
    f.gl.circle(.{ cx, cy }, 6, .{ .color = z.colors.slate_500, .segments = 16 });
    f.gl.line(.{ cx, cy }, .{ px, py }, .{ .color = z.colors.emerald_500, .thickness = 2 });
    f.gl.circle(.{ px, py }, 10, .{ .color = z.colors.emerald_500, .segments = 16 });
}
const orbit_app: z.AppSpec(Orbit) = .{
    .config = .{ .window = .{ .width = 300, .height = 300 } },
    .init = orbitInit,
    .deinit = orbitDeinit,
    .update = orbitUpdate,
};

// ===========================================================================
// The launcher app
// ===========================================================================

const State = struct {
    launcher: z.Launcher,
    ids: [4]z.ChildId = undefined,
};

fn init(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{ .launcher = z.Launcher.init(gpa) };
    s.ids[0] = try s.launcher.add(f, z.eraseApp(bouncer_app));
    s.ids[1] = try s.launcher.add(f, z.eraseApp(pulse_app));
    s.ids[2] = try s.launcher.add(f, z.eraseApp(spinner_app));
    s.ids[3] = try s.launcher.add(f, z.eraseApp(orbit_app));
}

fn deinit(gpa: Allocator, s: *State) void {
    _ = gpa;
    s.launcher.deinit();
}

fn update(f: *z.Frame, s: *State) void {
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    const cw: f32 = w * 0.5;
    const ch: f32 = h * 0.5;
    f.gl.rect(.{ .x = 0, .y = 0, .width = w, .height = h }, .{ .color = c.init(8, 10, 16, 255) });

    const cells = [4]z.Rectangle{
        .{ .x = 0, .y = 0, .width = cw, .height = ch },
        .{ .x = cw, .y = 0, .width = cw, .height = ch },
        .{ .x = 0, .y = ch, .width = cw, .height = ch },
        .{ .x = cw, .y = ch, .width = cw, .height = ch },
    };

    // Tap a cell to reset that child (clean reset; its leak-check passes).
    if (z.isMouseButtonPressed(f.input, .left)) {
        const m: Vec2 = z.getMousePosition(f.input);
        for (cells, 0..) |cell, i| {
            const inside: bool = m[0] >= cell.x and m[0] < cell.x + cell.width and
                m[1] >= cell.y and m[1] < cell.y + cell.height;
            if (inside) {
                s.launcher.reset(f, s.ids[i]);
            }
        }
    }

    // Tick: three reflow cells + one scale_to_fit (orbit, 300x300 design).
    s.launcher.tick(f, s.ids[0], .{ .rect = cells[0], .logical_w = cw, .logical_h = ch });
    s.launcher.tick(f, s.ids[1], .{ .rect = cells[1], .logical_w = cw, .logical_h = ch });
    s.launcher.tick(f, s.ids[2], .{ .rect = cells[2], .logical_w = cw, .logical_h = ch });
    s.launcher.tick(f, s.ids[3], .{
        .rect = cells[3],
        .logical_w = orbit_design,
        .logical_h = orbit_design,
        .scale_to_fit = true,
    });

    const gc: Color = z.colors.slate_700;
    f.gl.line(.{ cw, 0 }, .{ cw, h }, .{ .color = gc, .thickness = 1.0 });
    f.gl.line(.{ 0, ch }, .{ w, ch }, .{ .color = gc, .thickness = 1.0 });
}

pub const app: z.AppSpec(State) = .{
    .config = .{ .window = .{
        .title = "zimr - WebGPU - multi-app gallery",
        .width = 800,
        .height = 450,
        .scale_mode = .responsive,
        .depth_format = null,
    } },
    .init = init,
    .deinit = deinit,
    .update = update,
    .memory = .managed,
};
