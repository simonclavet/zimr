# raytracer.zig — single-file path tracer example

A real-time, interactive CPU path tracer for zimr, ~600-800 LOC in a
single file under `examples/`.  Based on the structure of "Ray
Tracing in One Weekend" (the upstream zip Simon uploaded), but:
- Adapted to zimr's frame loop + UI + input.
- Scene objects stored in `entities.zig` instead of an ArrayList.
- Camera live-movable; while moving, drops to low-res + single-sample
  to keep the frame budget under ~16 ms.
- All tunables exposed via an imgui panel.

## Goals

1. **Visual:** Three or more spheres on a ground plane, with a mix of
   lambertian / metal / dielectric materials.  Sky gradient.  Pleasing
   default scene at first frame.
2. **Interactive:** WASD + mouse-look for camera.  60 fps target while
   moving (degraded quality acceptable); converges to crisp render
   when still.
3. **Tunable:** UI panel covers samples-per-pixel, max bounce depth,
   vertical FOV, sun angle/sky tint, plus per-material picker for the
   selected sphere.
4. **Self-contained:** No dependencies beyond `zimr`, `zimr.ecs`,
   `zimr.ui`, `zimr.zimrmath`.  Single file.
5. **Pedagogical:** Each section commented in prose ("what is this
   doing and why"), present-tense, matches Simon's "what it IS not
   what it could be" doc style.

## Non-goals

- No BVH / spatial acceleration.  Linear iteration over ~5-10 spheres
  is fine; performance lives in the trace function, not the broad-
  phase.
- No GPU compute / WebGPU.  Pure CPU.  zimr targets WebGL2 and the
  example is meant to show the math + interactivity, not push
  the rasterizer.
- No multithreading.  The upstream uses 12 threads on a Mac; we're
  single-threaded wasm.  The low-res-while-moving trick is what buys
  the interactivity.
- No textures.  Solid albedos only.
- No emitters / area lights.  Sky is the only light source (matches
  RTiOW Book 1).

## File structure

One file: `examples/raytracer.zig`.  Sections (in order):

```zig
// 1. Imports + constants
// 2. Components — Sphere, Material (tagged union)
// 3. State — accumulator buffer, ECS world, camera, params, UI ctx
// 4. Init  — spawn the default scene, allocate the pixel buffer
// 5. Per-frame update:
//    5a. Read input → maybe-move camera; flag `moving` if anything changed
//    5b. Pick render resolution: full when still, 1/4 when moving
//    5c. Trace + accumulate into the float framebuffer
//    5d. Tonemap → upload pixels to texture → draw stretched to canvas
//    5e. Draw UI panel
// 6. Trace primitives:
//    6a. hitSphere — analytic ray-sphere intersection (zimr math)
//    6b. hitScene  — iterate ECS entities, return nearest hit
//    6c. scatterLambertian / scatterMetal / scatterDielectric
//    6d. rayColor  — recursive shading (depth-limited)
// 7. Camera math — re-derive viewport basis from lookfrom/lookat/vup
// 8. UI panel layout
```

## Components (ECS)

Each scene object is one entity with two components:

```zig
const Sphere   = struct { center: Vector3, radius: f32 };
const Material = union(enum) {
    lambertian: struct { albedo: Vector3 },
    metal:      struct { albedo: Vector3, fuzz: f32 },
    dielectric: struct { ref_idx: f32 },
};
```

Spawning a sphere:

```zig
const e = try ecs.Entity.reserveImmediateOrErr(&world);
_ = try e.changeArchImmediateOrErr(&world, gpa, struct {
    sphere:   Sphere,
    material: Material,
}, .{ .add = .{ .sphere = ..., .material = ... } });
```

The trace pass iterates with `world.iterator(struct { s: *const Sphere, m: *const Material })`.

**Why ECS?**  For a 5-sphere scene it's overkill, but:
- The single-archetype iteration compiles to the same loop a flat
  array would.
- Live add/remove via the UI ("+ Sphere" / "- Sphere" buttons) is a
  one-line `Entity.reserve` or `e.destroyImmediate`.
- Matches Simon's directive ("use entities.zig to hold the
  objects").

**Capacity:** preset `cap.entities = 64` (room for several dozen
spheres if the user goes wild with the spawn button).

## Math additions for zimrmath.zig

Path tracers need RNG-driven vector samples.  zimrmath has every
deterministic op (add/sub/scale/dot/cross/normalize/reflect/refract)
but no random-vector helpers.  Add three:

```zig
/// Uniformly random point inside the unit sphere (rejection sample).
pub fn vector3RandomInUnitSphere(rng: std.Random) Vector3;

/// Uniformly random point on the unit sphere's surface.  Useful for
/// lambertian scatter — `normal + randomUnitVector` is the standard
/// diffuse direction.
pub fn vector3RandomUnitVector(rng: std.Random) Vector3;

/// Uniformly random point inside the unit disk on the XY plane.
/// Used for depth-of-field sampling (defocus blur).
pub fn vector2RandomInUnitDisk(rng: std.Random) Vector2;
```

All three use rejection sampling against the unit cube/square; ~5
iterations average.  Document in the doc comment per Rule 11 style:
present tense, what it returns, no history.

Tests: each fn — generate 1000 samples, check magnitude is in [0, 1]
(or near 1.0 for unit-vector), check the mean is near origin (within
3σ).  ~30 LOC of tests in zimrmath.zig.

## Pixel pipeline

zimr already has the relevant texture-streaming fns
(`genImageColor`, `loadTextureFromImage`, `updateTexture`).  Pattern:

1. **Init:** allocate a CPU buffer `pixels: []Color` of size
   `W * H` (full-resolution count, e.g. 480 × 270 = 130 K pixels at
   ~512 KB).  Allocate a parallel `accum: []Vector3` float buffer
   for sample accumulation while idle.  Build an `Image` pointing at
   `pixels`, then `loadTextureFromImage` to get a GPU `Texture2D`.

2. **Per frame:**
   - `moving = bool` — set by the input pass.
   - If moving: stride = 4 (render every 4th pixel).  Sample count
     per pixel = 1.  Reset `accum` to zero so previous frame's hot
     spots don't bleed in.
   - If still: stride = 1.  Accumulate one new sample per pixel into
     `accum`, divide by `sample_count` to get the displayed color.
     Increment `sample_count`; cap at e.g. 256.
   - Tonemap (gamma 2.2 sqrt) + clip → `pixels[i]` as RGBA u8.
   - `updateTexture(tex, pixels.ptr)` — uploads the buffer.
   - `drawTexturePro` to stretch it to fill the canvas.

3. **Resolution choice:** internal RT res = 480 × 270 (16:9 quarter
   of 1920 × 1080).  Canvas = 800 × 450.  The texture stretch is
   nearest-neighbor so the image looks crisp-pixelated.  When moving
   with stride 4, each rendered pixel covers 16 screen pixels — very
   coarse but motion masks it.

## Camera + input

Camera state is what `Camera.initialize` in the upstream computes,
plus live `lookfrom` / `yaw` / `pitch` fields.

```zig
const Camera = struct {
    lookfrom: Vector3,
    yaw:      f32,   // radians, around +Y
    pitch:    f32,   // radians, clamped to ±~80°
    vfov:     f32,   // degrees

    // Derived (recomputed each frame from above):
    u: Vector3, v: Vector3, w: Vector3,
    px00: Vector3, pdu: Vector3, pdv: Vector3,
};
```

**Input mapping:**

| Input | Action |
|---|---|
| W / S | Translate along `-w` / `+w` (forward / back) |
| A / D | Translate along `-u` / `+u` (left / right) |
| Q / E | Translate along `-v` / `+v` (down / up) |
| Mouse drag (RMB held) | Yaw + pitch by delta × sensitivity |
| Shift | 4× speed multiplier |
| Scroll wheel | Zoom: nudge vfov by ±1° |

`moving = any-key-down OR RMB-held-with-mouse-delta`.

Camera basis recompute from `(yaw, pitch)`:

```zig
const w_dir: Vector3 = .{
    .x = @cos(pitch) * @sin(yaw),
    .y = @sin(pitch),
    .z = @cos(pitch) * @cos(yaw),
};
const w = math.vector3Normalize(w_dir);   // forward
const u = math.vector3Normalize(math.vector3CrossProduct(world_up, w));
const v = math.vector3CrossProduct(w, u);
```

Then derive `px00`/`pdu`/`pdv` from `(lookfrom, u, v, w, vfov, aspect)`
exactly as the upstream's `Camera.initialize` does.

## UI panel

One window, "Path tracer":

| Widget | Param | Range | Default |
|---|---|---|---|
| Slider | `samples_per_pixel` (still mode cap) | 1–256 | 64 |
| Slider | `max_depth` | 1–10 | 5 |
| Slider | `vfov` | 10°–90° | 50° |
| Combo  | Sky preset | Day / Sunset / Night | Day |
| Color  | Ground albedo | — | (0.7, 0.7, 0.7) |
| Button | "+ Sphere" | — | Spawns at random pos with lambertian albedo |
| Button | "Reset scene" | — | Destroy + respawn default scene |
| Text   | "Samples accumulated: N / target" | — | live |
| Text   | "Moving / Still" | — | live |

**Sky presets:** three pairs of (`top_color`, `bottom_color`) — Day is
the classic light-blue-to-white gradient; Sunset is orange-to-purple;
Night is dark-navy-to-black.

## Algorithm sketch

```zig
fn rayColor(ray: Ray, world: *ecs.World, params: Params, depth: usize) Vector3 {
    if (depth == 0) return .{ .x = 0, .y = 0, .z = 0 };

    // Closest-hit pass: iterate every (Sphere, Material) entity.
    var iter = world.iterator(struct { s: *const Sphere, m: *const Material });
    var closest_t: f32 = std.math.inf(f32);
    var closest: ?HitRecord = null;
    while (iter.next(world)) |view| {
        if (hitSphere(view.s.*, ray, 0.001, closest_t)) |rec| {
            closest_t = rec.t;
            closest = .{ .rec = rec, .mat = view.m.* };
        }
    }

    if (closest) |c| {
        if (scatter(c.mat, ray, c.rec, rng)) |s| {
            return math.vector3Multiply(
                s.attenuation,
                rayColor(s.scattered, world, params, depth - 1),
            );
        }
        return .{ .x = 0, .y = 0, .z = 0 };
    }
    // Miss: sky.
    return skyColor(ray.direction, params.sky);
}
```

`hitSphere` is the analytic quadratic-formula intersection from the
upstream (`sphere.zig` lines 13–43), translated to f32 + zimrmath
calls.  ~30 LOC.

`scatter` dispatches on the tagged union (3 arms × ~10 LOC each).

`skyColor`: `lerp(bottom, top, 0.5 * (unit_dir.y + 1))`.  3 LOC.

## Performance budget

Single-threaded wasm32, f32, 480 × 270 internal:
- ≈130 K primary rays per frame.
- Each ray: trace + up to 5 bounces × (loop over 5 spheres) ≈ 25 sphere
  tests, ~20 FLOPs each = ~13 M FLOPs per frame.
- Browser SIMD-enabled wasm runs ~1 G FLOPs/s for this kind of code
  (rough — varies wildly).  Budget: ~15 ms per frame at full res
  single-sample.

When moving (stride 4): only 130K / 16 = 8K primary rays, ~1 ms.
Plenty of headroom for the actual rendering + UI + texture upload.

When still (1 spp accumulated each frame): same 15 ms; the image
converges over ~5 seconds (e.g. 300 frames × 1 spp = 300 spp).  Each
frame after the first is just "add one more sample"; the image is
already viewable from frame 1, just noisy.

Headroom for going wider: if performance allows, bump internal res to
640 × 360 in a future turn.  Start conservative.

## Open questions for Simon before coding

1. **f32 vs f64 for the math:**  Upstream uses f64.  zimrmath is f32-
   native.  f32 is fine visually for a real-time demo; f64 would
   require a parallel zimrmath suffix or templating.  **Default:
   f32.**  Override if Simon prefers f64.

2. **Mouse-look engagement:**  RMB-drag-to-look (UI sees the cursor
   normally; only look when RMB held) vs WASD-and-mouse-always
   (Quake-style; need to lock pointer).  **Default: RMB-drag** —
   keeps UI clickable, doesn't need pointer-lock plumbing.

3. **Sphere count in the default scene:**  Upstream's "Final Scene"
   has 500 random spheres.  At 5 spheres the trace is trivial; at
   500 it's noticeable.  **Default: ~7 spheres** — three big ones in
   front (lambertian / dielectric / metal), one giant ground sphere
   (radius 1000), three small accent spheres.  User can spawn more
   via the UI button.

4. **Should this be in the smoke-test list?**  Smoke runs a few
   frames headless; the raytracer would still produce gl calls
   (drawTextureV) but the *content* is invisible to the smoke
   harness.  **Default: yes, add to smoke** — at least confirms it
   doesn't panic.  Future: add a "deterministic mode" flag that
   makes one specific test render reproducibly.

5. **CHANGELOG framing:**  This lands as either Batch 5 (with the
   shape-art ports) or its own one-example turn.  Given the size
   and singularity (the only path tracer in zimr), I'd argue it
   deserves its own turn rather than being bundled.  **Default:
   standalone Turn N entry.**

## Implementation order (when we start coding)

1. Add the three random-vector helpers + tests to `zimrmath.zig`.
   Verify build + tests green.
2. Stub `examples/raytracer.zig` with State + initState + an update
   that just clears the screen and draws a placeholder.  Wire it
   into `build.zig` + `manifest.json`.  Smoke green.
3. Add the ECS world, default scene spawning, and the trace function
   — but call it at low res (1 spp, stride 8) and don't yet wire
   camera input.  Verify a recognizable image renders.
4. Add the float accumulator + tonemap.  Switch to "still mode" —
   accumulate every frame.  Verify convergence over time.
5. Add camera input + lookfrom/yaw/pitch state + low-res-while-moving
   logic.
6. Add the UI panel.
7. Polish — labels, default tweaks, doc comments.

## Estimated turns

- Math additions + tests: half-turn.
- Stub + basic trace + accumulator: one turn.
- Camera + UI + polish: one turn.
- **Total: ~2.5 turns** to a shippable example.
