//! examples/rt_workers/tracer.zig — the PURE half. A path tracer that is a job kernel.
//!
//! No DOM, no GPU, no globals. It takes a scene and a band of scanlines, and returns those
//! scanlines' pixels. That is the whole contract, and it is why this compiles into a
//! freestanding kernel wasm with ZERO imports that a Web Worker can instantiate with `{}`.
//!
//! It is also why you can `zig build test` it. The tests at the bottom run the real tracer;
//! no browser, no worker, no wasm.
//!
//! WHY A TRACER, and not the PNG encoder or the Mandelbrot:
//!
//!   * The payload is TINY — a handful of spheres, a few hundred bytes — and the result is
//!     one band of pixels. `worker_png` shoves 4 MB in and 2.7 MB out, and the cost of moving
//!     those bytes is what dominated (and hid) its behaviour for weeks. Here the transport is
//!     nothing, so what you see is the POOL rather than the plumbing.
//!   * The cost is real and TUNABLE. `samples` spans "instant" to "please wait", so the same
//!     demo stays honest across the whole range.
//!   * Tiles land as they finish, so progressive display is not a presentation trick bolted
//!     on afterwards — it is what out-of-order completion actually looks like.
const std = @import("std");
const zm = @import("zm");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const float = zm.float;
const dot = zm.dot;
const normalize = zm.normalize;
const clamp = zm.clamp;
const Vec3 = zm.Vec3;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;

/// `extern`: these bytes are memcpy'd out of the app's wasm and into the KERNEL's — two
/// separate compilations — and Zig's auto layout is free to reorder fields across them.
pub const Sphere = extern struct {
    cx: f32,
    cy: f32,
    cz: f32,
    r: f32,
    /// albedo, or emission when `mat == mat_light`
    mr: f32,
    mg: f32,
    mb: f32,
    mat: u32,
};

pub const mat_diffuse: u32 = 0;
pub const mat_metal: u32 = 1;
pub const mat_light: u32 = 2;

/// One unit of work: a horizontal band of the image. The band is the JOB.
///
/// The camera arrives as an EYE plus a precomputed ORTHONORMAL BASIS, not as yaw/pitch. The
/// host does the trigonometry once per render; the kernel does none. Two reasons, and they
/// are both about keeping the kernel dumb:
///
///   * every kernel invocation would otherwise recompute the same sin/cos, per tile, per
///     worker, for a value that cannot change during a render;
///   * a basis is unambiguous. Yaw/pitch needs a convention, and a convention that lives in
///     two places is a convention that will disagree with itself.
pub const Tile = extern struct {
    y0: u32,
    y1: u32,
    w: u32,
    h: u32,
    samples: u32,
    bounces: u32,
    n_spheres: u32,
    seed: u32,

    ex: f32, // eye
    ey: f32,
    ez: f32,
    rx: f32, // right
    ry: f32,
    rz: f32,
    ux: f32, // up
    uy: f32,
    uz: f32,
    fx: f32, // forward (the view direction)
    fy: f32,
    fz: f32,
    focal: f32,
    _pad: f32 = 0,
};

const Hit = struct {
    t: f32,
    p: Vec3,
    n: Vec3,
    albedo: Vec3,
    mat: u32,
};

/// xorshift32. A kernel gets no globals and wants none — the RNG state is a local, seeded
/// from the pixel and the tile, so the same tile renders the same way wherever it runs.
/// (That is not a nicety: it is what lets the test below assert the worker and the main
/// thread agree.)
const Rng = struct {
    s: u32,

    fn next(self: *Rng) u32 {
        var x: u32 = self.s;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.s = x;
        return x;
    }

    /// [0, 1). Named `unit`, not `float`: `zm.float` is a reserved math word and shadowing
    /// it inside a kernel is exactly the kind of quiet confusion the linter exists to stop.
    fn unit(self: *Rng) f32 {
        const bits: u32 = self.next() >> 8; // 24 bits of mantissa
        return float(bits) / 16777216.0;
    }

    fn inUnitSphere(self: *Rng) Vec3 {
        // Rejection sampling, bounded: a kernel must not be able to spin forever on a bad
        // seed. After 8 tries take what we have and normalise — the bias is invisible and
        // the bound is absolute.
        var i: u32 = 0;
        while (i < 8) : (i += 1) {
            const p: Vec3 = .{
                self.unit() * 2.0 - 1.0,
                self.unit() * 2.0 - 1.0,
                self.unit() * 2.0 - 1.0,
            };
            if (dot(p, p) < 1.0) {
                return p;
            }
        }
        const fallback: Vec3 = .{ 0.577, 0.577, 0.577 };
        return normalize(fallback);
    }
};

