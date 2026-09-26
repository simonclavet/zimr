//! ecs_boids - Reynolds flocking on the zimr ECS, ported to WebGPU. ~160 boids live
//! in an archetype of Pos + Vel components. Each frame: a snapshot via `iterator` feeds a
//! steering `forEach` (separation/alignment/cohesion), then integrate-and-wrap, then a
//! render `iterator`. Proves the ECS subsystem (Registry, archetypes, iterator, forEach)
//! on the wgpu backend. Self-running, viewport-relative under `.responsive`.
//!
//! IMPORTANT: Pos and Vel are DISTINCT struct types, not both `Vec2`. The ECS keys
//! components by type, so two components of the same type collide into one - reading Pos
//! would return Vel data. Each component needs its own nominal type.
const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Vec2 = zm.Vec2;
const Color = zm.Color;
const float = zm.float;
const tau = zm.tau;
const ecs = z.ecs;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
const c = Color;

const num_boids: usize = 160;
const max_speed: f32 = 140;
const min_speed: f32 = 60;

const Pos = struct { x: f32 = 0, y: f32 = 0 };
const Vel = struct { x: f32 = 0, y: f32 = 0 };
const Snap = struct { p: Pos, v: Vel };

const Params = struct {
    neighbor_radius: f32 = 60,
    separation_radius: f32 = 18,
    alignment_factor: f32 = 0.06,
    cohesion_factor: f32 = 0.0009,
    separation_factor: f32 = 1.4,
};
const params: Params = .{};

const SteerCtx = struct {
    snap: []const Snap,
};

const IntegrateCtx = struct {
    dt: f32,
    w: f32,
    h: f32,
};

const State = struct {
    font: z.Font,
    es: ecs.Registry,
    rng: std.Random.DefaultPrng,
    snap: [num_boids]Snap = undefined,
    frame_count: usize = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.es.deinit(gpa);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24);
    var es: ecs.Registry = try .init(.{
        .gpa = gpa,
        .cap = .{ .entities = num_boids + 16, .arches = 4, .chunks = 8, .chunk = 4096 },
    });
    errdefer es.deinit(gpa);
    var rng: std.Random.DefaultPrng = .init(0xB01D5);
    const r: std.Random = rng.random();
    const w: f32 = @max(64.0, f.window.widthf());
    const h: f32 = @max(64.0, f.window.heightf());
    for (0..num_boids) |_| {
        const e: ecs.Entity = try ecs.Entity.reserveImmediateOrErr(&es);
        const angle: f32 = r.float(f32) * tau;
        const speed: f32 = min_speed + r.float(f32) * (max_speed - min_speed);
        _ = try e.changeArchImmediateOrErr(&es, gpa, struct {
            pos: Pos,
            vel: Vel,
        }, .{
            .add = .{
                .pos = .{ .x = r.float(f32) * w, .y = r.float(f32) * h },
                .vel = .{ .x = @cos(angle) * speed, .y = @sin(angle) * speed },
            },
        });
    }
    s.* = .{ .font = font, .es = es, .rng = rng };
}

/// Three Reynolds rules from the immutable snapshot, then a speed clamp.
fn steerBoid(
    ctx: SteerCtx,
    p: *const Pos,
    v: *Vel,
) void {
    var sep_x: f32 = 0;
    var sep_y: f32 = 0;
    var ali_x: f32 = 0;
    var ali_y: f32 = 0;
    var coh_x: f32 = 0;
    var coh_y: f32 = 0;
    var neighbor_count: usize = 0;

    for (ctx.snap) |other| {
        if (other.p.x == p.x and other.p.y == p.y and other.v.x == v.x and other.v.y == v.y) {
            continue;
        }
        const dx: f32 = other.p.x - p.x;
        const dy: f32 = other.p.y - p.y;
        const d: f32 = @sqrt(dx * dx + dy * dy);
        if (d > params.neighbor_radius) {
            continue;
        }
        coh_x += other.p.x;
        coh_y += other.p.y;
        ali_x += other.v.x;
        ali_y += other.v.y;
        neighbor_count += 1;
        if (d < params.separation_radius and d > 0.001) {
            const inv: f32 = 1.0 / d;
            sep_x += -dx * inv;
            sep_y += -dy * inv;
        }
    }

    if (neighbor_count > 0) {
        const inv_count: f32 = 1.0 / float(neighbor_count);
        v.x += (ali_x * inv_count - v.x) * params.alignment_factor;
        v.y += (ali_y * inv_count - v.y) * params.alignment_factor;
        v.x += (coh_x * inv_count - p.x) * params.cohesion_factor;
        v.y += (coh_y * inv_count - p.y) * params.cohesion_factor;
        v.x += sep_x * params.separation_factor;
        v.y += sep_y * params.separation_factor;
    }

    const speed: f32 = @sqrt(v.x * v.x + v.y * v.y);
    if (speed > max_speed) {
        const scale: f32 = max_speed / speed;
        v.x *= scale;
        v.y *= scale;
    } else if (speed < min_speed and speed > 0.001) {
        const scale: f32 = min_speed / speed;
        v.x *= scale;
        v.y *= scale;
    }
}

