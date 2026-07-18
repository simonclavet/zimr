//! particle_step.zig — one compute kernel: advance a particle under gravity and
//! bounce it off the unit-box walls. Pure GATHER (each id writes only its own
//! pos/vel), so it's identical on CPU and GPU and trivially parallel. Positions
//! live in [0,1]^2; the host maps them to the screen. Written once in the kompute
//! DSL; `z.Compute(@This())` runs it on either backend.
const k = @import("kompute");
const zm = @import("zm");
const Vec2 = zm.Vec2;
const splat2 = zm.splat2;

pub const config = k.Config{ .max = 8192, .workgroup = 64 };

// Plain struct (not extern): Zig 1245 bans @Vector fields in extern structs on
// CPU. The GPU binds each field by name via @extern on the SPIR-V target; the
// CPU twin just needs the Vec2 arrays. Per-field binding means struct layout is
// never used for the GPU buffers, so dropping `extern` changes nothing.
pub const Buffers = struct {
    pos: [config.max]Vec2,
    vel: [config.max]Vec2,
};

// 16-byte uniform: u32 + 3×f32 (scalar fields — an array pad would break the
// uniform layout; see the gpu-compute tutorial).
pub const Params = extern struct {
    count: u32,
    dt: f32,
    gravity: f32,
    damping: f32,
};

pub const g = k.Globals(@This());
const b_pos = g.bind(.pos);
const b_vel = g.bind(.vel);

pub fn particleStep(c: k.Ctx(@This())) void {
    if (c.id >= c.params.count) {
        return;
    }
    const id: u32 = c.id;
    var v: Vec2 = b_vel[id];
    v[1] = v[1] + c.params.gravity * c.params.dt; // gravity pulls +y (down on screen)
    var p: Vec2 = b_pos[id] + v * splat2(c.params.dt);

    // Bounce off the unit box, losing energy by `damping`.
    if (p[0] < 0.0) {
        p[0] = 0.0;
        v[0] = -v[0] * c.params.damping;
    }
    if (p[0] > 1.0) {
        p[0] = 1.0;
        v[0] = -v[0] * c.params.damping;
    }
    if (p[1] < 0.0) {
        p[1] = 0.0;
        v[1] = -v[1] * c.params.damping;
    }
    if (p[1] > 1.0) {
        p[1] = 1.0;
        v[1] = -v[1] * c.params.damping;
    }

    b_pos[id] = p;
    b_vel[id] = v;
}

comptime {
    k.installKernel(@This(), "particleStep");
}
