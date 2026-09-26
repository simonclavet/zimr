// examples/raytracer.zig - single-file CPU path tracer.
// A real-time, interactive Whitted-style path tracer.  Five sphere
// primitives plus a giant ground sphere, three material types
// (lambertian / metal / dielectric), one progressively-accumulated
// float framebuffer, one upload-each-frame pixel texture.
// Inspiration: Peter Shirley's "Ray Tracing in One Weekend", with
// the f64/multithread/PPM-output trio swapped for zimr's f32 +
// single-thread-wasm + live-screen-pixel-buffer story.
// Three runtime modes:
//   - **Moving** - any movement input is active.  Render at 1/4
//     resolution (stride 4) with one sample per pixel.  ~8K rays per
//     frame, sub-millisecond.  Image is noisy and pixelated;
//     motion masks both.
//   - **Still, converging** - no input for >0 frames; accumulator is
//     summing one fresh sample per pixel per frame.  Image refines
//     over ~5 seconds.
//   - **Still, converged** - accumulator hit the cap; rendering
//     pauses, the buffer just keeps re-uploading the same pixels.
//     Zero ray work, ~free.
// Controls:
//   - W / S         translate along the camera forward / back axis
//   - A / D         translate left / right
//   - Q / E         translate down / up
//   - RMB-drag      yaw / pitch
//   - Shift         4x movement speed
//   - Mouse wheel   nudge vertical FOV (zoom)
// All other tuning lives in the ImGui panel.
// What's exercised on the zimr side:
//   - `entities.zig` (one archetype, two components, ~7 entities)
//   - `zimrmath.zig` random-vector helpers + reflect/refract
//   - `ui` panel with sliders, combo, color picker, buttons
//   - `gpu.updateTexture` for streaming a CPU framebuffer
//   - `drawTextureRotated` to scale the small-res buffer to canvas
//   - `f.input` (keyboard + mouse + wheel)
// What's NOT done:
//   - No multithreading (wasm32, single-threaded)
//   - No BVH (linear sphere iteration; fine for ~10 spheres)
//   - No textures, area lights, or volumetrics

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const clamp = zm.clamp;
const cross = zm.cross;
const dot3 = zm.dot3;
const float = zm.float;
const inf = zm.inf;
const int = zm.int;
const lengthSq3 = zm.lengthSq3;
const normalize3 = zm.normalize3;
const pi = zm.pi;
const pow = zm.pow;
const reflect3 = zm.reflect3;
const refract3 = zm.refract3;
const splat = zm.splat;
const vec = zm.vec;
const ecs = z.ecs;
const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const Color = zm.Color;

/// Random unit vector by rejection sampling - replaces the old
/// `zimrmath.vector3RandomUnitVector` (the zimrmath compute surface
/// was deleted in Z4).  Uses the same algorithm: sample a cube,
/// reject points outside the unit ball, normalize what survives.
fn randomUnitVec3(rng: std.Random) zm.Vec {
    while (true) {
        const v = vec(
            rng.float(f32) * 2 - 1,
            rng.float(f32) * 2 - 1,
            rng.float(f32) * 2 - 1,
        );
        const len_sq: f32 = lengthSq3(v);
        if (len_sq > 1.0e-10 and len_sq <= 1.0) {
            return normalize3(v);
        }
    }
}

// ============================================================================
// Constants
// ============================================================================

const screen_w: i32 = 800;
const screen_h: i32 = 450;

/// Internal render resolution.  The framebuffer is this many pixels;
/// `drawTextureRotated` stretches the result to fill the canvas.  16:9
/// quarter-of-1080p - a sweet spot for "image still looks like an
/// image" at single-thread f32.
const rt_w: i32 = 480;
const rt_h: i32 = 270;
const rt_px_count: usize = @intCast(rt_w * rt_h);

/// Stride used when moving - every Nth pixel is rendered, the rest
/// inherit their last-frame color (since we never overwrite them
/// during a moving frame).
const move_stride: i32 = 4;