/// Move by velocity; toroidal wrap against the live viewport.
fn integrateAndWrap(
    ctx: IntegrateCtx,
    p: *Pos,
    v: *const Vel,
) void {
    p.x += v.x * ctx.dt;
    p.y += v.y * ctx.dt;
    if (p.x < 0) {
        p.x += ctx.w;
    } else if (p.x >= ctx.w) {
        p.x -= ctx.w;
    }
    if (p.y < 0) {
        p.y += ctx.h;
    } else if (p.y >= ctx.h) {
        p.y -= ctx.h;
    }
}

/// A small triangle pointing along the boid's velocity.
fn drawBoid(
    gl: anytype,
    pos: Pos,
    vel: Vel,
) void {
    const sp: f32 = @sqrt(vel.x * vel.x + vel.y * vel.y);
    const dx: f32 = if (sp > 0.001) vel.x / sp else 1.0;
    const dy: f32 = if (sp > 0.001) vel.y / sp else 0.0;
    const size: f32 = 6.0;
    const tip: Vec2 = .{ pos.x + dx * size, pos.y + dy * size };
    const bx: f32 = pos.x - dx * size * 0.6;
    const by: f32 = pos.y - dy * size * 0.6;
    const lft: Vec2 = .{ bx - dy * size * 0.5, by + dx * size * 0.5 };
    const rgt: Vec2 = .{ bx + dy * size * 0.5, by - dx * size * 0.5 };
    const col: Color = c.init(120, 190, 245, 255);
    gl.line(tip, lft, .{ .color = col, .thickness = 1.5 });
    gl.line(tip, rgt, .{ .color = col, .thickness = 1.5 });
    gl.line(lft, rgt, .{ .color = col, .thickness = 1.5 });
}

fn update(f: *z.Frame, s: *State) void {
    s.frame_count += 1;
    const dt: f32 = f.time.delta_time;
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();

    // 1. Snapshot every boid's (pos, vel) so steering reads a stable world.
    var n: usize = 0;
    var snap_it = s.es.iterator(struct {
        p: *const Pos,
        v: *const Vel,
    });
    while (snap_it.next(&s.es)) |view| {
        if (n >= s.snap.len) {
            break;
        }
        s.snap[n] = .{ .p = view.p.*, .v = view.v.* };
        n += 1;
    }

    // 2. Steer, 3. integrate + wrap.
    s.es.forEach(steerBoid, SteerCtx{ .snap = s.snap[0..n] });
    s.es.forEach(integrateAndWrap, IntegrateCtx{ .dt = dt, .w = w, .h = h });

    // 4. Render.
    z.clearViewport(f, c.init(8, 10, 16, 255));
    var draw_it = s.es.iterator(struct {
        p: *const Pos,
        v: *const Vel,
    });
    while (draw_it.next(&s.es)) |view| {
        drawBoid(f.gl, view.p.*, view.v.*);
    }
    var buf: [40]u8 = undefined;
    const lbl: []const u8 = bufPrint(&buf, "ECS boids: {d} entities", .{n}) catch "?";
    f.gl.text(.{ 12, 12 }, lbl, .{ .size = 16, .color = c.init(210, 214, 224, 220), .font = &s.font });
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - ECS boids",
            .width = 800,
            .height = 450,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
    .memory = .managed,
};
