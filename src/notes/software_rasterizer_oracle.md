# A Software Rasterizer as a GPU Oracle — the plan

> Status: **CURRENT PLAN — committed 2026-06-16.** This is the authoritative
> design for the software rasteriser; it supersedes the "two-rasterizers
> collapse" one-liner in `GL_RETIREMENT_PLAN.md` (tier-2b). No immediate-work
> pressure — correctness is the only deadline.
> Goal: the most beautiful / flexible CPU rasteriser that is *also* a
> ground-truth oracle for the wgpu path and a teaching device. It folds
> `rlsw.zig` (fixed-function) and `rlsw_shader.zig` (programmable) into one
> system.
>
> ### THE DECISION (read this first)
> We build **Plan B only** — the single-threaded, scalar "Reference"
> rasteriser (§9). Plan A (tiled / parallel / SIMD, §8) is **recorded as
> rejected**, for one decisive reason: **our deployment is single-threaded
> wasm.** A's headline advantage — parallel tiles across threads — is
> unusable there. The GPU is our speed path; the SW rasteriser only has to be
> *usable*, and the existing SW PBR demo already is. So B is **both the spec
> and the engine**: there is exactly one rasteriser, kept simple enough to be
> correct by inspection.
>
> The door stays open: tiling and wasm-SIMD128 can later be added *to B* as
> pure single-threaded optimisations (§8 "cons" notes the single-threaded
> wins they'd still buy), each validated bit-exact against scalar B. We do
> *not* do them now, and we do not pay their complexity until perf forces it.
> The lane-polymorphic SoA rewrite (§1) is therefore **deferred** — the
> committed plan is `L = f32` scalar, which is ~what we already have.
>
> §1–§7 are the shared core (all still required). §9 is the rasteriser we
> build. §8 is the road not taken (kept for its reasoning). §10 is the
> verdict. §11 is the payoff (the oracle harness). §12 is the build order.

---

## 0. What "best" actually means here, and the tension it resolves

Three jobs, in priority order:

1. **Oracle.** The SW path is the *spec* the GPU must match. We already run the
   same `shaderMain(io: Io) Out` source through SPIR-V→WGSL for the GPU; the SW
   evaluation of that same source is the golden image. When `spv2wgsl` or Tint
   does something subtle (uniformity hoists, `OpPhi` undef, a sample-LOD quirk),
   the SW result is what tells us the GPU is wrong — *not* the other way round.
   This demands **GPU-faithful semantics**: the same coverage rule, the same
   sample positions, the same perspective-correct interpolation, the same
   derivative behaviour, the same NDC/depth conventions, deterministically.
2. **Teaching device.** The pipeline should be the GPU pipeline made legible:
   vertex shading → primitive assembly → clip → divide → viewport → cull →
   triangle setup → coverage → interpolate → quad fragment shading → depth →
   blend → MRT. Each stage inspectable, each with an obvious correct form.
3. **Production CPU renderer.** It must subsume the raylib fixed-function path
   (`rlsw.drawTriangle`, used by 10 call-sites: `ui.zig`, `wgpu_app`, …) with
   **no perf regression**, and be fast enough to be genuinely useful (not the
   current "2-5M px/s, viewer-grade" scalar path).

The tension I raised last turn — *"making fixed-function a shader on the
programmable path regresses the fast path onto a viewer-grade scalar loop"* —
**dissolves under Zig comptime.** `rasterize(comptime Fs: type, …)` is
monomorphised per shader. Feed it the fixed-function shader and the compiler
inlines the texture-sample-and-modulate into the inner loop, producing the same
machine code the hand-written fixed-function rasteriser had. *"Everything is a
shader"* costs zero when the shader is a comptime parameter. So the real design
question was never "which of the two existing rasterisers wins" — it's **what is
the one rasteriser, and how does it schedule work.** Under single-threaded
wasm (the §0 decision) the answer is the simplest schedule that is provably
correct: the Reference (§9).

Everything in §1–§7 is the shared core of the one rasteriser we build (§9).
§8 (the tiled/parallel design) is kept only as the recorded rationale for why
we *don't* build it under single-threaded wasm.

---

## 1. Shaders: scalar now, lane-polymorphic later (DEFERRED optimisation)

> **Committed plan: shaders stay `L = f32` scalar** — the form we already
> have, and exactly the form we hand to the SPIR-V backend (the GPU lanes
> pixels itself, so its source is scalar). The lane-polymorphic SoA design
> below is the **deferred** route to a single-threaded wasm-SIMD128 (W=4)
> speedup. Build it only if scalar B proves too slow in practice, and when you
> do, validate it bit-exact against scalar B. Read it now for context — it
> shapes how we write `shadermath` so the door stays open — but it is not in
> the committed scope.

A shader is written generic over a **lane type** `L`:

- `L = f32` → one pixel per invocation. This is *both* the readable reference
  *and* the form we hand to the SPIR-V backend (the GPU lanes pixels itself, so
  the GPU-bound source is scalar).
- `L = @Vector(8, f32)` → eight pixels per invocation (AVX2). Same source.

The trick is **SoA-over-pixels** ("SPMD on SIMD", the ISPC / SwiftShader model).
This is the single most important — and most easily-botched — expert point, so
be precise about the two distinct uses of `@Vector`:

```zig
// (a) GEOMETRIC SIMD  — what shader_interface.zig uses TODAY.
//     A 3-vector packs its 3 spatial components into one register.
//     One Vec3 = one pixel's normal. AoS. Good for scalar shading.
const Vec3_aos = @Vector(3, f32);          // {x, y, z} of ONE fragment

// (b) PIXEL SIMD (SoA) — what the fast path needs.
//     Each "component" is a lane-vector holding that component across W pixels.
//     One Vec3 = W pixels' normals. dot() does W dot products at once.
fn Vec3(comptime L: type) type {
    return struct { x: L, y: L, z: L };     // x = x-of-all-W-pixels
}
```

`shader_interface.zig`'s current `Vec4 = @Vector(4, f32)` is exactly the
`L = f32`, geometric-AoS instantiation — it already *is* the reference form (and
even gets free SIMD on the four spatial components). The generalisation that
unlocks the fast path is replacing the **scalar component** `f32` with the lane
type `L`, and laying vectors out SoA:

```zig
// shadermath, lane-polymorphic. `L` is f32 or @Vector(W, f32).
pub fn Sm(comptime L: type) type {
    return struct {
        pub const F = L;
        pub const V2 = struct { x: L, y: L };
        pub const V3 = struct { x: L, y: L, z: L };
        pub const V4 = struct { x: L, y: L, z: L, w: L };

        pub inline fn splat(s: f32) L {
            return if (L == f32) s else @splat(s);
        }
        pub inline fn dot3(a: V3, b: V3) L {
            return a.x * b.x + a.y * b.y + a.z * b.z; // works scalar & SIMD
        }
        pub inline fn normalize3(v: V3) V3 {
            const inv = splat(1.0) / @sqrt(dot3(v, v)); // @sqrt is lane-wise
            return .{ .x = v.x * inv, .y = v.y * inv, .z = v.z * inv };
        }
        pub inline fn mix(a: L, b: L, t: L) L { return a + (b - a) * t; }
        // … cross, mul (mat·vec), pow, exp, etc. — all lane-wise, one body.
    };
}
```

A shader written against `Sm(L)` compiles three ways from one source:

```zig
// pbr_fs.zig — sketch of the lane-polymorphic shape.
pub fn Shader(comptime L: type) type {
    const sm = Sm(L);
    return struct {
        pub const Uniforms = extern struct { light_dir: [3]f32, exposure: f32, /*…*/ };
        // Varyings = the VS→FS interpolants. By convention these are what gets
        // perspective-correctly interpolated (see §4). Lane-typed.
        pub const Varyings = struct { world_pos: sm.V3, normal: sm.V3, uv: sm.V2 };
        pub const Out = struct { color: sm.V4 };

        pub fn fragmentMain(v: Varyings, u: *const Uniforms, ctx: *FragmentCtx(L)) Out {
            const n = sm.normalize3(v.normal);
            const ndl = @max(sm.dot3(n, ldir(u)), sm.splat(0));
            const albedo = ctx.sample(ctx.albedo_tex, v.uv);  // auto-LOD, §5/§6
            return .{ .color = .{ .x = albedo.x * ndl, /*…*/ .w = sm.splat(1) } };
        }
    };
}

const PbrScalar = Shader(f32);          // reference + the source we transpile
const PbrAvx2   = Shader(@Vector(8, f32)); // production fast path
```

**Why this is the foundation of the oracle:** one source, three backends, no
divergence. The reference (`L=f32`) and the GPU (scalar SPIR-V of the same
source) are *the same program*; the fast path is the same program widened. There
is no second implementation to drift.

> Honest caveat: today's shaders are AoS-`@Vector(4,f32)` scalar. The
> lane-polymorphic SoA rewrite is real work (it touches `shadermath` and every
> `_fs.zig`/`_vs.zig`). It is *not* needed for the reference or the GPU — those
> are the `L=f32` form, which is ~what we have. It is only needed to *widen* the
> CPU path. So we can ship the reference (§9) first and widen later (§12).

---

## 2. The pipeline as explicit, configurable stages

Mirror the GPU. One config type drives everything; comptime-known so the
compiler specialises each combination and dead-strips disabled stages.

```zig
pub const CompareFn = enum { never, less, equal, less_equal, greater, not_equal, greater_equal, always };
pub const CullMode  = enum { none, front, back };
pub const Winding   = enum { ccw, cw };
pub const FillMode  = enum { solid, wire, point };
pub const BlendOp   = enum { none, alpha, additive, premultiplied /*…*/ };

pub const PipelineConfig = struct {
    lane_width: comptime_int = 1,         // 1 = reference; 8 = AVX2 fast path
    depth_test: bool = true,
    depth_write: bool = true,
    depth_compare: CompareFn = .less,     // wgpu reverse-Z is just .greater + clear 0
    cull: CullMode = .back,
    front_face: Winding = .ccw,           // matches wgpu / GL(CCW)
    fill: FillMode = .solid,
    blend: BlendOp = .none,
    color_targets: comptime_int = 1,      // MRT
    samples: comptime_int = 1,            // 1, 4 (MSAA), …
    subpixel_bits: comptime_int = 8,      // fixed-point coverage precision (§3)
};

// The whole pipeline is `Raster(cfg, VsModule, FsModule)`; both VS/FS are
// comptime, so the shaders inline and the config branches fold away.
pub fn Raster(comptime cfg: PipelineConfig, comptime Vs: type, comptime Fs: type) type { … }
```

The stage order (the scheduling around it is the only thing §8 would have
changed; we take §9):

```
vertices ──VS──▶ clip-space + varyings
            └─ primitive assembly (3 verts/tri)
            └─ CLIP near plane (§7)         ← the stage naive rasterisers skip
            └─ perspective divide  (clip → NDC)
            └─ viewport transform  (NDC → screen, subpixel-snapped, §3)
            └─ back-face cull (signed area sign)
            └─ triangle setup (edge fns, 1/w, varyings/w)        ← per-tri
            └─ COVERAGE (tiled or bbox; fixed-point; top-left; §3)
            └─ perspective-correct interpolation (comptime fold, §4)
            └─ 2×2 QUAD fragment shading + derivatives (§5/§6)
            └─ depth test/write
            └─ blend
            └─ MRT color write
```

---

## 3. Watertight coverage: fixed-point subpixel edge functions + the top-left rule

This is non-negotiable for an oracle. Floating-point edge functions **leak**:
two triangles sharing an edge can both skip a boundary pixel (a crack) or both
cover it (double-shade — wrong for blending). Hardware avoids this with
**fixed-point subpixel coverage** + a **tie-break fill rule**. We match it.

```zig
// Snap screen-space vertices to a subpixel grid (cfg.subpixel_bits fractional
// bits; 8 → 1/256 px, like D3D). Edge functions then live in exact integers.
const SUB = 1 << cfg.subpixel_bits;
inline fn snap(x: f32) i32 { return @intFromFloat(@round(x * SUB)); }

// Edge v_a → v_b, evaluated at pixel-centre. E(x,y) = A·x + B·y + C, in i64 to
// avoid overflow on the C term (coords are ~screen·SUB, product is ~that²).
const Edge = struct {
    a: i64, b: i64, c: i64,
    fn setup(ax: i32, ay: i32, bx: i32, by: i32) Edge {
        const A: i64 = ay - by;     // (these are the standard
        const B: i64 = bx - ax;     //  Pineda half-space coefficients)
        // Top-left rule baked into C: a sample exactly on the edge is "inside"
        // iff the edge is top-left. Bias by -1 (in subpixel units) otherwise.
        const top_left = (A < 0) or (A == 0 and B > 0); // dy<0 || (dy==0 && dx<0)
        const bias: i64 = if (top_left) 0 else -1;
        const C: i64 = -(A * ax + B * ay) + bias;
        return .{ .a = A, .b = B, .c = C };
    }
    inline fn eval(e: Edge, x: i32, y: i32) i64 {
        // pixel centre = (x + 0.5) → (x·SUB + SUB/2) in fixed point
        return e.a * (@as(i64, x) * SUB + SUB / 2) + e.b * (@as(i64, y) * SUB + SUB / 2) + e.c;
    }
    // incremental: eval(x+1,y) = eval(x,y) + a·SUB ; eval(x,y+1) += b·SUB
};
```

A pixel is covered when **all three** edges are `>= 0` (for one winding;
flip signs for the other). Coverage is now exact and deterministic: adjacent
triangles partition the plane with no cracks and no double-coverage. *This is
the property that makes the SW path a trustworthy oracle for coverage.*

The three edge values at a covered pixel are, after normalising by the doubled
area, the **barycentric weights** — free, no separate computation.

---

## 4. Perspective-correct interpolation as a comptime fold over the varyings

Linear-in-screen-space interpolation of attributes is wrong under perspective.
The correct recipe: interpolate `attr/w` and `1/w` linearly (they *are* affine in
screen space), then divide. Generalise over **any** `Varyings` struct with a
comptime field fold — beautiful and total:

```zig
// w0,w1,w2 are the barycentric weights (the normalised edge values, §3).
// iw = {1/w0', 1/w1', 1/w2'} are per-vertex 1/clip_w from triangle setup.
inline fn interpolate(comptime V: type, a: V, b: V, c: V, w: [3]f32, iw: [3]f32) V {
    const p0 = w[0] * iw[0];
    const p1 = w[1] * iw[1];
    const p2 = w[2] * iw[2];
    const inv_sum = 1.0 / (p0 + p1 + p2);       // = interpolated 1/w, inverted
    var out: V = undefined;
    inline for (std.meta.fields(V)) |f| {
        const FT = f.type;                       // f32, @Vector(n,f32), or a Vec struct
        const va = @field(a, f.name);
        const vb = @field(b, f.name);
        const vc = @field(c, f.name);
        @field(out, f.name) = scaleAdd3(FT, va, p0, vb, p1, vc, p2, inv_sum);
    }
    return out;
}
// scaleAdd3 is itself a tiny comptime recursion for nested Vec structs, so this
// works for V2/V3/V4 and any user varying struct with no special-casing.
```

Depth `z` is the exception: `z/w` *is* screen-affine, so depth uses the raw
barycentric weights (no perspective divide) — exactly as your current
`rasterizeTriangles` comment already notes. We keep that.

---

## 5. 2×2 quads + derivatives — the GPU's open secret, and why an oracle *must* do it

GPUs never shade a lone pixel. They shade **2×2 quads** so a fragment can take
finite differences across the quad: `ddx(v) = v[right] - v[left]`,
`ddy(v) = v[bottom] - v[top]`. That's how `textureSample` gets its mip LOD, how
`fwidth` works, how anti-aliased procedural patterns get their filter width. A
fragment near a triangle edge has **helper invocations** — the off-triangle quad
pixels are still shaded (results discarded) purely to make derivatives valid.

If the SW oracle shades single pixels, **every shader that samples a texture
with implicit LOD diverges from the GPU.** So quads are mandatory for fidelity,
not an optimisation. Lane layout (quad-major):

```zig
//  lane 0 = (x,   y  )  TL      derivatives within a quad:
//  lane 1 = (x+1, y  )  TR        ddx = lane[1] - lane[0]   (and lane[3]-lane[2])
//  lane 2 = (x,   y+1)  BL        ddy = lane[2] - lane[0]   (and lane[3]-lane[1])
//  lane 3 = (x+1, y+1)  BR
inline fn ddx(comptime W: comptime_int, v: @Vector(W, f32)) @Vector(W, f32) {
    // For each 4-lane quad, broadcast (right - left) to both columns.
    // W=4 (one quad): shuffle to {1,1,3,3} - {0,0,2,2}.
    const right = @shuffle(f32, v, undefined, [W]i32{ 1, 1, 3, 3 });
    const left  = @shuffle(f32, v, undefined, [W]i32{ 0, 0, 2, 2 });
    return right - left;
}
inline fn ddy(comptime W: comptime_int, v: @Vector(W, f32)) @Vector(W, f32) {
    const bot = @shuffle(f32, v, undefined, [W]i32{ 2, 3, 2, 3 });
    const top = @shuffle(f32, v, undefined, [W]i32{ 0, 1, 0, 1 });
    return bot - top;
}
```

This is where lane-polymorphism (§1) and quads click together: the natural fast
path is `lane_width = 4·k` with **quad-major packing** (W=8 → two quads). The
reference (`L=f32`) still shades a quad — as four sequential scalar invocations
whose four outputs are differenced — so derivatives are correct even in the
reference. The reference is slower but *semantically identical*, which is the
whole point.

---

## 6. The fragment context — the SW↔GPU builtin bridge

Everything a WGSL fragment can do that isn't pure arithmetic goes through one
context type, lane-typed, mirroring the WGSL builtins so the shader source is
literally the same:

```zig
pub fn FragmentCtx(comptime L: type) type {
    const sm = Sm(L);
    return struct {
        const Self = @This();
        frag_coord: sm.V4,                 // gl_FragCoord / @builtin(position)
        // Derivative plumbing: the quad's interpolated varyings live here so
        // sample() can difference them. Filled by the rasteriser per quad.
        quad_uv: [4]sm.V2 = undefined,     // (only meaningful for L spanning a quad)
        // bound resources:
        albedo_tex: *const Texture, /* … */

        pub fn ddx(self: *Self, v: L) L { return derivX(L, v); }
        pub fn ddy(self: *Self, v: L) L { return derivY(L, v); }

        /// textureSample with implicit LOD — uses quad derivatives of uv.
        pub fn sample(self: *Self, tex: *const Texture, uv: sm.V2) sm.V4 {
            const dudx = self.ddx(uv.x); const dvdx = self.ddx(uv.y);
            const dudy = self.ddy(uv.x); const dvdy = self.ddy(uv.y);
            const lod = computeLod(L, dudx, dvdx, dudy, dvdy, tex.dims); // log2(maxAniso)
            return tex.sampleTrilinear(uv, lod);   // matches GPU mip+bilinear
        }
        pub fn sampleLod(self: *Self, tex: *const Texture, uv: sm.V2, lod: L) sm.V4 { … }

        /// discard, lane-masked (a quad may discard some lanes, keep others).
        pub fn discard(self: *Self, mask: Mask(L)) void { self.kill |= mask; }
    };
}
```

The match between `computeLod` / `sampleTrilinear` and the GPU's sampler is the
crux of fidelity. Document the sampler model (mip selection, wrap modes,
filtering, gamma) as *the* spec; the GPU is then validated against it.

---

## 7. Clipping — the stage everyone skips, and the bug it hides

A vertex with `w <= 0` (behind the eye) makes the perspective divide produce
garbage; a triangle straddling the near plane *must* be clipped or it smears
across the screen. Naive rasterisers (including, today, `rlsw_shader`) skip this
and rely on geometry staying in front of the camera — fine for a fixed demo,
fatal for a general oracle. Near-plane Sutherland–Hodgman, with varyings
interpolated at the introduced vertices via the **same comptime fold** as §4:

```zig
// Clip one triangle against the near plane (clip-space w + z >= 0 for wgpu's
// [0,1] z; use w - z, w + z, etc. for the six planes if you want full frustum).
// Produces 0, 1, or 2 output triangles.
fn clipNear(comptime Vary: type, tri: [3]ClipVert(Vary), out: *[2][3]ClipVert(Vary)) usize {
    var poly: [4]ClipVert(Vary) = undefined; var n: usize = 0;
    inline for (0..3) |i| {
        const a = tri[i]; const b = tri[(i + 1) % 3];
        const da = a.pos.w + a.pos.z;     // signed distance to near plane
        const db = b.pos.w + b.pos.z;
        if (da >= 0) { poly[n] = a; n += 1; }
        if ((da >= 0) != (db >= 0)) {     // edge crosses the plane
            const t = da / (da - db);     // intersection parameter
            poly[n] = lerpVert(Vary, a, b, t); // lerps pos AND every varying (fold)
            n += 1;
        }
    }
    // fan-triangulate the clipped polygon (n is 3 or 4)
    if (n < 3) return 0;
    out[0] = .{ poly[0], poly[1], poly[2] };
    if (n == 4) { out[1] = .{ poly[0], poly[2], poly[3] }; return 2; }
    return 1;
}
```

(Guard-band rasterisation — clip only against a band larger than the viewport
and let coverage scissor the rest — is the standard perf refinement; note it,
defer it.)

---

## 8. The road not taken — "The GPU Mirror" (tiled / parallel) — REJECTED for single-threaded wasm

> **Recorded for its reasoning, not built.** A's decisive win is *parallel
> tiles across threads* — unusable in single-threaded wasm, which is our
> deployment. Its single-threaded merits (hierarchical tile trivial-accept/
> reject, cache-resident tile framebuffer) are real but secondary, and can be
> retrofitted onto B later as a pure optimisation (see "Pros" below) *without*
> A's binning-and-threading machinery. Given the GPU is our speed path and
> scalar B is usable, A's complexity is not worth it. Read on for the tradeoff
> we are consciously declining.

The most faithful software model of a **tile-based GPU** (every mobile GPU; the
helmet's actual target). Two phases: **bin** triangles into screen tiles, then
**shade** tiles — and tiles are independent, so shading parallelises with zero
locking (disjoint framebuffer regions).

```zig
const TILE = 32; // px. Tile-resident color+depth fits in cache.

const BinnedTri = struct { setup: TriSetup, /* edges, 1/w, varyings/w */ };
const Tile = struct {
    tris: std.ArrayListUnmanaged(BinnedTri) = .{},
    x0: u16, y0: u16,
};

// PHASE 1 — bin. Each triangle's screen bbox → the tiles it touches.
fn binTriangle(tiles: []Tile, cols: usize, setup: TriSetup) void {
    const tx0 = setup.bbox.min_x / TILE; const tx1 = setup.bbox.max_x / TILE;
    const ty0 = setup.bbox.min_y / TILE; const ty1 = setup.bbox.max_y / TILE;
    var ty = ty0; while (ty <= ty1) : (ty += 1) {
        var tx = tx0; while (tx <= tx1) : (tx += 1) {
            // (optional: trivial-reject the tile against the 3 edges here)
            tiles[ty * cols + tx].tris.append(alloc, .{ .setup = setup }) catch {};
        }
    }
}

// PHASE 2 — shade one tile (a worker thread owns it; no shared writes).
fn shadeTile(comptime cfg: PipelineConfig, comptime Fs: type, fb: *Framebuffer, tile: *Tile) void {
    for (tile.tris.items) |t| {
        // Hierarchical coverage: test the tile's 4 corners against each edge.
        // If a whole tile is inside an edge, skip the per-pixel edge test for it
        // (trivial-accept). If fully outside, skip the triangle for this tile.
        // Otherwise descend to 2×2 quads:
        var qy = tile.y0; while (qy < tile.y0 + TILE) : (qy += 2) {
            var qx = tile.x0; while (qx < tile.x0 + TILE) : (qx += 2) {
                const cov = quadCoverage(t.setup, qx, qy);     // §3, 4 lanes
                if (cov == 0) continue;                        // (helpers: keep if any lane in)
                const bary = quadBarycentrics(t.setup, qx, qy);
                const vary = interpolateQuad(Fs.Varyings, t.setup, bary); // §4
                var ctx = FragmentCtx(QuadLane){ .frag_coord = … };
                const out = Fs.fragmentMain(vary, t.setup.uniforms, &ctx); // §5/§6
                // per-lane: depth test → blend → MRT write, masked by cov & !ctx.kill
                fb.writeQuad(cfg, qx, qy, out, cov, &ctx);
            }
        }
    }
}

// Dispatch: a thread pool, tiles as work items. Static or work-stealing.
pub fn renderMirror(comptime cfg: PipelineConfig, comptime Vs: type, comptime Fs: type,
                    pool: *std.Thread.Pool, fb: *Framebuffer, mesh: Mesh, u: *const Fs.Uniforms) void {
    // VS + clip + setup + bin (can itself be parallel over triangle ranges) …
    var wg: std.Thread.WaitGroup = .{};
    for (tiles) |*tile| pool.spawnWg(&wg, shadeTile, .{ cfg, Fs, fb, tile });
    pool.waitAndWork(&wg);
}
```

**Pros**
- *Best oracle for real GPUs.* Tile + 2×2-quad + hierarchical coverage is what
  mobile TBDR hardware does; behaviours like quad helper-invocation timing,
  tile-granular early-Z, and bandwidth shape match the thing we're validating.
- *Best performance ceiling.* Tiles are embarrassingly parallel with **no locks**
  (disjoint regions); tile-resident color+depth is cache-perfect; hierarchical
  trivial-accept/reject skips most edge tests on large triangles; SIMD across the
  quad/tile row. This is the architecture that scales to many cores + wide SIMD.
- *MSAA is cheap and local* — per-tile sample buffers, resolve on tile evict.
- *Deferred-friendly* — natural place to add early-Z, overdraw stats, a visible
  "tiles touched / overdraw" debug view (great teaching + great profiling).

**Cons**
- *Two-phase, more moving parts* — binning structure, tile memory, a scheduler.
  More code, more to get right, more to explain.
- *Harder to single-step mentally* — control flow is bin-then-sweep, not "follow
  one triangle." Worse as the *first* thing a learner reads.
- *Binning overhead on tiny triangles* — a 3-pixel triangle still pays tile
  bookkeeping; pathological for dense micro-geometry (mitigable, but real).
- *Determinism needs care* — triangle order within a tile must be stable for
  blend/MRT to be bit-reproducible across thread counts (sort by submit index).

---

## 9. THE RASTERISER WE BUILD — "The Reference" (sort-first, immediate per-triangle, scalar)

The executable specification. One triangle at a time, bounding-box walk in
quads, `lane_width = 1`, single-threaded. So small you can hold all of it in your
head and so simple it is *correct by inspection.* This is the cleaned-up,
fixed-pointed, clipped, quad-shaded descendant of today's
`rlsw_shader.rasterizeTriangles`.

```zig
pub fn rasterizeReference(
    comptime cfg: PipelineConfig,        // cfg.lane_width == 1
    comptime Vs: type,
    comptime Fs: type,
    fb: *Framebuffer,
    mesh: Mesh,
    u: *const Fs.Uniforms,
) void {
    // 1. Vertex shading → clip space + varyings (one array, indexed by vid).
    const vout = runVertexShader(Vs, mesh, u);

    var i: usize = 0;
    while (i < mesh.indices.len) : (i += 3) {
        // 2. Assemble, 3. clip near plane (§7) → 0/1/2 triangles.
        var clipped: [2][3]ClipVert(Fs.Varyings) = undefined;
        const n = clipNear(Fs.Varyings, gather3(vout, mesh.indices, i), &clipped);

        for (clipped[0..n]) |tri| {
            // 4. perspective divide, 5. viewport + subpixel snap (§3),
            // 6. back-face cull (signed area sign vs cfg.front_face).
            const s = setupTriangle(cfg, tri);
            if (s.culled) continue;

            // 7. walk the bbox in 2×2 quads (so derivatives are valid, §5).
            var y = s.bbox.min_y & ~@as(i32, 1);
            while (y <= s.bbox.max_y) : (y += 2) {
                var x = s.bbox.min_x & ~@as(i32, 1);
                while (x <= s.bbox.max_x) : (x += 2) {
                    // four scalar lanes of the quad, sequential:
                    var quad_vary: [4]Fs.Varyings = undefined;
                    var cov: u4 = 0;
                    inline for (0..4) |q| {
                        const px = x + (q & 1); const py = y + (q >> 1);
                        if (s.covers(px, py)) cov |= (1 << q);     // §3
                        quad_vary[q] = s.interpolate(Fs.Varyings, px, py); // §4
                    }
                    if (cov == 0) continue;
                    // 8. shade (helpers included so ddx/ddy across quad_vary work).
                    inline for (0..4) |q| {
                        var ctx = FragmentCtx(f32){ .quad = &quad_vary, .lane = q, … };
                        const out = Fs.fragmentMain(quad_vary[q], u, &ctx);
                        if (cov & (1 << q) == 0 or ctx.killed) continue;
                        const px = x + (q & 1); const py = y + (q >> 1);
                        // 9. depth test/write, 10. blend, 11. MRT write — all
                        //    comptime-gated by cfg, so disabled stages vanish.
                        fb.writeFragment(cfg, px, py, out, &ctx);
                    }
                }
            }
        }
    }
}
```

**Pros**
- *It is the spec.* Linear, allocation-free control flow you can audit line by
  line. When SW and GPU disagree, B is the arbiter you trust without a second
  thought. An oracle you can't trust is worthless; B is the trust.
- *Best teaching artifact.* "Follow one triangle from vertex to pixel" — the
  whole GPU pipeline, legible, in one function. This is the file a newcomer reads.
- *Zero scheduling state* — no bins, no threads, nothing to make non-deterministic.
  Bit-reproducible by construction.
- *Trivially widened* — flip `cfg.lane_width` to 8 and the *only* thing that
  changes is the inner quad loop becomes vectorised; semantics are unchanged, so
  the widened B is validated by the scalar B for free.

**Cons**
- *Not the fastest.* Per-triangle setup with no hierarchy; large triangles re-test
  every quad in the bbox even where a tile-accept would skip them; parallelism is
  coarse (per-triangle or per-scanline-band, with framebuffer contention you have
  to manage). Fine for an oracle and for modest scenes; not a 4-core 8-wide engine.
- *Slightly weaker as a behavioural GPU model* — it is **pixel-identical** to a
  real GPU (same coverage, same quads, same interpolation), but it does not model
  *tile/bandwidth/early-Z scheduling*, so it's a perfect *image* oracle and only an
  approximate *performance/architecture* oracle. (A is the architecture oracle.)

---

## 10. The verdict — one rasteriser (B), which is both the spec and the engine

Under single-threaded wasm the "which architecture" question answers itself: A's
parallelism is unreachable, so its complexity buys nothing we can spend. We build
**B and only B.** Crucially, B is not a compromise here — because the GPU carries
real-time performance and B carries *correctness*, B gets to be the thing it is
best at: the **executable specification**, slow-and-simple enough that nothing in
it can be wrong in a way you can't see. That same file is also our production CPU
renderer (the existing SW PBR demo proves scalar is usable) and the file we teach
from. One artefact, three roles, zero divergence.

Concretely:

- **`src/raster/reference.zig`** — B: the per-triangle, `L=f32`, single-threaded
  rasteriser of §9. The spec, the engine, the teaching text.
- **Shared core** — `src/raster/{pipeline,coverage,interp,clip,sampler,fragment_ctx}.zig`
  (§2–§7): fixed-point coverage + top-left, the perspective-correct interpolation
  fold, the near-plane clipper, the 2×2-quad derivatives + sampler model, the
  configurable depth/blend/MRT stages.
- **Fixed-function = a comptime shader** on B (§0, §12 phase 2). One rasteriser;
  `rlsw.drawTriangle` retires with no perf regression (monomorphisation inlines it).

We still get the discipline that made the layered idea attractive — **differential
testing** — just pointed at the targets that matter for B:

```zig
// The oracle gate (§11): the SAME shader source, SW reference vs real GPU.
test "GPU matches the SW spec, per shader, on random scenes" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    for (0..1000) |_| {
        const scene = randomScene(prng.random());
        const sw  = renderWith(.{ .lane_width = 1 }, rasterizeReference, scene); // the spec
        const gpu = renderOnWgpu(scene);                                          // SPIR-V→WGSL
        try expectClose(sw, gpu, .{ .max_abs = 1.0 / 255.0, .psnr_min = 50 });
    }
}

// IF we ever add the deferred SIMD128 path (§1, §8): it must equal scalar B
// bit-for-bit, so the spec stays the single source of truth.
test "deferred: SIMD128 path == scalar reference, pixel-exact" {
    // … renderWith(.{ .lane_width = 4 }, …) vs lane_width = 1 …
}
```

So, stated plainly:

1. **Build B.** It is simultaneously the spec, the engine, and the teaching device.
2. **A is rejected** for single-threaded wasm and recorded in §8 only as the
   reasoning for that rejection.
3. **The door stays open, under test.** If B is ever too slow, add tiling and/or
   wasm-SIMD128 *to B* as pure single-threaded optimisations, each gated by a
   bit-exact diff against today's scalar B. The spec never moves; only its speed does.

---

## 11. The payoff: the oracle harness (why all this exists)

The same `shaderMain` source already goes to the GPU via SPIR-V→WGSL. The harness
renders both and diffs — and that diff is what validates `spv2wgsl`, Tint's
uniformity transforms, the sampler model, and our depth/blend conventions:

```zig
pub fn oracleCheck(comptime Shader: type, scene: Scene) !void {
    const sw  = renderWith(.{ .lane_width = 1 }, rasterizeReference, scene, Shader(f32));
    const gpu = renderOnWgpu(scene, Shader);     // SPIR-V→WGSL, real device/Tint
    // Exact where it must be (coverage, flat interpolation); ε-tolerant where
    // float order legitimately differs (transcendentals). Report PSNR + a diff
    // image + the first divergent pixel's (tri, bary, varyings) for debugging.
    try expectClose(sw, gpu, .{ .max_abs = 1.0/255.0, .psnr_min = 50 });
}
```

This is the upgrade path for everything in `spv2wgsl_hardening.md`: instead of
eyeballing screenshots on a phone, every shader gets a CI gate that says "the GPU
matches the spec." Determinism requirements that make this possible: fixed-point
coverage (§3), a defined float reduction order in the reference, a documented
sampler model (§6), and stable primitive ordering (§10 cons).

Other applications this unlocks, basically for free, once the core exists:
headless server-side rendering (no GPU needed in CI), golden-image regression
tests for the examples, a "show me the overdraw / quad-helper waste" teaching
overlay, baking (lightmaps/AO) on the CPU with the *same* shaders, and a fallback
renderer for environments with no WebGPU.

---

## 12. The build order (committed; immediate effort is irrelevant, correctness is the deadline)

**Phase 0 — baseline (DONE 2026-06-16).** Build the existing `wgpu_helmet_sw`
standalone (`zig build wgpu-helmet-sw-standalone -Dmode=release`) and confirm the
three targets still render — GPU (right), CPU software via
`rlsw_shader.rasterizeTriangles` (left), comptime corner. This is the
before-picture every later phase is diffed against. *Do not change the rasteriser
until this is verified green.*

**Phase 1 — B, done right (the heart of the work).** Evolve
`rlsw_shader.rasterizeTriangles` into `src/raster/reference.zig`, keeping
`lane_width = 1` (scalar — the form we already have and the form we transpile):
- add the near-plane clipper (§7) — the correctness hole today;
  **[DONE 2026-06-16, shipped zimr1211]** `clipTriangleNearPlane` + `lerpVertex2`
  in `src/rlsw_shader.zig`; both `rasterizeTriangles` (~L281) and `rasterizeToImage`
  (~L512) now Sutherland-Hodgman-clip `clip.z >= 0` instead of dropping `w<=0`
  triangles; 2 tests (vertex-count + straddle-render) pass; `zig build test` green.
- switch coverage to fixed-point subpixel + top-left rule (§3) — watertight;
  **[DONE 2026-06-16, shipped zimr1215]** integer edge functions + top-left in
  `setupTriCoverage`/`EdgeFn`/`covers`/`weights`; both `rasterizeTriangles` and
  `rasterizeToImage` swapped (float edges + signed `inv_area2` gone); the
  `rasterizeToImage`==`rasterizeTriangles` parity test stays green; helmet_sw
  visually confirmed.
- shade in 2×2 quads + derivatives + a sampler model (§5/§6).
  **[a DONE; b+c CUT — see below].**  The CPU texture fetch is
  `sampleTextureRgba8` in the GENERATED externs (`tools/gen_shader_externs.zig`);
  `zm.zsample2d` is only the GPU-rewrite stub.
  (a) **[DONE 2026-06-16, shipped zimr1217]** bilinear filtering in
  `sampleTextureRgba8` (repeat-wrap, sRGB-correct per-texel blend via a
  `_texelRgba8` helper; `TextureRef.linear: bool = true` selects bilinear vs
  nearest, defaulted); closes the helmet's nearest→linear divergence; lint 0/277.
  (b)+(c) **[CUT 2026-06-16]** — verified the engine creates every GPU texture
  with `mipLevelCount` unset (defaults to 1) and generates no mipmaps anywhere
  (`bridge.zig` createTexture @ ~3340; zero `generateMipmap`/`mipLevelCount` in
  bridge/draw3d), AND no shader consumes screen-space derivatives (grep for
  `dpdx`/`ddx`/`fwidth`/`SampleGrad` across `src/shaders` is empty; pbr_fs builds
  its TBN from vertex tangents `frag_world_tangent`, not `ddx`).  With no mip
  chain to select and no derivative consumer, the 2×2-quad/derivative machinery
  has nothing to feed and mip LOD has nothing to sample — the shipped base-level
  bilinear already matches the GPU's base-level bilinear.  REVISIT only if
  mipmaps, or a derivative-using shader (screen-space TBN, `fwidth` AA), are
  ever added.
- (shared-core extraction) — **NOT a goal in itself.**  House rule (Simon,
  2026-06-16): files stay big and flat; we split ONLY when it yields a genuinely
  *shared* core that makes the system more beautiful, never for organization.
  The rasterizer core becomes a real sharing point in Phase 2 (fixed-function +
  programmable both run through it) — revisit extraction THEN, driven by the
  sharing, only if it reads better as its own unit.  Until then `rlsw_shader.zig`
  stays whole.
- Validate against the Phase-0 baseline (helmet_sw + the side-by-sides) — the CPU
  half should match or *improve* on today (bilinear instead of nearest, full-res).
*Deliverable: a trustworthy scalar SW rasteriser that is the spec.*

**Phase 2 — fixed-function becomes a shader (one rasteriser).** Express the raylib
fixed-function path as `FixedFunctionFs` (texture-sample × vertex-colour) and route
`ui.zig` / `wgpu_app` immediate-mode drawing through `reference.zig`. Retire
`rlsw.drawTriangle` and its monomorphised triangle variants. **Prove no perf
regression** — disassemble the specialised inner loop and compare to the old
fixed-function loop (comptime should make them equivalent). `rlsw_pixel.zig` stays
(it's the pixel-format codecs); `rlsw.Context`/framebuffer stays. *Now there is
exactly one rasteriser.*

  *Progress (2026-06-16):* `FixedFunctionFs` already exists — `default_shapes_fs`
  is exactly `sample × vertex_colour`, compiled through the same pipeline, so no
  new shader is needed.  Gap analysis vs `triangleKernel`: `rlsw_shader` already
  has winding cull + depth + perspective interp, and texture/vertex-colour come
  free from running a shader; the only missing pipeline features are **blend** and
  **scissor**.
  - blend: **[DONE, shipped zimr1218]** `RasterizeOpts.blend` (comptime, default
    off) + a comptime-gated `color_reader` + alpha-over at the write site
    mirroring `triangleKernel` (`out = src·a + dst·(1-a)`).  Unit-tested; the
    `rasterizeToImage`==`rasterizeTriangles` parity guard + lint 0/277 stay green;
    the helmet is untouched (blend dormant until a caller opts in).
  - scissor: **[DONE, shipped zimr1219]** a pub `Context.scissorPixelRect` (wraps
    the private `scissorRect` against the effective colour buffer) + `rlsw_shader`
    clamps each triangle bbox to it.  No comptime gate needed — the rect equals
    the full colour buffer when `.scissor_test` is off, so it stays a viewport
    clamp in the common case.  Unit-tested; parity guard + lint 0/277 stay green;
    helmet untouched.
  - routing (integration): the layer-clean approach is a `ff_triangle` dispatch
    hook on `rlsw.Context` (mirrors `SwPipelineDispatch`; `*anyopaque` ctx; `null`
    → built-in kernel, so opt-in + reversible) — this keeps rlsw BELOW
    `rlsw_shader` (rlsw cannot import the shader layer, so it can't call
    `rasterizeTriangles` directly).
    - hook mechanism: **[DONE, shipped zimr1220]** the field + flush dispatch
      (triangles, and quads → two triangles) + a fast-harness test proving
      immediate-mode geometry routes through `rasterizeTriangles`.  Null fallback
      keeps every `triangleKernel` test green; parity guard intact; lint 0/277.
    - bridge logic: **[PROVEN, shipped zimr1221]** the hook impl (`ffBridge`: map
      rlsw `Vertex` → `default_shapes_vs.Out` directly — the VS is bypassed since
      positions are already clip-space, preserving the full vec4 for 3D —, white
      1×1 `_texture0`, `autoConnect`, `rasterizeTriangles`) demonstrated in
      `examples/sw_engine_shader.zig`: the same 3 triangles drawn via the
      immediate-mode API + the `ff_triangle` hook match the direct
      `rasterizeTriangles` path **0 / 3,686,400 channels differing >2 (max delta
      1** — only the u8 colour round-trip).  Verified by a real native build+run
      (`zig build sw-engine-shader`).  So the whole chain (immediate-mode → hook →
      `default_shapes_fs` on CPU → pixels) is correct with the REAL engine shader.
    - opts dispatcher: **[DONE, shipped zimr1222]**
      `rlsw_shader.rasterizeWithRuntimeOpts` — packs runtime depth/blend/cull into
      a 3-bit index and `inline`-expands to 8 comptime `rasterizeTriangles`
      instantiations (cull→`.ccw`/`.none` front face; depth/blend forward
      through).  A fast-harness test (inline shader) covers the cull + blend
      dispatch.  Generic (no `default_shapes` dep) → the reusable opts core the
      bridge calls.
    - engine-wide wiring: **[DONE, shipped zimr1223]** `default_shapes` is
      re-exported as `z.default_shapes.vs` / `.fs` (+ `z.autoConnect`), its CPU
      `*_externs` wired into the zimr/wgpu graph (build.zig
      `is_reexported_shadermain`, alongside pbr), and a `blendEnabled` accessor
      added.  `examples/wgpu_sidebyside` — the ONLY immediate-mode side-by-side —
      sets `s.sw.ff_triangle` to `ffBridge`, which builds the `Out` triple + a
      white 1×1 `_texture0` and calls `rasterizeWithRuntimeOpts(.., false,
      ctx.blendEnabled(), false)` (2D: no depth/cull, blend follows the ctx).  Its
      CPU half now renders through the SAME `default_shapes` shader the GPU half
      runs.  Verified: full standalone build + lint 0/277, all 5 side-by-sides
      typecheck 0 errors, 271 host tests green, no wasm-size regression (the
      dispatcher's dead variants prune under ReleaseSmall).  Key finding: the
      OTHER four side-by-sides render their CPU halves through fragment-shader
      paths (`rasterizeToImage` for helmet; per-pixel eval for cube/mandel/rt),
      NOT the immediate-mode `triangleKernel` path — so they are untouched by the
      bridge and by the eventual retire.
    - **NEXT** — retire `triangleKernel` + its 16 variants + the SIMD path (once
      perf-proven; note other engine consumers — draw3d/image via `SwGl` in
      non-side-by-side contexts — still use it via the `null` fallback, so they
      must be wired to the bridge first), THEN perf-proof (+ begin..end batching
      if per-primitive dispatch regresses).  Textured `TextureRef` (from
      `ctx.bound_texture` when `.texture_2d` is on, else white 1×1 — RGBA8
      assumption) is only needed once a textured immediate-mode consumer appears;
      no current side-by-side needs it.
    Two findings: (1) byte-exact parity with `triangleKernel` is impossible BY
    DESIGN — `rasterizeTriangles` uses the top-left fill rule (the Phase-1 win),
    `triangleKernel` omits it; so "no regression" means interior-equivalent +
    correctly-cleaner edges, validated by the demos + perf-proof, not a pixel
    diff.  (2) the fixed-function fragment is `default_shapes_fs` unchanged.

**Phase 2.5 — unify the rasterizer (the best-possible pass) [RESOLVED 2026-06-16 — KEEP BOTH; see FINAL RESOLUTION below].**
Grounding (verified in-code 2026-06-16; supersedes the Phase 2 "NEXT" above): the
same Zig shader ALREADY runs CPU + GPU for all four showcases — the helmet's CPU
half runs the real `pbr.fs` via `rasterizeToImage` (five material maps as
`TextureRef`s, sRGB matched to the GPU view), with perspective-correct varying
interpolation (1/w lerp), near-plane clip, front-face cull, depth, alpha-over.
WebGL is retired (wgpu-only) — so the extern-freedom constraint that justified the
`ff_triangle` hook is DEAD. Two non-idealities remain:
  (i)  `rlsw.triangleKernel` (16 monomorphised variants + a SIMD path) is a SECOND
       rasterizer, NOT shader-driven; bridged via the runtime `ff_triangle` fn-ptr
       hook (opt-in, triangles-only, one indirect call per triangle).
  (ii) `rasterizeTriangles` (→ Context FB) and `rasterizeToImage` (→ returned
       array) DUPLICATE the entire clip/project/cover/interpolate/shade loop, kept
       in lockstep by a differential test.

TARGET ARCHITECTURE (one-line defense each):
  - One programmable rasterizer = the foundation; fixed-function is JUST the
    `default_shapes` shader over it.  Defense: maximal unification, minimal code.
  - One core with a pluggable output sink (Context FB | returned array).  Defense:
    two implementations of identical math is a latent divergence bug; one isn't.
  - Fixed-function calls the unified rasterizer DIRECTLY; delete `triangleKernel`
    + its 16 variants + the hook.  Defense: WebGL's gone, so the inversion the hook
    bought is dead weight; a direct call is monomorphised + drops the indirect call.
  COUPLING FORK (decide on Turn-1 evidence): (a) keep the fn-ptr hook; (b) hard-
  import `default_shapes` into `rlsw` (couples the layer + forces its externs into
  every rlsw build); (c) make `Context` generic over the shader module —
  monomorphised + type-safe, but ripples through `SwGl` + every consumer.  Leaning
  (c), contingent on perf + ripple cost.

THE OPEN QUESTION THAT GATES THE THESIS: does the programmable path, with the
comptime shader inlined, MATCH `triangleKernel`'s SIMD kernel?  Unknown until
measured (Turn 1).  If it regresses, we need SIMD and/or begin..end batching in
`rlsw_shader` BEFORE any retire.

REALITY ANCHOR: this dev container has no GPU/browser, so CPU-vs-real-GPU cannot be
auto-tested here.  The honest oracle = CPU-correctness + transpile-correctness +
matched sampler/interp SEMANTICS, with the final visual match confirmed when the
HTML is opened.  (Full CPU-vs-GPU CI needs a headless GPU — see Phase 3.)

COMPLETENESS EDGES (bound "full" parity; audit as we go): near-plane clip ONLY (no
full-frustum / guard-band, §7); alpha-over blend ONLY; texture-sampling matrix only
partly matched (wrap modes, mips, cubemaps, non-RGBA8 formats); no MSAA/MRT/stencil
(Phase 3).  spv2wgsl feature coverage is the real ceiling on WHICH shaders unify.

THE NEXT 3 TURNS (precise, runnable, small):
  [RESULT + DECISION, 2026-06-16] Turn 1 ran: B/A = 1.94× (A `triangleKernel`
  2365 ns/tri vs B `rasterizeTriangles`+`default_shapes` 4591 ns/tri; 480×270,
  blend on; native ReleaseFast).  The gap is ALGORITHMIC, not hook overhead — the
  ~548 ms delta over 246K triangles is per-PIXEL: (1) perspective-correct 1/w
  interpolation 2D (W=1) doesn't need; (2) a per-pixel fragment-shader call that
  always samples a texture (even the 1×1 white) where `triangleKernel`'s untextured
  path skips sampling; (3) `triangleKernel`'s SIMD path vs the programmable scalar
  loop.  Simon chose (b): CLOSE the gap BEFORE retiring, so the retire is a
  no-regression change.  REORDERED PLAN: Turn 2 (golden refs) FIRST — they pin
  current behavior so the gap-closing can't silently regress correctness — THEN
  close the perf gap (a W=1 affine fast-path that skips the perspective divide for
  2D + SIMD in `rasterizeTriangles`), THEN collapse the two rasteriser cores into
  one, THEN retire `triangleKernel` (the coupling fork a/b/c is decided at retire
  time).  (Benchmark lives in `examples/sw_engine_shader.zig` → `runBenchmark`,
  run by `zig build sw-engine-shader`.)

  [GAP-CLOSING RESULT + RE-DECISION, 2026-06-16] The gap-closing ran, and the
  cheap levers are EXHAUSTED.  Measured on the wgpu_sidebyside scene (Path B =
  rasterizeTriangles via the fixed-function bridge):
    • affine MULTIPLY fast-path (skip `w·inv_w` for W=1, keep the normalize):
      0% — within run-to-run noise (±~5%; Path A's unchanged code swung
      2254–2467 ns/tri across runs).  The perspective multiply is NOT a cost.
    • skip the normalize-DIVIDE (W=1 takes the raw barycentric weights — they
      sum to ≈1, the same ones the depth interp already uses raw): B 4624→4272
      ns/tri, ≈7% (B/A ≈1.94→≈1.82).  ADOPTED; ≤1 ULP vs the normalized form
      (factor 1±~6e-8); the absolute golden was updated once to match.
    • varying interpolation (`lerpAny`) is ALREADY vectorized (`@splat` + vector
      mul/add for @Vector fields) — no cheap win there.
  The residual ~1.8× is the always-on bilinear texture sample (default_shapes_fs
  samples even the 1×1 white), the per-pixel FS call, and the lack of cross-pixel
  SIMD.  KEY REALISATION: a programmable rasteriser that calls an ARBITRARY
  per-pixel `shaderMain` cannot be vectorised across pixels the way the
  fixed-function `triangleKernel` is — the kernel SIMDs precisely because its ops
  are known.  So "close the gap to parity" is likely NOT achievable cheaply for
  the programmable path; ~1.8× is probably near the floor.  This re-raises the
  perf fork with hard data — options: (i) ACCEPT ~1.8× and retire `triangleKernel`
  (fixed-function 2D is rarely the bottleneck; the unification is the right
  architecture; skip-divide already banked); (ii) KEEP `triangleKernel` for 2D (no
  retire — keep the perf, accept the duplication); (iii) INVEST in a 1×1/nearest
  sampler fast-path + a shader-vectorisation SIMD framework (large).  Leaning (i).
  The new absolute golden + the existing differential/proof guard whichever path.

  [FINAL RESOLUTION, 2026-06-16] Simon chose (ii): KEEP `triangleKernel` — accept
  the duplication, NO retire.  Final measured numbers (native ReleaseFast,
  wgpu_sidebyside scene): fixed-function 2447 ns/tri vs programmable 4287 ns/tri,
  B/A = 1.75× (after the W=1 skip-divide landed; the proof holds — 0/3.6M channels
  differ >2, golden green).  Rationale: the residual ~1.75× is STRUCTURAL — a
  programmable per-pixel `shaderMain` can't be SIMD'd across pixels the way the
  fixed-function kernel is, so closing it would need a shader-vectorisation
  framework — large machinery for a regime that rarely bites (real 2D UI/shapes run
  far below this 246K-tri/s stress test).  So `triangleKernel` keeps its speed for
  fixed-function 2D, and `rasterizeTriangles`/`rasterizeToImage` stay the
  programmable path for 3D + the showcases + the helmet.  Both stand BY DESIGN; the
  two programmable cores remain duplicated, kept honest by the differential test +
  the absolute golden pin.  This CLOSES Phase 2.5 — the W=1 affine fast-path and the
  absolute golden landed and stay; the "Turn 1 / Turn 2 / Turn 3" plan below is now
  HISTORICAL (the collapse + retire steps were NOT taken).

  Turn 1 — PERF GROUND TRUTH (decides the thesis).  A native micro-benchmark
    rasterizing the `wgpu_sidebyside` scene (10 alpha discs as triangle fans + 1
    hexagon) both ways: hook-off (`triangleKernel`) vs hook-on (`rasterizeTriangles`
    + `default_shapes`), many iterations, wall-clock + per-triangle ns.  Output: a
    number that says whether the programmable path is competitive + whether
    SIMD/batching is required before any retire.
  Turn 2 — PARITY GROUND TRUTH (the defensibility document).  Golden-reference
    test: `rasterizeToImage` per showcase shader vs a checked-in PNG (pins the CPU
    path); `spv2wgsl` output vs checked-in golden WGSL (pins the transpile).  Plus a
    short sampler/interp parity SPEC (sRGB, filtering, wrap, NDC-z [0,1] range,
    top-left fill rule) defining what "matches the GPU" MEANS.
  Turn 3 — DECIDE + FIRST IRREVERSIBLE-SAFE STEP.  Lock the coupling decision
    (a/b/c) on the evidence, then collapse `rasterizeTriangles` + `rasterizeToImage`
    into ONE sink-pluggable core, guarded by the existing differential test — the
    prerequisite that makes deleting `triangleKernel` clean, not risky.

**Phase 3 — fidelity + the oracle harness (the payoff).** MSAA (sample mask +
positions + resolve, §2), MRT polish, guard-band clipping (§7), and the
`oracleCheck` CI gate (§11) wired over every `_fs.zig`: render SW-spec vs real GPU,
assert close, on random scenes. *Now the GPU is continuously validated against the
spec instead of eyeballed on a phone.*

**Deferred (NOT in committed scope) — speed, only if needed.** If scalar B is too
slow in real use: (a) wasm-SIMD128 via the lane-polymorphic SoA rewrite (§1,
`lane_width = 4`), and/or (b) single-threaded tiling for cache-locality +
hierarchical reject (§8's single-threaded wins, *without* threads). Each is gated
by a bit-exact diff against today's scalar B (§10). Don't start these until a
profile demands them.

Each phase ends green on the existing gate + `zig build test`, adds its own
golden/differential tests, and deletes nothing until the replacement is proven
equal. The order builds the *trustworthy* thing first and only ever optimises
*under* a bit-exact check against it — the only order that yields an oracle you can
actually believe.