// ============================================================================
// Components (one entity per scene object)
// ============================================================================

const Sphere = struct {
    center: Vec,
    radius: f32,
};

const Lambertian = struct { albedo: Vec };

const Metal = struct { albedo: Vec, fuzz: f32 };

const Dielectric = struct { ref_idx: f32 };

const Material = union(enum) {
    lambertian: Lambertian,
    metal: Metal,
    dielectric: Dielectric,
};

// ============================================================================
// Ray + HitRecord (plain data passed through trace recursion)
// ============================================================================

const Ray = zm.Ray;
fn rayAt(self: Ray, t: f32) Vec {
    return (self.position + (self.direction * splat(t)));
}

const HitRecord = struct {
    point: Vec,
    normal: Vec,
    t: f32,
    front_face: bool,
    material: Material,
};

// ============================================================================
// Camera - pose + derived viewport basis
// ============================================================================

/// Camera pose is `(lookfrom, yaw, pitch, vfov)`; the rest of the
/// viewport math (`px00`, `pdu`, `pdv`, `u`, `v`, `w`) is recomputed
/// each frame from these four fields.  Cheap to redo (~30 FLOPs);
/// keeps "did the camera move?" trivially detectable.
const Camera = struct {
    lookfrom: Vec,
    yaw: f32, // radians, around world +Y
    pitch: f32, // radians, clamped to +/-~80 deg
    vfov: f32, // degrees, vertical
};

/// Derived per-frame camera basis + viewport plane.
const CamBasis = struct {
    origin: Vec,
    u: Vec, // viewport right
    v: Vec, // viewport down (note: negated relative to world up)
    w: Vec, // camera forward (points behind the camera, raylib style)
    px00: Vec, // center of the top-left pixel
    pdu: Vec, // one-pixel right
    pdv: Vec, // one-pixel down
};

fn deriveBasis(cam: Camera) CamBasis {
    // Forward direction from (yaw, pitch).  Yaw rotates around +Y,
    // pitch tilts up/down.  At yaw=0, the camera looks toward -Z.
    const cp: f32 = @cos(cam.pitch);
    const sp: f32 = @sin(cam.pitch);
    const cy: f32 = @cos(cam.yaw);
    const sy: f32 = @sin(cam.yaw);

    const forward: Vec = vec(-cp * sy, sp, -cp * cy);
    const w: zm.Vec = normalize3((-(forward)));
    const world_up: Vec = vec(0, 1, 0);
    const u: zm.Vec = normalize3(cross(world_up, w));
    const v: zm.Vec = cross(w, u);

    // Viewport size in world units.  `focus_dist = 1.0` (no depth-
    // of-field) keeps the math straightforward.
    const focus_dist: f32 = 1.0;
    const theta: f32 = cam.vfov * pi / 180.0;
    const half_h: f32 = @tan(theta / 2.0) * focus_dist;
    const half_w: f32 = half_h * (float(rt_w) / float(rt_h));

    const viewport_u: zm.Vec = (u * splat(2.0 * half_w));
    const viewport_v: zm.Vec = (v * splat(-2.0 * half_h));
    const pdu: zm.Vec = (viewport_u * splat(1.0 / float(rt_w)));
    const pdv: zm.Vec = (viewport_v * splat(1.0 / float(rt_h)));

    // Top-left corner of the viewport, then nudge by half a pixel
    // to sit at the center of pixel (0, 0).
    const upper_left: zm.Vec =
        cam.lookfrom - (w * splat(focus_dist)) - (viewport_u * splat(0.5)) - (viewport_v * splat(0.5));
    const px00: zm.Vec = upper_left + (pdu * splat(0.5)) + (pdv * splat(0.5));

    return .{
        .origin = cam.lookfrom,
        .u = u,
        .v = v,
        .w = w,
        .px00 = px00,
        .pdu = pdu,
        .pdv = pdv,
    };
}