fn hitSphere(
    s: Sphere,
    ro: Vec3,
    rd: Vec3,
    t_min: f32,
    t_max: f32,
) ?Hit {
    const c: Vec3 = .{ s.cx, s.cy, s.cz };
    const oc: Vec3 = ro - c;
    const a: f32 = dot(rd, rd);
    const half_b: f32 = dot(oc, rd);
    const cc: f32 = dot(oc, oc) - s.r * s.r;
    const disc: f32 = half_b * half_b - a * cc;
    if (disc < 0.0) {
        return null;
    }
    const root: f32 = @sqrt(disc);
    var t: f32 = (-half_b - root) / a;
    if (t < t_min or t > t_max) {
        t = (-half_b + root) / a;
        if (t < t_min or t > t_max) {
            return null;
        }
    }
    const p: Vec3 = ro + rd * @as(Vec3, @splat(t));
    return .{
        .t = t,
        .p = p,
        .n = (p - c) / @as(Vec3, @splat(s.r)),
        .albedo = .{ s.mr, s.mg, s.mb },
        .mat = s.mat,
    };
}

fn hitScene(spheres: []const Sphere, ro: Vec3, rd: Vec3) ?Hit {
    var best: ?Hit = null;
    var closest: f32 = 1e30;
    for (spheres) |s| {
        if (hitSphere(s, ro, rd, 0.001, closest)) |h| {
            closest = h.t;
            best = h;
        }
    }
    return best;
}

/// Iterative, not recursive. A worker's wasm stack is small and a kernel that blows it takes
/// the whole worker with it — and a stack overflow across a postMessage boundary is a
/// miserable thing to debug.
fn radiance(
    spheres: []const Sphere,
    ro_in: Vec3,
    rd_in: Vec3,
    bounces: u32,
    rng: *Rng,
) Vec3 {
    var ro: Vec3 = ro_in;
    var rd: Vec3 = rd_in;
    var throughput: Vec3 = .{ 1.0, 1.0, 1.0 };
    var acc: Vec3 = .{ 0.0, 0.0, 0.0 };

    var depth: u32 = 0;
    while (depth < bounces) : (depth += 1) {
        const h: Hit = hitScene(spheres, ro, rd) orelse {
            // Sky: a soft vertical gradient. The only light besides the emitters.
            const t: f32 = 0.5 * (normalize(rd)[1] + 1.0);
            const white: Vec3 = .{ 1.0, 1.0, 1.0 };
            const blue: Vec3 = .{ 0.35, 0.55, 1.0 };
            const sky: Vec3 = white + (blue - white) * @as(Vec3, @splat(t));
            acc += throughput * sky * @as(Vec3, @splat(0.7));
            break;
        };

        if (h.mat == mat_light) {
            acc += throughput * h.albedo;
            break;
        }

        if (h.mat == mat_metal) {
            const refl: Vec3 = rd - h.n * @as(Vec3, @splat(2.0 * dot(rd, h.n)));
            rd = normalize(refl + rng.inUnitSphere() * @as(Vec3, @splat(0.08)));
        } else {
            rd = normalize(h.n + rng.inUnitSphere());
        }
        ro = h.p;
        throughput *= h.albedo;
    }
    return acc;
}

/// THE KERNEL. An ordinary Zig function: allocator first, header, payload, writer.
///
/// Nothing here says "worker". It runs identically on a Web Worker, on the main thread via
/// the inline fallback, and in a unit test — which is the whole point of the jobs design and
/// the reason the tests below can be trusted.
///
/// `payload` is the sphere array, verbatim. `gpa` is an ARENA the job system releases when
/// the job ends, so there is no `defer free` here and no way to leak.
pub fn traceTile(
    gpa: Allocator,
    hdr: Tile,
    payload: []const u8,
    out: *Writer,
) !void {
    _ = gpa;

    const want: usize = @sizeOf(Sphere) * hdr.n_spheres;
    if (payload.len < want) {
        return error.ShortPayload;
    }
    const spheres: []const Sphere = @alignCast(std.mem.bytesAsSlice(Sphere, payload[0..want]));

    const fw: f32 = float(hdr.w);
    const fh: f32 = float(hdr.h);
    const aspect: f32 = fw / fh;
    const inv_samples: f32 = 1.0 / float(hdr.samples);

    const eye: Vec3 = .{ hdr.ex, hdr.ey, hdr.ez };
    const right: Vec3 = .{ hdr.rx, hdr.ry, hdr.rz };
    const up: Vec3 = .{ hdr.ux, hdr.uy, hdr.uz };
    const fwd: Vec3 = .{ hdr.fx, hdr.fy, hdr.fz };

    var y: u32 = hdr.y0;
    while (y < hdr.y1) : (y += 1) {
        var x: u32 = 0;
        while (x < hdr.w) : (x += 1) {
            // Seeded from the PIXEL, not from a running counter, so a tile's output does not
            // depend on which worker picked it up or what ran before it.
            var rng: Rng = .{ .s = (y *% 1973 +% x *% 9277 +% hdr.seed *% 26699) | 1 };

            var col: Vec3 = .{ 0.0, 0.0, 0.0 };
            var s: u32 = 0;
            while (s < hdr.samples) : (s += 1) {
                const u: f32 = (float(x) + rng.unit()) / fw;
                const v: f32 = (float(y) + rng.unit()) / fh;
                const sx: f32 = (u * 2.0 - 1.0) * aspect;
                const sy: f32 = -(v * 2.0 - 1.0);
                const ray: Vec3 = right * @as(Vec3, @splat(sx)) +
                    up * @as(Vec3, @splat(sy)) +
                    fwd * @as(Vec3, @splat(hdr.focal));
                const dir: Vec3 = normalize(ray);
                col += radiance(spheres, eye, dir, hdr.bounces, &rng);
            }
            col *= @as(Vec3, @splat(inv_samples));

            // gamma 2.0, then to 8-bit.
            const r: u8 = toByte(@sqrt(col[0]));
            const g: u8 = toByte(@sqrt(col[1]));
            const b: u8 = toByte(@sqrt(col[2]));
            try out.writeAll(&[_]u8{ r, g, b, 255 });
        }
    }
}

