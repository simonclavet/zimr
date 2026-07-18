//! simple_particles — a three-type particle emitter ported to WebGPU. A ring
//! buffer of particles is emitted from a centre emitter; the active type cycles every
//! few seconds: water (blue, falls under gravity), smoke (grey, rises, grows, fades),
//! and fire (yellow→red, rises with a flicker wobble, shrinks). The GL original let you
//! drag the emitter with the mouse; this runs itself. Viewport-relative under
//! `.responsive`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Vec2 = zm.Vec2;
const Color = zm.Color;
const float = zm.float;
const pi = zm.pi;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
const c = Color;

const max_particles: usize = 1600;
const emit_per_frame: usize = 5;
const cycle_frames: usize = 200; // switch active type on this cadence

const ParticleType = enum(u8) { water, smoke, fire };

const Particle = struct {
    ptype: ParticleType = .water,
    pos: Vec2 = .{ 0, 0 },
    vel: Vec2 = .{ 0, 0 },
    radius: f32 = 0,
    color: Color = c.white,
    alive: bool = false,
};

const State = struct {
    font: z.Font,
    particles: []Particle,
    head: usize = 0,
    tail: usize = 0,
    rng: std.Random.DefaultPrng,
    frame_count: usize = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    _ = gpa;
    _ = s;
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24);
    const particles: []Particle = try gpa.alloc(Particle, max_particles);
    for (particles) |*p| {
        p.* = .{};
    }
    s.* = .{
        .font = font,
        .particles = particles,
        .rng = std.Random.DefaultPrng.init(0x9a7d_1c3e),
    };
}

fn emit(
    s: *State,
    ptype: ParticleType,
    emitter: Vec2,
) void {
    const next: usize = (s.head + 1) % max_particles;
    if (next == s.tail) {
        return; // buffer full
    }
    const rand: std.Random = s.rng.random();
    const speed: f32 = rand.float(f32) * 1.8;
    const dir: f32 = rand.float(f32) * 2.0 * pi;
    const eff: f32 = if (ptype == .fire) speed / 10.0 else speed;
    var p: Particle = .{ .ptype = ptype, .pos = emitter, .alive = true };
    p.vel = .{ eff * @cos(dir), eff * @sin(dir) };
    switch (ptype) {
        .water => {
            p.radius = 5.0;
            p.color = c.init(60, 130, 235, 255);
        },
        .smoke => {
            p.radius = 7.0;
            p.color = c.init(150, 150, 150, 255);
        },
        .fire => {
            p.radius = 10.0;
            p.color = c.init(255, 230, 60, 255);
        },
    }
    s.particles[s.head] = p;
    s.head = next;
}

fn tickParticles(
    s: *State,
    w: f32,
    h: f32,
) void {
    var i: usize = s.tail;
    while (i != s.head) : (i = (i + 1) % max_particles) {
        const p: *Particle = &s.particles[i];
        if (!p.alive) {
            continue;
        }
        switch (p.ptype) {
            .water => {
                p.vel[1] += 0.2;
                p.pos += p.vel;
            },
            .smoke => {
                p.vel[1] -= 0.05;
                p.pos += p.vel;
                p.radius += 0.5;
                p.color.a = if (p.color.a >= 4) p.color.a - 4 else 0;
                if (p.color.a < 4) {
                    p.alive = false;
                }
            },
            .fire => {
                p.pos[0] += p.vel[0] + @cos(float(s.frame_count) * 0.21);
                p.vel[1] -= 0.05;
                p.pos[1] += p.vel[1];
                p.radius -= 0.15;
                p.color.g = if (p.color.g >= 3) p.color.g - 3 else 0;
                if (p.radius <= 0.02) {
                    p.alive = false;
                }
            },
        }
        if (p.pos[0] < -p.radius or p.pos[0] > w + p.radius or
            p.pos[1] < -p.radius or p.pos[1] > h + p.radius)
        {
            p.alive = false;
        }
    }
    // Retire leading dead slots so alive particles stay contiguous.
    while (s.tail != s.head and !s.particles[s.tail].alive) {
        s.tail = (s.tail + 1) % max_particles;
    }
}

fn update(f: *z.Frame, s: *State) void {
    s.frame_count += 1;
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    const ptype: ParticleType = @enumFromInt(@as(u8, @intCast((s.frame_count / cycle_frames) % 3)));
    const emitter: Vec2 = .{ w * 0.5, h * 0.5 };

    var e: usize = 0;
    while (e < emit_per_frame) : (e += 1) {
        emit(s, ptype, emitter);
    }
    tickParticles(s, w, h);

    z.clearViewport(f, c.init(8, 9, 14, 255));
    var i: usize = s.tail;
    while (i != s.head) : (i = (i + 1) % max_particles) {
        const p: Particle = s.particles[i];
        if (p.alive and p.radius > 0.1) {
            f.gl.circle(p.pos, p.radius, .{ .color = p.color, .segments = 16 });
        }
    }
    const label: []const u8 = switch (ptype) {
        .water => "particles: water (gravity)",
        .smoke => "particles: smoke (rises + fades)",
        .fire => "particles: fire (flicker)",
    };
    f.gl.text(.{ 12, 12 }, label, .{ .size = 16, .color = c.init(210, 214, 224, 220), .font = &s.font });
    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - particles",
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