// ============================================================================
// UI-tunable params
// ============================================================================

const SkyPreset = enum(i32) { day, sunset, night };

const Params = struct {
    samples_per_pixel: i32 = 64, // cap on accumulated samples per pixel
    max_depth: i32 = 5, // recursion cap
    vfov: f32 = 50.0,
    sky_preset: i32 = @backingInt(SkyPreset.day),
};

// ============================================================================
// State
// ============================================================================

const State = struct {
    // -- ECS ---------------------------
    world: ecs.Registry,

    // -- Camera + params -----------------------
    cam: Camera,
    params: Params = .{},

    // -- Framebuffers ------------------------
    /// Float HDR accumulator - sum of all samples drawn into each
    /// pixel since the last camera move.  Divided by `sample_count`
    /// at tonemap time to produce the displayed color.
    accum: []Vec,
    /// Per-pixel sample count.  Stays in lock-step with `accum`.
    sample_count: u32 = 0,
    /// LDR display buffer - what gets uploaded to the GPU texture.
    /// Owned by `accum_image`; pointer alias kept here for clarity.
    pixels: []Color,

    // -- GPU resources ------------------------
    fb: z.CpuFramebuffer,

    // -- Input bookkeeping ----------------------
    /// Did anything move during the last frame?  Drives stride
    /// (full-res when false, 1/4-res when true) and accum-reset
    /// (reset when transitioning false->true).
    moving: bool = false,

    // -- UI + scratch ------------------------
    rng: std.Random.DefaultPrng,
    gpa: Allocator,
};

// ============================================================================
// Main entry point
// ============================================================================

fn deinit(gpa: Allocator, s: *State) void {
    s.fb.deinit();
    s.world.deinit(gpa);
    gpa.free(s.accum);
    gpa.free(s.pixels);
}

// ============================================================================
// Init
// ============================================================================

fn spawnSphere(
    gpa: Allocator,
    world: *ecs.Registry,
    center: Vec,
    radius: f32,
    mat: Material,
) !void {
    const e: ecs.Entity = try ecs.Entity.reserveImmediateOrErr(world);
    _ = try e.changeArchImmediateOrErr(world, gpa, struct {
        sphere: Sphere,
        material: Material,
    }, .{ .add = .{
        .sphere = .{ .center = center, .radius = radius },
        .material = mat,
    } });
}