fn toByte(v: f32) u8 {
    const c: f32 = clamp(v, 0.0, 1.0) * 255.0;
    return @trunc(c);
}

// ---------------------------------------------------------------------------------------
// The kernel is a plain function, so testing it needs no browser, no worker and no wasm.
// This is the ergonomic payoff of the jobs design, and it is worth stating plainly: if you
// can `zig build test` your kernel, the only thing left to break is transport — and
// transport is the engine's problem, not yours.
// ---------------------------------------------------------------------------------------

/// A fixed camera looking down -Z, so the tests exercise the same path the app does.
fn testTile(
    y0: u32,
    y1: u32,
    w: u32,
    h: u32,
    samples: u32,
    bounces: u32,
    seed: u32,
) Tile {
    return .{
        .y0 = y0,
        .y1 = y1,
        .w = w,
        .h = h,
        .samples = samples,
        .bounces = bounces,
        .n_spheres = test_scene.len,
        .seed = seed,
        .ex = 0,
        .ey = 0.55,
        .ez = 2.6,
        .rx = 1,
        .ry = 0,
        .rz = 0,
        .ux = 0,
        .uy = 1,
        .uz = 0,
        .fx = 0,
        .fy = 0,
        .fz = -1,
        .focal = 1.6,
    };
}

const test_scene = [_]Sphere{
    .{ .cx = 0, .cy = -100.5, .cz = -1, .r = 100, .mr = 0.5, .mg = 0.5, .mb = 0.5, .mat = mat_diffuse },
    .{ .cx = 0, .cy = 0, .cz = -1, .r = 0.5, .mr = 0.8, .mg = 0.3, .mb = 0.3, .mat = mat_diffuse },
};

test "traceTile: emits exactly one RGBA pixel per pixel of the band" {
    var buf: [4 * 8 * 3]u8 = undefined;
    var out: Writer = .fixed(&buf);
    const hdr: Tile = testTile(2, 5, 8, 16, 1, 2, 7);
    try traceTile(std.testing.allocator, hdr, std.mem.sliceAsBytes(&test_scene), &out);
    // 3 rows x 8 px x RGBA
    try expectEqual(@as(usize, 3 * 8 * 4), out.buffered().len);
}

test "traceTile: a band is deterministic — same tile, same bytes, wherever it ran" {
    // Load-bearing. A worker and the main thread must agree, or a progressively-drawn image
    // would show seams at the tile boundaries depending on which core got which band.
    const hdr: Tile = testTile(0, 2, 6, 6, 3, 3, 11);
    var a_buf: [2 * 6 * 4]u8 = undefined;
    var b_buf: [2 * 6 * 4]u8 = undefined;
    var a: Writer = .fixed(&a_buf);
    var b: Writer = .fixed(&b_buf);
    try traceTile(std.testing.allocator, hdr, std.mem.sliceAsBytes(&test_scene), &a);
    try traceTile(std.testing.allocator, hdr, std.mem.sliceAsBytes(&test_scene), &b);
    try expectEqualSlices(u8, a.buffered(), b.buffered());
}

test "traceTile: a short payload is an error, not a read past the end" {
    var buf: [4 * 4 * 4]u8 = undefined;
    var out: Writer = .fixed(&buf);
    var hdr: Tile = testTile(0, 1, 4, 4, 1, 1, 1);
    hdr.n_spheres = 9; // claims nine spheres...
    // ...but hands over two. The kernel runs in a worker with its own linear memory; a
    // trusting `bytesAsSlice` here would read whatever happens to follow.
    try expectError(
        error.ShortPayload,
        traceTile(std.testing.allocator, hdr, std.mem.sliceAsBytes(&test_scene), &out),
    );
}
