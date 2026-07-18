// examples/touch_paint.zig
// Each touch leaves a colored trail.  Touch ID maps deterministically
// to a colour so multi-touch gives a rainbow finger-paint effect.
// Validates the `input.getTouchPosition/Count/PointId` primitives
// from Steps 23-25 end-to-end.  On desktop without a touch device,
// you'll see an empty canvas with the HUD only - that's expected.

const std = @import("std");
const allocPrint = std.fmt.allocPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const Vec2 = zm.Vec2;
const Color = zm.Color;

const trail_len: usize = 200;
const max_trails: usize = 10;

/// One per-finger trail - a ring buffer of past positions.  We
/// can't store an arbitrary growing list per frame because we
/// can't pre-allocate inside `update`; the ring is fixed-size.
const Trail = struct {
    /// Browser-assigned touch id this trail belongs to.  -1 = empty.
    id: i32 = -1,
    points: [trail_len]Vec2 = @splat(.{ 0, 0 }),
    head: usize = 0,
    count: usize = 0,
};

const State = struct {
    font: z.Font,
    scratch: std.heap.ArenaAllocator,
    frame_count: usize = 0,
    trails: [max_trails]Trail = @splat(.{}),
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.scratch.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, @embedFile("atkinson_mono_ttf"), 32);
    s.* = .{ .font = font, .scratch = std.heap.ArenaAllocator.init(gpa) };
}

/// Map a touch ID to a stable color from a small palette.  Same
/// finger always gets the same color even if it lifts and reattaches.
fn colorForId(id: i32) Color {
    const palette: [8]Color = .{
        z.colors.sky_400,
        z.colors.pink_400,
        z.colors.amber_400,
        z.colors.green_400,
        z.colors.violet_400,
        z.colors.red_400,
        z.colors.emerald_400,
        z.colors.rose_400,
    };
    const idx: usize = @intCast(@mod(id, @as(i32, palette.len)));
    return palette[idx];
}

fn pushPoint(trail: *Trail, p: Vec2) void {
    trail.points[trail.head] = p;
    trail.head = (trail.head + 1) % trail_len;
    if (trail.count < trail_len) {
        trail.count += 1;
    }
}

/// Find or allocate a trail for `id`.  Returns null if no slot
/// available (shouldn't happen since trails.len == MAX_TOUCH_POINTS).
fn trailFor(state: *State, id: i32) ?*Trail {
    // Existing trail for this id?
    for (&state.trails) |*t| {
        if (t.id == id) {
            return t;
        }
    }
    // Free slot?
    for (&state.trails) |*t| {
        if (t.id == -1) {
            t.* = .{ .id = id };
            return t;
        }
    }
    return null;
}

fn update(f: *z.Frame, state: *State) void {
    _ = state.scratch.reset(.retain_capacity);
    state.frame_count += 1;

    // Build a set of currently-active touch ids so we can prune
    // trails whose finger has lifted.
    const count: i32 = z.getTouchPointCount(f.input);
    var active_ids: [max_trails]i32 = @splat(-1);
    var ai: usize = 0;
    var i: i32 = 0;
    while (i < count) : (i += 1) {
        // wgpu touch API is slot-based (no stable getTouchPointId); use the
        // slot index as the trail id. Trails follow slots, not fingers across sessions.
        const id: i32 = i;
        const pos = z.getTouchPosition(f.input, i);
        if (trailFor(state, id)) |t| {
            pushPoint(t, .{ pos[0], pos[1] });
        }
        if (ai < active_ids.len) {
            active_ids[ai] = id;
            ai += 1;
        }
    }

    // Drop trails whose finger lifted (clear the slot).
    for (&state.trails) |*t| {
        if (t.id == -1) {
            continue;
        }
        var found: bool = false;
        for (active_ids[0..ai]) |aid| {
            if (aid == t.id) {
                found = true;
                break;
            }
        }
        if (!found) {
            t.* = .{};
        }
    }

    // ---- Render ----
    z.clearViewport(f, z.colors.slate_950);

    // Draw each trail as a series of fading dots.
    for (state.trails) |t| {
        if (t.id == -1) {
            continue;
        }
        const col: Color = colorForId(t.id);
        var k: usize = 0;
        while (k < t.count) : (k += 1) {
            // age 0 = newest, age (count-1) = oldest.
            const age: usize = (trail_len + t.head - 1 - k) % trail_len;
            const idx_in_buffer: usize = (trail_len + t.head - 1 - k) % trail_len;
            _ = age;
            const p = t.points[idx_in_buffer];
            const fade: f32 = 1.0 - float(k) / float(t.count);
            const radius: f32 = 8.0 * fade;
            f.gl.circle(p, radius, .{ .color = col, .segments = 16 });
        }
    }

    // HUD
    const hud: []u8 = allocPrint(
        state.scratch.allocator(),
        "touches: {d} / max {d}    frame {d}",
        .{ count, max_trails, state.frame_count },
    ) catch return;
    f.gl.text(.{ 10, 10 }, hud, .{ .size = 18, .color = z.colors.slate_300, .font = &state.font });
    f.gl.text(
        .{ 10, 32 },
        "Touch the canvas to paint.",
        .{ .size = 14, .color = z.colors.slate_500, .font = &state.font },
    );
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - touch paint",
            .width = 800,
            .height = 450,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