/// Spawn the opening scene: ground + 3 feature spheres + 3 small
/// accents.  All hard-coded; the user can add/remove via the UI.
fn spawnDefaultScene(gpa: Allocator, world: *ecs.Registry) !void {
    // Ground (giant green-grey sphere - looks like a plane from
    // anywhere near the origin).
    try spawnSphere(gpa, world, vec(0, -100.5, -1), 100, .{
        .lambertian = .{ .albedo = vec(0.5, 0.55, 0.45) },
    });
    // Center sphere - matte teal.
    try spawnSphere(gpa, world, vec(0, 0, -1.2), 0.5, .{
        .lambertian = .{ .albedo = vec(0.15, 0.45, 0.55) },
    });
    // Left sphere - clear glass (dielectric).  The "bubble" trick
    // from RTiOW: an outer sphere with ri=1.5 plus a slightly-
    // smaller negative-radius (inverted normals) sphere with
    // ri=1/1.5 inside it produces a hollow-sphere look.
    try spawnSphere(gpa, world, vec(-1.0, 0, -1), 0.5, .{
        .dielectric = .{ .ref_idx = 1.5 },
    });
    try spawnSphere(gpa, world, vec(-1.0, 0, -1), 0.4, .{
        .dielectric = .{ .ref_idx = 1.0 / 1.5 },
    });
    // Right sphere - brushed gold (metal with some fuzz).
    try spawnSphere(gpa, world, vec(1.0, 0, -1), 0.5, .{
        .metal = .{ .albedo = vec(0.8, 0.6, 0.2), .fuzz = 0.25 },
    });
    // Three small accents - different positions + materials, spread
    // out in front to give the camera something to look around at.
    try spawnSphere(gpa, world, vec(-0.3, -0.35, -0.5), 0.15, .{
        .metal = .{ .albedo = vec(0.75, 0.75, 0.85), .fuzz = 0.0 },
    });
    try spawnSphere(gpa, world, vec(0.4, -0.4, -0.4), 0.1, .{
        .lambertian = .{ .albedo = vec(0.85, 0.3, 0.3) },
    });
    try spawnSphere(gpa, world, vec(0.65, -0.42, -1.5), 0.08, .{
        .lambertian = .{ .albedo = vec(0.95, 0.85, 0.2) },
    });
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    // ECS world for scene objects.  Tiny - a handful of entities,
    // one archetype.  Capacity headroom for ~50 spawn-via-UI clicks.
    var world: ecs.Registry = try .init(.{
        .gpa = gpa,
        .cap = .{ .entities = 64, .arches = 4, .chunks = 4, .chunk = 4096 },
    });
    errdefer world.deinit(gpa);

    try spawnDefaultScene(gpa, &world);

    // Allocate the float accumulator + LDR display buffers.
    const accum = try gpa.alloc(Vec, rt_px_count);
    @memset(accum, vec(0, 0, 0));
    const pixels = try gpa.alloc(Color, rt_px_count);
    @memset(pixels, .{ .r = 0, .g = 0, .b = 0, .a = 255 });

    // Wrap the LDR buffer in an `Image` so we can upload it through
    // the standard `loadFromImage` -> `updateTexture` pipeline.

    // GPU texture world (Phase E pattern - same shape as
    // procgen_noise).  Just holds the one streaming texture.
    const fb: z.CpuFramebuffer = z.CpuFramebuffer.init(
        f.gpu.device,
        f.gpu.queue,
        @intCast(rt_w),
        @intCast(rt_h),
        std.mem.sliceAsBytes(pixels),
        "raytracer_fb",
    );

    s.* = .{
        .world = world,
        .cam = .{
            .lookfrom = vec(0, 0.5, 2.0),
            .yaw = 0,
            .pitch = -0.15, // small tilt down, so the ground is visible
            .vfov = 50,
        },
        .accum = accum,
        .pixels = pixels,
        .fb = fb,
        .rng = std.Random.DefaultPrng.init(0xCAFE),
        .gpa = gpa,
    };
}

// ============================================================================
// Per-frame update
// ============================================================================

fn drawUiPanel(f: *z.Frame, s: *State) bool {
    _ = f;
    _ = s;
    return false; // UI panel omitted in the wgpu CPU port (no z.Ui yet)
}

/// Read input.  Returns true if any camera-related state changed
/// this frame (which triggers the accumulator reset + low-res
/// render path).
fn handleInput(
    f: *z.Frame,
    s: *State,
    ui_capture_mouse: bool,
) bool {
    var changed: bool = false;
    const dt: f32 = f.time.delta_time;

    // Movement speed: 1.5 world-units/sec normally, 6 with Shift.
    const speed_mul: f32 = if (z.isKeyDown(f.input, .left_shift)) 4.0 else 1.0;
    const speed: f32 = 1.5 * speed_mul * dt;

    const basis: CamBasis = deriveBasis(s.cam);

    // WASDQE - translate along the camera basis.
    if (z.isKeyDown(f.input, .w)) {
        s.cam.lookfrom = (s.cam.lookfrom - (basis.w * splat(speed)));
        changed = true;
    }
    if (z.isKeyDown(f.input, .s)) {
        s.cam.lookfrom = (s.cam.lookfrom + (basis.w * splat(speed)));
        changed = true;
    }
    if (z.isKeyDown(f.input, .a)) {
        s.cam.lookfrom = (s.cam.lookfrom - (basis.u * splat(speed)));
        changed = true;
    }
    if (z.isKeyDown(f.input, .d)) {
        s.cam.lookfrom = (s.cam.lookfrom + (basis.u * splat(speed)));
        changed = true;
    }
    if (z.isKeyDown(f.input, .q)) {
        s.cam.lookfrom = (s.cam.lookfrom - (basis.v * splat(speed)));
        changed = true;
    }
    if (z.isKeyDown(f.input, .e)) {
        s.cam.lookfrom = (s.cam.lookfrom + (basis.v * splat(speed)));
        changed = true;
    }

    // RMB-drag: yaw / pitch.  Gated on `ui_capture_mouse` so the
    // UI panel stays clickable.
    if (!ui_capture_mouse and z.isMouseButtonDown(f.input, .right)) {
        const delta: Vec2 = z.getMouseDelta(f.input);
        if (delta[0] != 0 or delta[1] != 0) {
            const sensitivity: f32 = 0.005;
            s.cam.yaw += delta[0] * sensitivity;
            s.cam.pitch -= delta[1] * sensitivity;
            // Clamp pitch so the camera can't flip past straight-up
            // or straight-down (would gimbal-lock the yaw axis).
            const pitch_cap: f32 = 1.4; // ~80 deg
            s.cam.pitch = clamp(s.cam.pitch, -pitch_cap, pitch_cap);
            changed = true;
        }
    }

    // Wheel: zoom by nudging vfov.
    const wheel: f32 = z.getMouseWheelMove(f.input);
    if (wheel != 0 and !ui_capture_mouse) {
        s.cam.vfov = clamp(s.cam.vfov - wheel * 2.0, 10.0, 90.0);
        changed = true;
    }

    return changed;
}

/// Build the ray for pixel (x, y), with a tiny anti-alias jitter so
/// successive samples for the same pixel sit at slightly different
/// sub-pixel positions - the convergence path.
fn pixelRay(
    rng: std.Random,
    basis: *const CamBasis,
    x: i32,
    y: i32,
) Ray {
    const jx: f32 = rng.float(f32) - 0.5;
    const jy: f32 = rng.float(f32) - 0.5;
    const fx: f32 = float(x) + jx;
    const fy: f32 = float(y) + jy;
    const px_center: zm.Vec = basis.px00 + (basis.pdu * splat(fx)) + (basis.pdv * splat(fy));
    return .{
        .position = basis.origin,
        .direction = (px_center - basis.origin),
    };
}

/// Analytic ray-sphere intersection.  Solves the quadratic
/// `|O + tD - C|^2 = r^2` for `t`.  Returns the nearest root in
/// `(t_min, t_max)` or null.
fn hitSphere(
    s: Sphere,
    mat: Material,
    ray: Ray,
    t_min: f32,
    t_max: f32,
) ?HitRecord {
    const oc: zm.Vec = (s.center - ray.position);
    const a: f32 = dot3(ray.direction, ray.direction);
    const h: f32 = dot3(oc, ray.direction);
    const c: f32 = dot3(oc, oc) - s.radius * s.radius;
    const disc: f32 = h * h - a * c;
    if (disc < 0) {
        return null;
    }
    const sqrt_d: f32 = @sqrt(disc);

    // Try the nearer root first; fall back to the further one if
    // the nearer is outside the interval.  (This handles cases like
    // "ray origin is inside the sphere".)
    var root: f32 = (h - sqrt_d) / a;
    if (root <= t_min or root >= t_max) {
        root = (h + sqrt_d) / a;
        if (root <= t_min or root >= t_max) {
            return null;
        }
    }

    const point: zm.Vec = rayAt(ray, root);
    const outward_normal: zm.Vec = ((point - s.center) * splat(1.0 / s.radius));
    const front_face: bool = dot3(ray.direction, outward_normal) < 0;
    return .{
        .point = point,
        .normal = if (front_face) outward_normal else (-(outward_normal)),
        .t = root,
        .front_face = front_face,
        .material = mat,
    };
}

/// Iterate every (Sphere, Material) entity, return the nearest hit
/// in the [t_min, t_max] interval (or null).
fn hitScene(
    ray: Ray,
    world: *const ecs.Registry,
    t_min: f32,
    t_max: f32,
) ?HitRecord {
    var closest: ?HitRecord = null;
    var closest_t: f32 = t_max;

    // Cast away const for iteration (ecs requires *World).  No
    // component mutation happens - we only read.
    const w_mut: *ecs.Registry = @constCast(world);
    var iter = w_mut.iterator(struct { s: *const Sphere, m: *const Material });
    while (iter.next(w_mut)) |view| {
        if (hitSphere(view.s.*, view.m.*, ray, t_min, closest_t)) |rec| {
            closest = rec;
            closest_t = rec.t;
        }
    }
    return closest;
}

const Scatter = struct {
    attenuation: Vec,
    scattered: Ray,
};

/// Diffuse: scatter in a random direction biased toward the normal.
/// `normal + randomUnitVector` is the "true Lambertian" distribution
/// (cosine-weighted) - gives the soft, even-illumination look.
fn scatterLambertian(
    rng: std.Random,
    m: Lambertian,
    rec: HitRecord,
) ?Scatter {
    var dir: zm.Vec = (rec.normal + randomUnitVec3(rng));
    // Guard against the degenerate case where the random vector
    // cancels the normal (would produce a zero-length ray direction).
    if (lengthSq3(dir) < 1.0e-8) {
        dir = rec.normal;
    }
    return .{
        .attenuation = m.albedo,
        .scattered = .{ .position = rec.point, .direction = dir },
    };
}

/// Specular reflection plus optional fuzz.  Fuzz=0 is a perfect
/// mirror; higher fuzz scatters the reflection inside a sphere
/// around the ideal direction, producing brushed-metal blur.
fn scatterMetal(
    rng: std.Random,
    m: Metal,
    ray_in: Ray,
    rec: HitRecord,
) ?Scatter {
    const reflected: zm.Vec = reflect3(normalize3(ray_in.direction), rec.normal);
    const fuzzy: zm.Vec = (reflected + (randomUnitVec3(rng) * splat(m.fuzz)));
    // If the fuzz scatter pushes the ray below the surface, drop
    // the bounce - would otherwise produce darkened pixels at
    // grazing angles.
    if (dot3(fuzzy, rec.normal) <= 0) {
        return null;
    }
    return .{
        .attenuation = m.albedo,
        .scattered = .{ .position = rec.point, .direction = fuzzy },
    };
}

/// Schlick's approximation for the Fresnel reflectance - gives the
/// "edges of glass reflect more than the middle" effect cheaply.
fn schlick(cos_theta: f32, ref_idx: f32) f32 {
    var r0: f32 = (1.0 - ref_idx) / (1.0 + ref_idx);
    r0 = r0 * r0;
    return r0 + (1.0 - r0) * pow(1.0 - cos_theta, 5);
}

/// Glass: refract (Snell's law) unless total internal reflection or
/// the Schlick approximation says "reflect this one anyway."  No
/// attenuation - glass passes color through unchanged.
fn scatterDielectric(
    rng: std.Random,
    m: Dielectric,
    ray_in: Ray,
    rec: HitRecord,
) ?Scatter {
    const ri: f32 = if (rec.front_face) 1.0 / m.ref_idx else m.ref_idx;
    const unit_dir: zm.Vec = normalize3(ray_in.direction);
    const cos_theta: f32 = @min(dot3((-(unit_dir)), rec.normal), 1.0);
    const sin_theta: f32 = @sqrt(1.0 - cos_theta * cos_theta);

    const cannot_refract: bool = ri * sin_theta > 1.0;
    const reflect_prob: f32 = schlick(cos_theta, ri);
    const must_reflect = cannot_refract or reflect_prob > rng.float(f32);

    const dir: Vec = if (must_reflect)
        reflect3(unit_dir, rec.normal)
    else
        refract3(unit_dir, rec.normal, ri);

    return .{
        .attenuation = vec(1, 1, 1),
        .scattered = .{ .position = rec.point, .direction = dir },
    };
}

fn scatter(
    rng: std.Random,
    ray_in: Ray,
    rec: HitRecord,
) ?Scatter {
    return switch (rec.material) {
        .lambertian => |m| scatterLambertian(rng, m, rec),
        .metal => |m| scatterMetal(rng, m, ray_in, rec),
        .dielectric => |m| scatterDielectric(rng, m, ray_in, rec),
    };
}

fn skyColor(dir: Vec, preset_idx: i32) Vec {
    const unit: zm.Vec = normalize3(dir);
    const a: f32 = 0.5 * (unit[1] + 1.0);
    const preset: SkyPreset = @fromBackingInt(@intCast(preset_idx));
    const colors: [2]zm.Vec = switch (preset) {
        .day => .{
            vec(1.0, 1.0, 1.0), // horizon - bright white
            vec(0.5, 0.7, 1.0), // zenith - sky blue
        },
        .sunset => .{
            vec(1.0, 0.55, 0.35), // horizon - orange
            vec(0.25, 0.15, 0.45), // zenith - purple
        },
        .night => .{
            vec(0.05, 0.06, 0.12), // horizon - dim navy
            vec(0.01, 0.01, 0.03), // zenith - near-black
        },
    };
    return ((colors[0] * splat(1.0 - a)) + (colors[1] * splat(a)));
}

/// Recursive ray color.  Hits -> scatter recursively x albedo.  Miss
/// -> sky.  Depth -> black (energy budget exhausted).
fn rayColor(
    rng: std.Random,
    ray: Ray,
    world: *const ecs.Registry,
    params: Params,
    depth: u32,
) Vec {
    if (depth == 0) {
        return vec(0, 0, 0);
    }

    if (hitScene(ray, world, 0.001, inf(f32))) |rec| {
        if (scatter(rng, ray, rec)) |scat| {
            const sub: zm.Vec = rayColor(rng, scat.scattered, world, params, depth - 1);
            return (scat.attenuation * sub);
        }
        return vec(0, 0, 0);
    }

    return skyColor(ray.direction, params.sky_preset);
}

fn clamp8(v: f32) u8 {
    return int(u8, clamp(v, 0, 0.999) * 256.0);
}

/// Linear HDR -> sRGB-ish 8-bit color.  `sqrt` is the cheap stand-in
/// for gamma 2.0 (the proper sRGB curve is barely different
/// visually and costlier per pixel).
fn tonemap(c: Vec) Color {
    return .{
        .r = clamp8(@sqrt(@max(0, c[0]))),
        .g = clamp8(@sqrt(@max(0, c[1]))),
        .b = clamp8(@sqrt(@max(0, c[2]))),
        .a = 255,
    };
}

/// Low-resolution single-sample stride render.  Renders every
/// `move_stride`-th pixel; the other pixels keep their last-frame
/// color.  Runs while the camera is moving - the framebuffer was
/// just reset to zero in the caller, so the un-stride pixels read
/// as zero (black).  To compensate, we fill an entire stridexstride
/// block from each rendered sample so the image looks coherent
/// instead of like a polka-dot pattern.
fn renderStride(s: *State, basis: *const CamBasis) void {
    const rng: std.Random = s.rng.random();
    var y: i32 = 0;
    while (y < rt_h) : (y += move_stride) {
        var x: i32 = 0;
        while (x < rt_w) : (x += move_stride) {
            const ray: Ray = pixelRay(rng, basis, x, y);
            // Shallower depth while moving (cap at 3) - the extra
            // bounces are invisible in motion + halve the per-ray
            // work.
            const depth: u32 = @min(3, @as(u32, @intCast(s.params.max_depth)));
            const color: Vec = rayColor(rng, ray, &s.world, s.params, depth);
            const display: Color = tonemap(color);
            // Splat this color across the move_stride x move_stride
            // pixel block.
            var dy: i32 = 0;
            while (dy < move_stride and (y + dy) < rt_h) : (dy += 1) {
                var dx: i32 = 0;
                while (dx < move_stride and (x + dx) < rt_w) : (dx += 1) {
                    const idx: usize = @intCast((y + dy) * rt_w + (x + dx));
                    s.pixels[idx] = display;
                }
            }
        }
    }
}

/// Full-resolution single-sample-per-frame accumulator render.  Adds
/// one fresh sample to each pixel; caller divides by `sample_count`
/// at tonemap time.  Runs while the camera is still.
fn renderOneSample(s: *State, basis: *const CamBasis) void {
    const rng: std.Random = s.rng.random();
    var y: i32 = 0;
    while (y < rt_h) : (y += 1) {
        var x: i32 = 0;
        while (x < rt_w) : (x += 1) {
            const idx: usize = @intCast(y * rt_w + x);
            const ray: Ray = pixelRay(rng, basis, x, y);
            const sample: Vec = rayColor(rng, ray, &s.world, s.params, @intCast(s.params.max_depth));
            s.accum[idx] = (s.accum[idx] + sample);
        }
    }
    // Tonemap the whole buffer for display.
    const denom: f32 = 1.0 / float(s.sample_count + 1);
    for (s.accum, 0..) |c, i| {
        s.pixels[i] = tonemap((c * splat(denom)));
    }
}

fn update(f: *z.Frame, s: *State) void {
    // Per-frame order of operations:
    //   1. Submit the UI panel first.  This populates the context's
    //      `frame_windows` list (used by `wantCaptureMouse`), so by
    //      the time we read input below the hit-test against the
    //      panel rect is correct.  The UI's draw calls go into the
    //      same render batch as everything else and only flush at
    //      `endDrawing` - there's no "render UI first" cost.
    //   2. Read input + maybe-update camera.
    //   3. Render the scene + upload pixels.
    //   4. Issue draw calls (clear -> texture -> UI commands -> flush).
    const ui_capture_mouse: bool = drawUiPanel(f, s);
    const cam_changed: bool = handleInput(f, s, ui_capture_mouse);

    const basis: CamBasis = deriveBasis(s.cam);

    if (cam_changed) {
        @memset(s.accum, vec(0, 0, 0));
        s.sample_count = 0;
    }
    s.moving = cam_changed;

    // 4. Render - full-res accumulate when still, stride-4 single-
    //    sample when moving.  When the accumulator hits its cap,
    //    skip rendering entirely; the displayed image already shows
    //    the converged result.
    if (s.moving) {
        renderStride(s, &basis);
    } else if (s.sample_count < @as(u32, @intCast(s.params.samples_per_pixel))) {
        renderOneSample(s, &basis);
        s.sample_count += 1;
    }

    // 5. Push pixels to the GPU + draw.
    s.fb.update(f.gpu.queue, std.mem.sliceAsBytes(s.pixels));

    z.clearViewport(f, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    s.fb.present(f.gl, 0, 0, float(screen_w), float(screen_h));

    z.endDrawing(f.gl);
}

// ============================================================================
// Input -> camera updates
// ============================================================================

// ============================================================================
// Rendering - two paths, full-res accumulate + low-res-while-moving
// ============================================================================

// ============================================================================
// Trace - recursive shading
// ============================================================================

// ============================================================================
// Material scatter
// ============================================================================

// ============================================================================
// Sky + tonemap
// ============================================================================

// ============================================================================
// UI panel
// ============================================================================

/// User-owned framework integration point.  See `examples/basic.zig`
/// for the canonical comment block; this declaration is the
/// AppBridge pattern's required convention.
/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - ray tracer (CPU)",
            .width = screen_w,
            .height = screen_h,
            .scale_mode = .fit,
            .depth_format = null,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
